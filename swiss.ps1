param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CliArguments
)

# Linux Swiss Army Knife read-only Windows system inspector.
# Every command in this file queries local APIs. It never elevates privileges,
# installs software, contacts a remote host, or changes machine state.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectorName = 'linux-swiss-army-knife'
$collectorVersion = '0.1.0'
$schemaVersion = '1'
$outputMode = 'human'
$collectionMode = 'normal'
$debugOutput = $false
$outputOptionSeen = 0

function Show-Usage {
    @'
Usage: swiss.ps1 [OPTIONS]

Collect read-only local Windows system information without elevation or network traffic.

Options:
  --plain       Stable, uncolored tab-separated output
  --json        Versioned JSON output for automation
  --debug       Include each fact's source in human/plain output
  --full        Include additional safe local queries
  -h, --help    Show this help
  --version     Show the collector version
'@ | Write-Output
}

foreach ($argument in $CliArguments) {
    switch ($argument) {
        '--plain' {
            $outputOptionSeen++
            $outputMode = 'plain'
        }
        '--json' {
            $outputOptionSeen++
            $outputMode = 'json'
        }
        '--debug' {
            $debugOutput = $true
        }
        '--full' {
            $collectionMode = 'full'
        }
        { $_ -in @('-h', '--help') } {
            Show-Usage
            exit 0
        }
        '--version' {
            Write-Output ('{0} {1}' -f $collectorName, $collectorVersion)
            exit 0
        }
        default {
            [Console]::Error.WriteLine('swiss.ps1: unknown option: {0}', $argument)
            [Console]::Error.WriteLine('Try swiss.ps1 --help for usage.')
            exit 2
        }
    }
}

if ($outputOptionSeen -gt 1) {
    [Console]::Error.WriteLine('swiss.ps1: --plain and --json are mutually exclusive')
    exit 2
}

$script:facts = New-Object 'System.Collections.Generic.List[object]'

function Convert-ToDisplayText {
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return ''
    }
    return ([string] $Value) -replace '[\x00-\x1F\x7F]', ' '
}

function Convert-ToInventoryText {
    param([AllowNull()] $Value)

    $text = Convert-ToDisplayText $Value
    return $text.Replace('%', '%25').Replace(';', '%3B').Replace('|', '%7C').Replace('=', '%3D')
}

function Add-Fact {
    param(
        [Parameter(Mandatory = $true)] [string] $Key,
        [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ok', 'unknown', 'unsupported', 'missing', 'denied', 'error')]
        [string] $Status,
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)]
        [ValidateSet('exact', 'derived', 'heuristic')]
        [string] $Confidence
    )

    $script:facts.Add([ordered] @{
        key = $Key
        value = (Convert-ToDisplayText $Value)
        status = $Status
        source = (Convert-ToDisplayText $Source)
        confidence = $Confidence
    })
}

function Add-DetectedFact {
    param(
        [Parameter(Mandatory = $true)] [string] $Key,
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Source,
        [string] $Confidence = 'exact',
        [string] $EmptyStatus = 'unknown'
    )

    $text = Convert-ToDisplayText $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        Add-Fact -Key $Key -Value '' -Status $EmptyStatus -Source $Source `
            -Confidence $Confidence
    }
    else {
        Add-Fact -Key $Key -Value $text -Status 'ok' -Source $Source `
            -Confidence $Confidence
    }
}

function Get-CommandAvailable {
    param([Parameter(Mandatory = $true)] [string] $Name)
    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Join-Inventory {
    param([object[]] $Items)
    return (@($Items) -join ';')
}

function Get-InterfaceKind {
    param(
        [AllowEmptyString()] [string] $Name,
        [AllowEmptyString()] [string] $Description,
        [AllowEmptyString()] [string] $MediaType
    )

    $combined = '{0} {1} {2}' -f $Name, $Description, $MediaType
    if ($combined -match '(?i)loopback') { return 'loopback' }
    if ($combined -match '(?i)wi-?fi|wireless|802\.11') { return 'wifi' }
    if ($combined -match '(?i)ethernet|802\.3') { return 'wired' }
    if ($combined -match '(?i)vpn|tunnel|wireguard|tailscale') { return 'tunnel' }
    if ($combined -match '(?i)hyper-v|virtual|bridge|container') { return 'virtual' }
    return 'unknown'
}

function Get-CimStatus {
    param([bool] $CommandAvailable, [bool] $QueryFailed)
    if (-not $CommandAvailable) { return 'missing' }
    if ($QueryFailed) { return 'error' }
    return 'unknown'
}

$fixtureMode = $env:SWISS_FIXTURE_MODE -eq '1'
$isWindowsHost = $env:OS -eq 'Windows_NT' -or $env:SWISS_TEST_WINDOWS -eq '1'
$platformAdapter = if ($isWindowsHost) { 'windows' } else { 'unknown' }
$collectionTimestamp = [DateTime]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ssZ',
    [Globalization.CultureInfo]::InvariantCulture
)

