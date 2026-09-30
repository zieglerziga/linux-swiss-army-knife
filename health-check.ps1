param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProgramVersion = '0.1.0'

function Write-Usage {
    @(
        'Usage: health-check.ps1 CHECK [CHECK ...] [OPTIONS]',
        '',
        'Run explicitly selected system health checks.',
        '',
        'Checks:',
        '  --sudo              Detect administrator or sudo availability',
        '  --disk              Report fixed disks over a usage threshold',
        '  --processes         Detect non-responsive GUI processes',
        '  --updates           Search for applicable Windows updates',
        '  --all               Run all four checks',
        '',
        'Options:',
        '  --plain             Stable tab-separated output: check, status, detail',
        '  --disk-warning N    Warn when disk use is N percent or higher (default: 85)',
        '  --remote USER@HOST  Stream health-check.sh to a POSIX host over SSH',
        '  --identity PATH     SSH private key for --remote',
        '  --connect-timeout N SSH connection timeout in seconds (default: 10)',
        '  -h, --help          Show this help',
        '  --version           Show the command version',
        '',
        'Remote mode requires a verified host key already present in local known_hosts;',
        'unknown keys and passwords are rejected.'
    )
}

function Write-Check {
    param(
        [string] $Name,
        [string] $Status,
        [string] $Detail,
        [bool] $Plain
    )

    $cleanDetail = $Detail -replace '[\r\n\t]+', ' '
    if ($Plain) {
        Write-Output ("{0}`t{1}`t{2}" -f $Name, $Status, $cleanDetail)
    }
    else {
        Write-Output ('[{0}] {1} {2}' -f $Status.ToUpperInvariant(), $Name, $cleanDetail)
    }
}

function Read-FixtureLine {
    param([string] $FileName)

    $path = Join-Path $env:HEALTH_FIXTURE_ROOT $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('fixture is missing: {0}' -f $FileName)
    }
    $line = [string] (Get-Content -LiteralPath $path -Raw)
    return $line.TrimEnd([char[]] @(13, 10))
}

function New-HealthResult {
    param(
        [string] $Name,
        [string] $Status,
        [string] $Detail
    )
    return [pscustomobject] @{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Get-FixtureResult {
    param(
        [string] $Name,
        [string] $FileName
    )

    $line = Read-FixtureLine $FileName
    $columns = $line -split "`t", 2
    if ($columns.Count -ne 2) {
        throw ('{0} must contain status and detail separated by a tab' -f $FileName)
    }
    $status = $columns[0].ToLowerInvariant()
    if ($status -notin @('pass', 'warn', 'unsupported', 'fail', 'error')) {
        throw ('invalid fixture status: {0}' -f $columns[0])
    }
    return (New-HealthResult -Name $Name -Status $status -Detail $columns[1])
}

function Get-DiskSamples {
    # Fixtures and Windows disks use the same small record shape.
    $samples = New-Object 'System.Collections.Generic.List[object]'

    if (-not [string]::IsNullOrWhiteSpace($env:HEALTH_FIXTURE_ROOT)) {
        $fixturePath = Join-Path $env:HEALTH_FIXTURE_ROOT 'windows-disks.tsv'
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw 'fixture is missing: windows-disks.tsv'
        }

        foreach ($line in Get-Content -LiteralPath $fixturePath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $columns = $line -split "`t", 3
            if ($columns.Count -ne 3) { throw 'invalid windows-disks.tsv row' }

            if ($columns[1] -eq 'missing' -or $columns[2] -eq 'missing') {
                $samples.Add([pscustomobject] @{
                    Name = $columns[0]
                    Size = 0.0
                    Free = 0.0
                    Readable = $false
                })
                continue
            }
            if ($columns[1] -notmatch '^\d+(?:\.\d+)?$' -or
                $columns[2] -notmatch '^\d+(?:\.\d+)?$') {
                throw 'invalid windows-disks.tsv row'
            }

            $size = [double]::Parse($columns[1], [Globalization.CultureInfo]::InvariantCulture)
            $free = [double]::Parse($columns[2], [Globalization.CultureInfo]::InvariantCulture)
            if ($size -le 0 -or $free -lt 0 -or $free -gt $size) {
                throw 'invalid disk size or free space in fixture'
            }
            $samples.Add([pscustomobject] @{
                Name = $columns[0]
                Size = $size
                Free = $free
                Readable = $true
            })
        }
        return $samples.ToArray()
    }

    $fixedDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3')
    foreach ($disk in $fixedDisks) {
        $diskName = [string] $disk.DeviceID
        if ([string]::IsNullOrWhiteSpace($diskName)) { $diskName = '<unknown>' }

        if ($null -eq $disk.Size -or $null -eq $disk.FreeSpace) {
            $samples.Add([pscustomobject] @{
                Name = $diskName
                Size = 0.0
                Free = 0.0
                Readable = $false
            })
            continue
        }

        $size = [double] $disk.Size
        $free = [double] $disk.FreeSpace
        if ($size -le 0 -or $free -lt 0 -or $free -gt $size) {
            $samples.Add([pscustomobject] @{
                Name = $diskName
                Size = 0.0
                Free = 0.0
                Readable = $false
            })
            continue
        }
        $samples.Add([pscustomobject] @{
            Name = $diskName
            Size = $size
            Free = $free
            Readable = $true
        })
    }
    return $samples.ToArray()
}

function Get-ProcessSamples {
    $samples = New-Object 'System.Collections.Generic.List[object]'

    if (-not [string]::IsNullOrWhiteSpace($env:HEALTH_FIXTURE_ROOT)) {
        $fixturePath = Join-Path $env:HEALTH_FIXTURE_ROOT 'windows-processes.tsv'
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw 'fixture is missing: windows-processes.tsv'
        }

        foreach ($line in Get-Content -LiteralPath $fixturePath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $columns = $line -split "`t", 3
            if ($columns.Count -ne 3 -or $columns[2] -notmatch '^(?i:true|false|1|0)$') {
                throw 'invalid windows-processes.tsv row'
            }
            $responding = $columns[2] -match '^(?i:true|1)$'
            $samples.Add([pscustomobject] @{
                Name = $columns[1]
                Id = $columns[0]
                Responding = $responding
            })
        }
        return $samples.ToArray()
    }

    foreach ($process in Get-Process) {
        if ($process.MainWindowHandle -ne 0) {
            $samples.Add([pscustomobject] @{
                Name = $process.ProcessName
                Id = $process.Id
                Responding = [bool] $process.Responding
            })
        }
    }
    return $samples.ToArray()
}

