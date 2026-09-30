param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Usage {
    Write-Output 'Usage: health-check.ps1 [--sudo] [--disk] [--processes] [--updates] [--all] [--plain] [--disk-warning PERCENT] [--remote USER@HOST] [--identity PATH] [--connect-timeout SECONDS] [--help]'
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

function Convert-FixtureResult {
    param([string] $Line)

    $columns = $Line -split "`t", 2
    if ($columns.Count -ne 2) {
        throw 'fixture result must contain status and detail separated by a tab'
    }
    $status = $columns[0].ToLowerInvariant()
    if ($status -notin @('pass', 'warn', 'unsupported', 'fail', 'error')) {
        throw ('invalid fixture status: {0}' -f $columns[0])
    }
    return @($status, $columns[1])
}

function Add-Result {
    param(
        [System.Collections.Generic.List[object]] $Results,
        [string] $Name,
        [string] $Status,
        [string] $Detail
    )
    $Results.Add([pscustomobject] @{ Name = $Name; Status = $Status; Detail = $Detail })
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
        Write-Check -Name remote -Status error -Detail 'sibling health-check.sh is missing' -Plain $script:Plain
        return 2
    }
    $sshCommand = Get-Command -Name ssh -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $sshCommand) {
        Write-Check -Name remote -Status unsupported -Detail 'ssh is unavailable' -Plain $script:Plain
        return 1
    }

    $sshArguments = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', ('ConnectTimeout={0}' -f $ConnectTimeout))
    if (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $sshArguments += @('-i', $Identity)
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
        '--help' { $help = $true; continue }
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
if ($all) {
    $selected.Clear()
    foreach ($name in @('sudo', 'disk', 'processes', 'updates')) { $selected.Add($name) }
}
$selected = @($selected | Select-Object -Unique)
if ($selected.Count -eq 0) {
    Write-Output 'Error: select at least one check with --sudo, --disk, --processes, --updates, or --all'
    Write-Usage
    exit 2
}

$script:Plain = $plain
if (-not [string]::IsNullOrEmpty($remote)) {
    $forwardArguments = @($selected | ForEach-Object { '--' + $_ })
    if ($all -and $selected.Count -eq 4) { $forwardArguments = @('--all') }
    if ($plain) { $forwardArguments += '--plain' }
    if ($diskWarning -ne 85) { $forwardArguments += @('--disk-warning', [string] $diskWarning) }
    exit (Invoke-Remote -Remote $remote -Identity $identity -ConnectTimeout $connectTimeout -ForwardArguments $forwardArguments)
}

$results = New-Object 'System.Collections.Generic.List[object]'
foreach ($check in $selected) {
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:HEALTH_FIXTURE_ROOT)) {
            switch ($check) {
                'sudo' {
                    $fixture = Convert-FixtureResult (Read-FixtureLine 'sudo-result.tsv')
                    Add-Result $results 'sudo' $fixture[0] $fixture[1]
                }
                'disk' {
                    $fixturePath = Join-Path $env:HEALTH_FIXTURE_ROOT 'windows-disks.tsv'
                    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw 'fixture is missing: windows-disks.tsv' }
                    $lowDisks = New-Object 'System.Collections.Generic.List[string]'
                    $validDiskCount = 0
                    foreach ($line in Get-Content -LiteralPath $fixturePath) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        $columns = $line -split "`t", 3
                        if ($columns.Count -ne 3 -or $columns[1] -notmatch '^\d+(?:\.\d+)?$' -or $columns[2] -notmatch '^\d+(?:\.\d+)?$') { throw 'invalid windows-disks.tsv row' }
                        $size = [double]::Parse($columns[1], [Globalization.CultureInfo]::InvariantCulture)
                        $free = [double]::Parse($columns[2], [Globalization.CultureInfo]::InvariantCulture)
                        if ($size -le 0 -or $free -lt 0 -or $free -gt $size) { throw 'invalid disk size or free space in fixture' }
                        $validDiskCount++
                        $usedPercent = 100.0 * ($size - $free) / $size
                        if ($usedPercent -ge $diskWarning) {
                            $lowDisks.Add(('{0} {1}% used' -f $columns[0],
                                $usedPercent.ToString('N1', [Globalization.CultureInfo]::InvariantCulture)))
                        }
                    }
                    if ($validDiskCount -eq 0) { Add-Result $results 'disk' 'unsupported' 'no fixed disks were found' }
                    elseif ($lowDisks.Count -eq 0) { Add-Result $results 'disk' 'pass' ('all fixed disks are below {0}% used' -f $diskWarning) }
                    else { Add-Result $results 'disk' 'warn' ($lowDisks -join '; ') }
                }
                'processes' {
                    $fixturePath = Join-Path $env:HEALTH_FIXTURE_ROOT 'windows-processes.tsv'
                    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw 'fixture is missing: windows-processes.tsv' }
                    $hung = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($line in Get-Content -LiteralPath $fixturePath) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        $columns = $line -split "`t", 3
                        if ($columns.Count -ne 3 -or $columns[2] -notmatch '^(?i:true|false|1|0)$') { throw 'invalid windows-processes.tsv row' }
                        if ($columns[2] -match '^(?i:false|0)$') { $hung.Add(('{0} (PID {1})' -f $columns[1], $columns[0])) }
                    }
                    if ($hung.Count -eq 0) { Add-Result $results 'processes' 'pass' 'no unresponsive GUI processes found' }
                    else { Add-Result $results 'processes' 'warn' ('unresponsive GUI processes: ' + ($hung -join ', ')) }
                }
                'updates' {
                    $fixture = Convert-FixtureResult (Read-FixtureLine 'updates-result.tsv')
                    Add-Result $results 'updates' $fixture[0] $fixture[1]
                }
            }
            continue
        }

        switch ($check) {
            'sudo' {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object Security.Principal.WindowsPrincipal($identity)
                if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    Add-Result $results 'sudo' 'pass' 'PowerShell is running elevated'
                }
                elseif (Get-Command -Name sudo -ErrorAction SilentlyContinue) {
                    Add-Result $results 'sudo' 'warn' `
                        'sudo is available, but non-interactive elevation was not attempted'
                }
                else {
                    Add-Result $results 'sudo' 'warn' 'session is not elevated and sudo is unavailable'
                }
            }
            'disk' {
                $lowDisks = New-Object 'System.Collections.Generic.List[string]'
                $fixedDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3')
                $validDiskCount = 0
                foreach ($disk in $fixedDisks) {
                    if ($null -eq $disk.Size -or $null -eq $disk.FreeSpace -or
                        [double] $disk.Size -le 0) { continue }
                    $validDiskCount++
                    $usedPercent = 100.0 * ([double] $disk.Size - [double] $disk.FreeSpace) / [double] $disk.Size
                    if ($usedPercent -ge $diskWarning) {
                        $lowDisks.Add(('{0} {1}% used' -f $disk.DeviceID,
                            $usedPercent.ToString('N1', [Globalization.CultureInfo]::InvariantCulture)))
                    }
                }
                if ($validDiskCount -eq 0) { Add-Result $results 'disk' 'unsupported' 'no fixed disks were found' }
                elseif ($lowDisks.Count -eq 0) { Add-Result $results 'disk' 'pass' ('all fixed disks are below {0}% used' -f $diskWarning) }
                else { Add-Result $results 'disk' 'warn' ($lowDisks -join '; ') }
            }
            'processes' {
                $hung = New-Object 'System.Collections.Generic.List[string]'
                foreach ($process in Get-Process) {
                    if ($process.MainWindowHandle -ne 0 -and -not $process.Responding) {
                        $hung.Add(('{0} (PID {1})' -f $process.ProcessName, $process.Id))
                    }
                }
                if ($hung.Count -eq 0) { Add-Result $results 'processes' 'pass' 'no unresponsive GUI processes found' }
                else { Add-Result $results 'processes' 'warn' ('unresponsive GUI processes: ' + ($hung -join ', ')) }
            }
            'updates' {
                try {
                    $session = New-Object -ComObject Microsoft.Update.Session
                    $searcher = $session.CreateUpdateSearcher()
                    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
                    if ($searchResult.Updates.Count -eq 0) { Add-Result $results 'updates' 'pass' 'no applicable updates are pending' }
                    else { Add-Result $results 'updates' 'warn' ('{0} applicable update(s) are pending' -f $searchResult.Updates.Count) }
                }
                catch {
                    Add-Result $results 'updates' 'unsupported' ('Windows Update search is unavailable: ' + $_.Exception.Message)
                }
            }
        }
    }
    catch {
        Add-Result $results $check 'error' $_.Exception.Message
    }
}

$exitCode = 0
foreach ($result in $results) {
    Write-Check -Name $result.Name -Status $result.Status -Detail $result.Detail -Plain $plain
    if ($result.Status -in @('fail', 'error')) { $exitCode = 2 }
    elseif ($result.Status -in @('warn', 'unsupported') -and $exitCode -eq 0) { $exitCode = 1 }
}
exit $exitCode