Add-Fact collector.name $collectorName ok 'built-in' exact
Add-Fact collector.version $collectorVersion ok 'built-in' exact
Add-Fact collector.schema_version $schemaVersion ok 'built-in' exact
Add-Fact collector.timestamp $collectionTimestamp ok '.NET DateTime UTC' exact
Add-Fact collector.mode $collectionMode ok 'arguments' exact
Add-Fact collector.platform_adapter $platformAdapter ok '.NET environment' exact

$hostnameValue = if ($fixtureMode) { 'fixture-host' } else { [Environment]::MachineName }
$usernameValue = if ($fixtureMode) { 'fixture-user' } else { [Environment]::UserName }
Add-DetectedFact identity.hostname $hostnameValue '.NET Environment.MachineName'
Add-DetectedFact identity.username $usernameValue '.NET Environment.UserName'
Add-Fact identity.uid '' unsupported 'Windows has no POSIX numeric user ID' exact
Add-Fact identity.primary_gid '' unsupported 'Windows has no POSIX numeric primary group ID' exact

if ($isWindowsHost) {
    try {
        $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $windowsPrincipal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
        $isAdministrator = $windowsPrincipal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
        Add-Fact identity.is_privileged ($isAdministrator.ToString().ToLowerInvariant()) `
            ok '.NET WindowsPrincipal token membership' exact
    }
    catch {
        Add-Fact identity.is_privileged '' error '.NET WindowsPrincipal token membership' exact
    }
}
else {
    Add-Fact identity.is_privileged '' unsupported 'non-Windows host' exact
}

$elevationTools = New-Object 'System.Collections.Generic.List[string]'
foreach ($toolName in @('runas.exe', 'sudo.exe', 'gsudo.exe')) {
    if (Get-CommandAvailable $toolName) {
        $elevationTools.Add($toolName)
    }
}
Add-Fact identity.elevation_tools ($elevationTools -join ',') ok `
    'Get-Command (tools not invoked)' exact

$cimAvailable = $isWindowsHost -and (Get-CommandAvailable 'Get-CimInstance')
$osInfo = $null
$computerInfo = $null
$biosInfo = $null
$processorInfo = $null
$coreCimFailed = $false
if ($cimAvailable) {
    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -First 1
        $computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -First 1
        $biosInfo = Get-CimInstance -ClassName Win32_BIOS | Select-Object -First 1
        $processorInfo = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    }
    catch {
        $coreCimFailed = $true
    }
}

if ($isWindowsHost) {
    Add-Fact system.kernel.name 'Windows NT' ok 'Windows platform definition' exact
    if ($null -ne $osInfo) {
        Add-DetectedFact system.kernel.release $osInfo.Version `
            'CIM Win32_OperatingSystem.Version'
    }
    else {
        Add-DetectedFact system.kernel.release ([Environment]::OSVersion.Version.ToString()) `
            '.NET Environment.OSVersion' derived
    }
    $machineArchitecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($machineArchitecture)) {
        $machineArchitecture = $env:PROCESSOR_ARCHITECTURE
    }
    Add-DetectedFact system.architecture.machine $machineArchitecture `
        'PROCESSOR_ARCHITECTURE environment'
    $userspaceBits = if ([Environment]::Is64BitProcess) { '64' } else { '32' }
    Add-Fact system.architecture.userspace_bits $userspaceBits ok `
        '.NET Environment.Is64BitProcess' exact
}
else {
    Add-Fact system.kernel.name '' unsupported 'non-Windows host' exact
    Add-Fact system.kernel.release '' unsupported 'non-Windows host' exact
    Add-Fact system.architecture.machine '' unsupported 'non-Windows host' exact
    Add-Fact system.architecture.userspace_bits '' unsupported 'non-Windows host' exact
}