function Get-SudoResult {
    if (-not [string]::IsNullOrWhiteSpace($env:HEALTH_FIXTURE_ROOT)) {
        return (Get-FixtureResult -Name 'sudo' -FileName 'sudo-result.tsv')
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return (New-HealthResult -Name 'sudo' -Status 'pass' `
            -Detail 'PowerShell is running elevated')
    }
    if (Get-Command -Name sudo -ErrorAction SilentlyContinue) {
        return (New-HealthResult -Name 'sudo' -Status 'warn' `
            -Detail 'sudo is available, but non-interactive elevation was not attempted')
    }
    return (New-HealthResult -Name 'sudo' -Status 'warn' `
        -Detail 'session is not elevated and sudo is unavailable')
}

function Get-DiskResult {
    param([int] $DiskWarning)

    $diskSamples = @(Get-DiskSamples)
    $lowDisks = New-Object 'System.Collections.Generic.List[string]'
    $unreadableDisks = New-Object 'System.Collections.Generic.List[string]'

    foreach ($disk in $diskSamples) {
        if (-not $disk.Readable) {
            $unreadableDisks.Add($disk.Name)
            continue
        }

        $usedPercent = 100.0 * ($disk.Size - $disk.Free) / $disk.Size
        if ($usedPercent -ge $DiskWarning) {
            $formattedPercent = $usedPercent.ToString(
                'N1', [Globalization.CultureInfo]::InvariantCulture
            )
            $lowDisks.Add(('{0} {1}% used' -f $disk.Name, $formattedPercent))
        }
    }

    if ($diskSamples.Count -eq 0) {
        return (New-HealthResult -Name 'disk' -Status 'unsupported' `
            -Detail 'no fixed disks were found')
    }
    if ($lowDisks.Count -gt 0) {
        $detail = $lowDisks -join '; '
        if ($unreadableDisks.Count -gt 0) {
            $detail += '; scan incomplete: unreadable capacity data for ' +
                ($unreadableDisks -join ', ')
        }
        return (New-HealthResult -Name 'disk' -Status 'warn' -Detail $detail)
    }
    if ($unreadableDisks.Count -gt 0) {
        $detail = 'disk scan incomplete: unreadable capacity data for ' +
            ($unreadableDisks -join ', ')
        return (New-HealthResult -Name 'disk' -Status 'unsupported' -Detail $detail)
    }

    $detail = 'all fixed disks are below {0}% used' -f $DiskWarning
    return (New-HealthResult -Name 'disk' -Status 'pass' -Detail $detail)
}

function Get-ProcessResult {
    $processSamples = @(Get-ProcessSamples)
    $unresponsiveProcesses = New-Object 'System.Collections.Generic.List[string]'

    foreach ($process in $processSamples) {
        if (-not $process.Responding) {
            $unresponsiveProcesses.Add(('{0} (PID {1})' -f $process.Name, $process.Id))
        }
    }

    if ($unresponsiveProcesses.Count -eq 0) {
        return (New-HealthResult -Name 'processes' -Status 'pass' `
            -Detail 'no unresponsive GUI processes found')
    }
    $detail = 'unresponsive GUI processes: ' + ($unresponsiveProcesses -join ', ')
    return (New-HealthResult -Name 'processes' -Status 'warn' -Detail $detail)
}

function Get-UpdatesResult {
    if (-not [string]::IsNullOrWhiteSpace($env:HEALTH_FIXTURE_ROOT)) {
        return (Get-FixtureResult -Name 'updates' -FileName 'updates-result.tsv')
    }

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
        if ($searchResult.Updates.Count -eq 0) {
            return (New-HealthResult -Name 'updates' -Status 'pass' `
                -Detail 'no applicable updates are pending')
        }
        $detail = '{0} applicable update(s) are pending' -f $searchResult.Updates.Count
        return (New-HealthResult -Name 'updates' -Status 'warn' -Detail $detail)
    }
    catch {
        $detail = 'Windows Update search is unavailable: ' + $_.Exception.Message
        return (New-HealthResult -Name 'updates' -Status 'unsupported' -Detail $detail)
    }
}