if (-not $isWindowsHost) {
    foreach ($key in @(
        'system.os.family',
        'system.os.product',
        'system.os.version',
        'system.os.build',
        'system.environment.type',
        'system.uptime_seconds',
        'hardware.manufacturer',
        'hardware.model',
        'hardware.firmware.vendor',
        'hardware.firmware.version',
        'hardware.firmware.date',
        'hardware.cpu.model',
        'hardware.cpu.logical_count',
        'hardware.memory.total_bytes',
        'hardware.battery.present',
        'hardware.battery.state',
        'hardware.battery.charge_percent',
        'hardware.filesystems',
        'hardware.storage',
        'network.hostname',
        'network.interfaces',
        'network.addresses',
        'network.default_route.exists',
        'network.default_route.interface',
        'network.default_route.gateway',
        'network.dns.resolvers'
    )) {
        Add-Fact $key '' unsupported 'non-Windows host' exact
    }
}
else {
    Add-Fact system.os.family windows ok 'Windows platform definition' exact
    if ($null -ne $osInfo) {
        Add-DetectedFact system.os.product $osInfo.Caption `
            'CIM Win32_OperatingSystem.Caption'
        Add-DetectedFact system.os.version $osInfo.Version `
            'CIM Win32_OperatingSystem.Version'
        Add-DetectedFact system.os.build $osInfo.BuildNumber `
            'CIM Win32_OperatingSystem.BuildNumber'
    }
    else {
        $coreStatus = Get-CimStatus $cimAvailable $coreCimFailed
        Add-Fact system.os.product '' $coreStatus 'CIM Win32_OperatingSystem' exact
        Add-Fact system.os.version ([Environment]::OSVersion.Version.ToString()) ok `
            '.NET Environment.OSVersion' derived
        Add-Fact system.os.build '' $coreStatus 'CIM Win32_OperatingSystem' exact
    }

    $environmentType = 'unknown'
    $environmentSource = 'CIM computer-system heuristics'
    if (-not [string]::IsNullOrWhiteSpace($env:WSL_DISTRO_NAME)) {
        $environmentType = 'wsl'
        $environmentSource = 'WSL_DISTRO_NAME environment'
    }
    elseif ($null -ne $computerInfo) {
        $environmentText = '{0} {1}' -f $computerInfo.Manufacturer, $computerInfo.Model
        if ($environmentText -match '(?i)virtual|vmware|virtualbox|kvm|qemu|xen|hyper-v') {
            $environmentType = 'virtual-machine'
        }
        else {
            $environmentType = 'physical'
        }
    }
    if ($environmentType -eq 'unknown') {
        Add-Fact system.environment.type $environmentType unknown $environmentSource heuristic
    }
    else {
        Add-Fact system.environment.type $environmentType ok $environmentSource heuristic
    }

    if ($null -ne $osInfo -and $null -ne $osInfo.LastBootUpTime) {
        try {
            $bootTimeUtc = ([DateTime] $osInfo.LastBootUpTime).ToUniversalTime()
            $uptimeSeconds = [Math]::Floor(([DateTime]::UtcNow - $bootTimeUtc).TotalSeconds)
            Add-Fact system.uptime_seconds ([string] $uptimeSeconds) ok `
                'CIM Win32_OperatingSystem.LastBootUpTime' derived
        }
        catch {
            Add-Fact system.uptime_seconds '' error `
                'CIM Win32_OperatingSystem.LastBootUpTime' derived
        }
    }
    else {
        Add-Fact system.uptime_seconds '' (Get-CimStatus $cimAvailable $coreCimFailed) `
            'CIM Win32_OperatingSystem.LastBootUpTime' derived
    }

    if ($null -ne $computerInfo) {
        Add-DetectedFact hardware.manufacturer $computerInfo.Manufacturer `
            'CIM Win32_ComputerSystem.Manufacturer'
        Add-DetectedFact hardware.model $computerInfo.Model `
            'CIM Win32_ComputerSystem.Model'
    }
    else {
        $coreStatus = Get-CimStatus $cimAvailable $coreCimFailed
        Add-Fact hardware.manufacturer '' $coreStatus 'CIM Win32_ComputerSystem' exact
        Add-Fact hardware.model '' $coreStatus 'CIM Win32_ComputerSystem' exact
    }

    if ($null -ne $biosInfo) {
        Add-DetectedFact hardware.firmware.vendor $biosInfo.Manufacturer `
            'CIM Win32_BIOS.Manufacturer'
        Add-DetectedFact hardware.firmware.version $biosInfo.SMBIOSBIOSVersion `
            'CIM Win32_BIOS.SMBIOSBIOSVersion'
        $firmwareDate = ''
        if ($null -ne $biosInfo.ReleaseDate) {
            try {
                $firmwareDate = ([DateTime] $biosInfo.ReleaseDate).ToString('yyyy-MM-dd')
            }
            catch {
                $firmwareDate = ''
            }
        }
        Add-DetectedFact hardware.firmware.date $firmwareDate 'CIM Win32_BIOS.ReleaseDate'
    }
    else {
        $coreStatus = Get-CimStatus $cimAvailable $coreCimFailed
        Add-Fact hardware.firmware.vendor '' $coreStatus 'CIM Win32_BIOS' exact
        Add-Fact hardware.firmware.version '' $coreStatus 'CIM Win32_BIOS' exact
        Add-Fact hardware.firmware.date '' $coreStatus 'CIM Win32_BIOS' exact
    }

    if ($null -ne $processorInfo) {
        Add-DetectedFact hardware.cpu.model $processorInfo.Name 'CIM Win32_Processor.Name'
        Add-DetectedFact hardware.cpu.logical_count $processorInfo.NumberOfLogicalProcessors `
            'CIM Win32_Processor.NumberOfLogicalProcessors'
    }
    else {
        $coreStatus = Get-CimStatus $cimAvailable $coreCimFailed
        Add-Fact hardware.cpu.model '' $coreStatus 'CIM Win32_Processor' exact
        Add-Fact hardware.cpu.logical_count '' $coreStatus 'CIM Win32_Processor' exact
    }

    if ($null -ne $osInfo -and $null -ne $osInfo.TotalVisibleMemorySize) {
        $memoryBytes = [uint64] $osInfo.TotalVisibleMemorySize * 1024
        Add-Fact hardware.memory.total_bytes ([string] $memoryBytes) ok `
            'CIM Win32_OperatingSystem.TotalVisibleMemorySize' exact
    }
    else {
        Add-Fact hardware.memory.total_bytes '' (Get-CimStatus $cimAvailable $coreCimFailed) `
            'CIM Win32_OperatingSystem.TotalVisibleMemorySize' exact
    }

    $batteryQueryFailed = $false
    $batteries = @()
    if ($cimAvailable) {
        try {
            $batteries = @(Get-CimInstance -ClassName Win32_Battery)
        }
        catch {
            $batteryQueryFailed = $true
        }
    }
    if ($batteries.Count -gt 0) {
        $battery = $batteries[0]
        Add-Fact hardware.battery.present true ok 'CIM Win32_Battery' exact
        Add-DetectedFact hardware.battery.state $battery.BatteryStatus `
            'CIM Win32_Battery.BatteryStatus'
        Add-DetectedFact hardware.battery.charge_percent $battery.EstimatedChargeRemaining `
            'CIM Win32_Battery.EstimatedChargeRemaining'
    }
    elseif ($cimAvailable -and -not $batteryQueryFailed) {
        Add-Fact hardware.battery.present false ok 'CIM Win32_Battery' exact
        Add-Fact hardware.battery.state '' unsupported 'CIM Win32_Battery' exact
        Add-Fact hardware.battery.charge_percent '' unsupported 'CIM Win32_Battery' exact
    }
    else {
        $batteryStatus = Get-CimStatus $cimAvailable $batteryQueryFailed
        Add-Fact hardware.battery.present '' $batteryStatus 'CIM Win32_Battery' exact
        Add-Fact hardware.battery.state '' $batteryStatus 'CIM Win32_Battery' exact
        Add-Fact hardware.battery.charge_percent '' $batteryStatus 'CIM Win32_Battery' exact
    }

    $logicalDiskQueryFailed = $false
    $filesystemItems = New-Object 'System.Collections.Generic.List[string]'
    if ($cimAvailable) {
        try {
            $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')
            foreach ($disk in $logicalDisks) {
                $filesystemItems.Add(('{0}|total={1}|free={2}' -f `
                    (Convert-ToInventoryText $disk.DeviceID), $disk.Size, $disk.FreeSpace))
            }
        }
        catch {
            $logicalDiskQueryFailed = $true
        }
    }
    $logicalDiskStatus = Get-CimStatus $cimAvailable $logicalDiskQueryFailed
    if ($filesystemItems.Count -gt 0) {
        Add-Fact hardware.filesystems (Join-Inventory $filesystemItems) ok `
            'CIM Win32_LogicalDisk' exact
    }
    else {
        Add-Fact hardware.filesystems '' $logicalDiskStatus 'CIM Win32_LogicalDisk' exact
    }

    if ($collectionMode -eq 'full') {
        $storageQueryFailed = $false
        $storageItems = New-Object 'System.Collections.Generic.List[string]'
        if ($cimAvailable) {
            try {
                $physicalDisks = @(Get-CimInstance -ClassName Win32_DiskDrive)
                foreach ($disk in $physicalDisks) {
                    $storageItems.Add(('{0}|bytes={1}|model={2}' -f `
                        (Convert-ToInventoryText $disk.DeviceID), $disk.Size,
                        (Convert-ToInventoryText $disk.Model)))
                }
            }
            catch {
                $storageQueryFailed = $true
            }
        }
        if ($storageItems.Count -gt 0) {
            Add-Fact hardware.storage (Join-Inventory $storageItems) ok `
                'CIM Win32_DiskDrive (--full)' exact
        }
        else {
            Add-Fact hardware.storage '' (Get-CimStatus $cimAvailable $storageQueryFailed) `
                'CIM Win32_DiskDrive (--full)' exact
        }
    }
    else {
        Add-Fact hardware.storage '' unsupported `
            'use --full for CIM Win32_DiskDrive' exact
    }

    Add-DetectedFact network.hostname $hostnameValue '.NET Environment.MachineName'

    $adapterItems = New-Object 'System.Collections.Generic.List[string]'
    $addressItems = New-Object 'System.Collections.Generic.List[string]'
    $dnsValues = New-Object 'System.Collections.Generic.List[string]'
    $routeInterface = ''
    $routeGateway = ''
    $networkSource = 'Windows networking cmdlets'
    $networkFailed = $false
    $modernNetworkAvailable = (Get-CommandAvailable 'Get-NetAdapter') -and
        (Get-CommandAvailable 'Get-NetIPAddress')

    if ($modernNetworkAvailable) {
        try {
            foreach ($adapter in @(Get-NetAdapter)) {
                $kind = Get-InterfaceKind $adapter.Name $adapter.InterfaceDescription `
                    ([string] $adapter.NdisPhysicalMedium)
                $adapterItems.Add(('{0}|state={1}|type={2}|mac={3}' -f `
                    (Convert-ToInventoryText $adapter.Name),
                    (Convert-ToInventoryText $adapter.Status), $kind,
                    (Convert-ToInventoryText $adapter.MacAddress)))
            }
            foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4, IPv6)) {
                $family = if ($address.AddressFamily -eq 2 -or
                    $address.AddressFamily -eq 'IPv4') { 'inet' } else { 'inet6' }
                $addressItems.Add(('{0}|{1}|{2}/{3}' -f
                    (Convert-ToInventoryText $address.InterfaceAlias), $family,
                    (Convert-ToInventoryText $address.IPAddress), $address.PrefixLength))
            }

            if (Get-CommandAvailable 'Get-NetRoute') {
                $defaultRoute = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
                    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1)
                if ($defaultRoute.Count -gt 0) {
                    $routeInterface = [string] $defaultRoute[0].InterfaceAlias
                    $routeGateway = [string] $defaultRoute[0].NextHop
                }
            }
            if (Get-CommandAvailable 'Get-DnsClientServerAddress') {
                foreach ($dnsEntry in @(Get-DnsClientServerAddress)) {
                    foreach ($serverAddress in @($dnsEntry.ServerAddresses)) {
                        if (-not [string]::IsNullOrWhiteSpace($serverAddress) -and
                            -not $dnsValues.Contains([string] $serverAddress)) {
                            $dnsValues.Add([string] $serverAddress)
                        }
                    }
                }
            }
        }
        catch {
            $networkFailed = $true
        }
    }
    elseif ($cimAvailable) {
        $networkSource = 'CIM Win32_NetworkAdapterConfiguration'
        try {
            $networkConfigurations = @(
                Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                    -Filter 'IPEnabled=True'
            )
            foreach ($configuration in $networkConfigurations) {
                $kind = Get-InterfaceKind $configuration.Description `
                    $configuration.Description ''
                $adapterItems.Add(('{0}|state=up|type={1}|mac={2}' -f `
                    (Convert-ToInventoryText $configuration.Description), $kind,
                    (Convert-ToInventoryText $configuration.MACAddress)))
                foreach ($address in @($configuration.IPAddress)) {
                    $family = if ($address -match ':') { 'inet6' } else { 'inet' }
                    $addressItems.Add(('{0}|{1}|{2}' -f `
                        (Convert-ToInventoryText $configuration.Description), $family,
                        (Convert-ToInventoryText $address)))
                }
                foreach ($gateway in @($configuration.DefaultIPGateway)) {
                    if ([string]::IsNullOrWhiteSpace($routeGateway)) {
                        $routeGateway = [string] $gateway
                        $routeInterface = [string] $configuration.Description
                    }
                }
                foreach ($serverAddress in @($configuration.DNSServerSearchOrder)) {
                    if (-not [string]::IsNullOrWhiteSpace($serverAddress) -and
                        -not $dnsValues.Contains([string] $serverAddress)) {
                        $dnsValues.Add([string] $serverAddress)
                    }
                }
            }
        }
        catch {
            $networkFailed = $true
        }
    }

    $networkStatus = if ($networkFailed) {
        'error'
    }
    elseif ($modernNetworkAvailable -or $cimAvailable) {
        'unknown'
    }
    else {
        'missing'
    }
    if ($adapterItems.Count -gt 0) {
        Add-Fact network.interfaces (Join-Inventory $adapterItems) ok $networkSource exact
    }
    else {
        Add-Fact network.interfaces '' $networkStatus $networkSource exact
    }
    if ($addressItems.Count -gt 0) {
        Add-Fact network.addresses (Join-Inventory $addressItems) ok $networkSource exact
    }
    else {
        Add-Fact network.addresses '' $networkStatus $networkSource exact
    }
    if (-not [string]::IsNullOrWhiteSpace($routeGateway + $routeInterface)) {
        Add-Fact network.default_route.exists true ok $networkSource exact
        Add-DetectedFact network.default_route.interface $routeInterface $networkSource
        Add-DetectedFact network.default_route.gateway $routeGateway $networkSource
    }
    elseif (-not $networkFailed -and ($modernNetworkAvailable -or $cimAvailable)) {
        Add-Fact network.default_route.exists false ok $networkSource exact
        Add-Fact network.default_route.interface '' unknown $networkSource exact
        Add-Fact network.default_route.gateway '' unknown $networkSource exact
    }
    else {
        Add-Fact network.default_route.exists '' $networkStatus $networkSource exact
        Add-Fact network.default_route.interface '' $networkStatus $networkSource exact
        Add-Fact network.default_route.gateway '' $networkStatus $networkSource exact
    }
    if ($dnsValues.Count -gt 0) {
        Add-Fact network.dns.resolvers ($dnsValues -join ',') ok $networkSource exact
    }
    else {
        Add-Fact network.dns.resolvers '' $networkStatus $networkSource exact
    }
}

if ($script:facts.Count -ne 42) {
    throw ('Internal schema error: expected 42 facts, got {0}' -f $script:facts.Count)
}

$report = [ordered] @{
    schema_version = $schemaVersion
    collector = [ordered] @{
        name = $collectorName
        version = $collectorVersion
        mode = $collectionMode
        platform = $platformAdapter
        timestamp = $collectionTimestamp
    }
    facts = $script:facts.ToArray()
    warnings = @()
}

switch ($outputMode) {
    'json' {
        $report | ConvertTo-Json -Depth 6
    }
    'plain' {
        foreach ($fact in $script:facts) {
            if ($debugOutput) {
                Write-Output ("{0}`t{1}`t{2}`t{3}`t{4}" -f $fact.key, $fact.status,
                    $fact.confidence, $fact.value, $fact.source)
            }
            else {
                Write-Output ("{0}`t{1}`t{2}`t{3}" -f $fact.key, $fact.status,
                    $fact.confidence, $fact.value)
            }
        }
    }
    default {
        Write-Output ('{0} {1} - read-only report' -f $collectorName, $collectorVersion)
        Write-Output ('Mode: {0} | Platform: {1} | Collected: {2}' -f
            $collectionMode, $platformAdapter, $collectionTimestamp)
        Write-Output ''
        foreach ($fact in $script:facts) {
            $line = '{0,-34} {1}' -f $fact.key, $fact.value
            if ($fact.status -ne 'ok') {
                $line += ' [{0}]' -f $fact.status
            }
            if ($debugOutput) {
                $line += ' {{{0}; {1}}}' -f $fact.source, $fact.confidence
            }
            Write-Output $line
        }
    }
}