function Invoke-HealthCheck {
    param(
        [string] $Name,
        [int] $DiskWarning
    )

    try {
        switch ($Name) {
            'sudo' { return (Get-SudoResult) }
            'disk' { return (Get-DiskResult -DiskWarning $DiskWarning) }
            'processes' { return (Get-ProcessResult) }
            'updates' { return (Get-UpdatesResult) }
            default { throw ('unknown check: {0}' -f $Name) }
        }
    }
    catch {
        return (New-HealthResult -Name $Name -Status 'error' `
            -Detail $_.Exception.Message)
    }
}

function Invoke-Remote {
    param(
        [string] $Remote,
        [string] $Identity,
        [int] $ConnectTimeout,
        [string[]] $ForwardArguments
    )

    $scriptPath = Join-Path $PSScriptRoot 'health-check.sh'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Check -Name remote -Status error `
            -Detail 'sibling health-check.sh is missing' -Plain $script:Plain
        return 2
    }
    $sshCommand = Get-Command -Name ssh -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $sshCommand) {
        Write-Check -Name remote -Status unsupported `
            -Detail 'ssh is unavailable' -Plain $script:Plain
        return 1
    }

    $sshArguments = @('-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ClearAllForwardings=yes',
        '-o', ('ConnectTimeout={0}' -f $ConnectTimeout))
    if (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $sshArguments += @('-o', 'IdentitiesOnly=yes', '-i', $Identity)
    }
    $sshArguments += $Remote

    $remoteCommandArguments = @('sh', '-s', '--') + $ForwardArguments
    $remoteCommand = ($remoteCommandArguments -join ' ')
    $sshArguments += $remoteCommand
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    $scriptText | & $sshCommand.Source @sshArguments
    $sshExitCode = $LASTEXITCODE
    if ($sshExitCode -eq 0) {
        return 0
    }
    if ($sshExitCode -eq 1) {
        return 1
    }
    return 2
}

$selected = New-Object 'System.Collections.Generic.List[string]'
$plain = $false
$help = $false
$version = $false
$all = $false
$remote = ''
$identity = ''
$diskWarning = 85
$connectTimeout = 10
$parseError = ''
if ($null -eq $Arguments) { $Arguments = @() }

for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $argument = $Arguments[$index]
    switch -CaseSensitive ($argument) {
        '--sudo' { $selected.Add('sudo'); continue }
        '--disk' { $selected.Add('disk'); continue }
        '--processes' { $selected.Add('processes'); continue }
        '--updates' { $selected.Add('updates'); continue }
        '--all' { $all = $true; continue }
        '--plain' { $plain = $true; continue }
        '-h' { $help = $true; continue }
        '--help' { $help = $true; continue }
        '--version' { $version = $true; continue }
        '--disk-warning' {
            $index++
            if ($index -ge $Arguments.Count -or $Arguments[$index] -notmatch '^\d+$') {
                $parseError = '--disk-warning requires an integer percentage from 1 to 100'
                break
            }
            $diskWarning = [int] $Arguments[$index]
            if ($diskWarning -lt 1 -or $diskWarning -gt 100) {
                $parseError = '--disk-warning must be between 1 and 100'
            }
            continue
        }
        '--remote' {
            $index++
            if ($index -ge $Arguments.Count) {
                $parseError = '--remote requires USER@HOST'
                break
            }
            $remote = $Arguments[$index]
            if ($remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*$') {
                $parseError = '--remote must be a valid USER@HOST value'
            }
            continue
        }
        '--identity' {
            $index++
            if ($index -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace($Arguments[$index])) {
                $parseError = '--identity requires a path'
                break
            }
            $identity = $Arguments[$index]
            continue
        }
        '--connect-timeout' {
            $index++
            if ($index -ge $Arguments.Count -or $Arguments[$index] -notmatch '^\d+$') {
                $parseError = '--connect-timeout requires a positive integer number of seconds'
                break
            }
            $connectTimeout = [int] $Arguments[$index]
            if ($connectTimeout -lt 1 -or $connectTimeout -gt 600) {
                $parseError = '--connect-timeout must be between 1 and 600 seconds'
            }
            continue
        }
        default {
            $parseError = ('unknown option: {0}' -f $argument)
            break
        }
    }
    if (-not [string]::IsNullOrEmpty($parseError)) { break }
}

if ([string]::IsNullOrEmpty($parseError) -and
    -not [string]::IsNullOrWhiteSpace($identity) -and
    [string]::IsNullOrWhiteSpace($remote)) {
    $parseError = '--identity requires --remote'
}
if ([string]::IsNullOrEmpty($parseError) -and
    -not [string]::IsNullOrWhiteSpace($identity) -and
    -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    $parseError = ('SSH identity is not readable: {0}' -f $identity)
}
if (-not [string]::IsNullOrEmpty($parseError)) {
    Write-Output ('Error: {0}' -f $parseError)
    Write-Usage
    exit 2
}
if ($help) {
    Write-Usage
    exit 0
}
if ($version) {
    Write-Output ('health-check.ps1 {0}' -f $script:ProgramVersion)
    exit 0
}
if ($all) {
    $selected.Clear()
    foreach ($name in @('sudo', 'disk', 'processes', 'updates')) { $selected.Add($name) }
}
$selected = @($selected | Select-Object -Unique)
if ($selected.Count -eq 0) {
    Write-Output ('Error: select at least one check with --sudo, --disk, ' +
        '--processes, --updates, or --all')
    Write-Usage
    exit 2
}

$script:Plain = $plain
if (-not [string]::IsNullOrEmpty($remote)) {
    $forwardArguments = @($selected | ForEach-Object { '--' + $_ })
    if ($all -and $selected.Count -eq 4) { $forwardArguments = @('--all') }
    if ($plain) { $forwardArguments += '--plain' }
    if ($diskWarning -ne 85) { $forwardArguments += @('--disk-warning', [string] $diskWarning) }
    $remoteExitCode = Invoke-Remote -Remote $remote -Identity $identity `
        -ConnectTimeout $connectTimeout -ForwardArguments $forwardArguments
    exit $remoteExitCode
}

$results = @()
foreach ($check in $selected) {
    $results += Invoke-HealthCheck -Name $check -DiskWarning $diskWarning
}

$exitCode = 0
foreach ($result in $results) {
    Write-Check -Name $result.Name -Status $result.Status -Detail $result.Detail -Plain $plain
    if ($result.Status -in @('fail', 'error')) { $exitCode = 2 }
    elseif ($result.Status -in @('warn', 'unsupported') -and $exitCode -eq 0) { $exitCode = 1 }
}
exit $exitCode
