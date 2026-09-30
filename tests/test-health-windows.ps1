param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Lines {
    param([string[]] $Expected, [string[]] $Actual, [string] $Message)
    Assert-True ($Actual.Count -eq $Expected.Count) $Message
    for ($lineIndex = 0; $lineIndex -lt $Expected.Count; $lineIndex++) {
        Assert-True ($Actual[$lineIndex] -ceq $Expected[$lineIndex]) `
            ('{0}: expected [{1}], got [{2}]' -f $Message, $Expected[$lineIndex], $Actual[$lineIndex])
    }
}

function Invoke-HealthCheck {
    param([string[]] $Arguments)
    $outputLines = @(& $script:healthCheckPath @Arguments)
    $resultCode = $LASTEXITCODE
    return [pscustomobject] @{ Output = $outputLines; ExitCode = $resultCode }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:healthCheckPath = Join-Path $repositoryRoot 'health-check.ps1'
if (-not (Test-Path -LiteralPath $script:healthCheckPath -PathType Leaf)) {
    throw 'health-check.ps1 is missing'
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('health-check-test-{0}' -f [Guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($fixtureRoot)
$previousFixtureRoot = $env:HEALTH_FIXTURE_ROOT
try {
    $env:HEALTH_FIXTURE_ROOT = $fixtureRoot
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'sudo-result.tsv') -Value "pass`tPowerShell is running elevated" -NoNewline
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') -Value "C:`t100`t5" -NoNewline
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-processes.tsv') -Value "42`tEditor`tfalse" -NoNewline
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'updates-result.tsv') -Value "pass`tNo applicable updates are pending" -NoNewline

    $sudoResult = Invoke-HealthCheck @('--sudo', '--plain')
    Assert-True ($sudoResult.ExitCode -eq 0) '--sudo should pass'
    Assert-Lines @("sudo`tpass`tPowerShell is running elevated") $sudoResult.Output '--sudo selection or plain output differs'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'sudo-result.tsv') `
        -Value "warn`tsudo is available, but non-interactive elevation was not attempted" `
        -NoNewline
    $sudoWarning = Invoke-HealthCheck @('--sudo', '--plain')
    Assert-True ($sudoWarning.ExitCode -eq 1) 'unverified sudo availability should warn'
    Assert-Lines @("sudo`twarn`tsudo is available, but non-interactive elevation was not attempted") `
        $sudoWarning.Output 'unverified sudo output differs'
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'sudo-result.tsv') `
        -Value "pass`tPowerShell is running elevated" -NoNewline

    $humanResult = Invoke-HealthCheck @('--sudo')
    Assert-True ($humanResult.ExitCode -eq 0) 'human-format sudo check should pass'
    Assert-Lines @('[PASS] sudo PowerShell is running elevated') $humanResult.Output 'human output differs'

    $diskResult = Invoke-HealthCheck @('--disk', '--disk-warning', '90', '--plain')
    Assert-True ($diskResult.ExitCode -eq 1) '--disk above the used-space threshold should warn'
    Assert-Lines @("disk`twarn`tC: 95.0% used") $diskResult.Output '--disk output differs'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') -Value '' -NoNewline
    $unsupportedDiskResult = Invoke-HealthCheck @('--disk', '--plain')
    Assert-True ($unsupportedDiskResult.ExitCode -eq 1) 'unsupported disk check should exit 1'
    Assert-Lines @("disk`tunsupported`tno fixed disks were found") `
        $unsupportedDiskResult.Output 'unsupported disk output differs'
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') `
        -Value "C:`t100`t5" -NoNewline

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') -Value @(
        "C:`t100`t50",
        "D:`tmissing`tmissing"
    )
    $incompleteDiskResult = Invoke-HealthCheck @('--disk', '--plain')
    Assert-True ($incompleteDiskResult.ExitCode -eq 1) 'incomplete disk check should exit 1'
    Assert-Lines @("disk`tunsupported`tdisk scan incomplete: unreadable capacity data for D:") `
        $incompleteDiskResult.Output 'incomplete disk output differs'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') -Value @(
        "C:`t100`t5",
        "D:`tmissing`tmissing"
    )
    $warningIncompleteDiskResult = Invoke-HealthCheck @('--disk', '--plain')
    Assert-True ($warningIncompleteDiskResult.ExitCode -eq 1) `
        'warning plus incomplete disk check should exit 1'
    Assert-Lines @("disk`twarn`tC: 95.0% used; scan incomplete: unreadable capacity data for D:") `
        $warningIncompleteDiskResult.Output 'warning plus incomplete disk output differs'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-disks.tsv') `
        -Value "C:`t100`t5" -NoNewline

    $processResult = Invoke-HealthCheck @('--processes', '--plain')
    Assert-True ($processResult.ExitCode -eq 1) 'unresponsive GUI process should warn'
    Assert-Lines @("processes`twarn`tunresponsive GUI processes: Editor (PID 42)") `
        $processResult.Output '--processes output differs'

    $allResult = Invoke-HealthCheck @('--all', '--plain')
    Assert-True ($allResult.ExitCode -eq 1) '--all should aggregate warning statuses'
    Assert-Lines @(
        "sudo`tpass`tPowerShell is running elevated",
        "disk`twarn`tC: 95.0% used",
        "processes`twarn`tunresponsive GUI processes: Editor (PID 42)",
        "updates`tpass`tNo applicable updates are pending"
    ) $allResult.Output '--all selection or output differs'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'updates-result.tsv') -Value "fail`tWindows Update access denied" -NoNewline
    $failureResult = Invoke-HealthCheck @('--updates', '--plain')
    Assert-True ($failureResult.ExitCode -eq 2) 'failed check should exit 2'
    Assert-Lines @("updates`tfail`tWindows Update access denied") $failureResult.Output 'failed status output differs'

    $noSelectionResult = Invoke-HealthCheck @()
    Assert-True ($noSelectionResult.ExitCode -eq 2) 'no selected checks should be a usage error'
    Assert-True (@($noSelectionResult.Output | Where-Object { $_ -match '^Usage: health-check\.ps1' }).Count -eq 1) `
        'no-selection error should print usage'

    $invalidNumberResult = Invoke-HealthCheck @('--disk', '--disk-warning', '101')
    Assert-True ($invalidNumberResult.ExitCode -eq 2) 'invalid numeric values should be usage errors'

    $invalidRemoteResult = Invoke-HealthCheck @('--sudo', '--remote', 'user@bad host')
    Assert-True ($invalidRemoteResult.ExitCode -eq 2) 'invalid remote hosts should be usage errors'

    $optionRemoteResult = Invoke-HealthCheck @('--sudo', '--remote', '-x@host.test')
    Assert-True ($optionRemoteResult.ExitCode -eq 2) `
        'remote usernames that resemble SSH options should be rejected'

    $invalidTimeoutResult = Invoke-HealthCheck @('--sudo', '--connect-timeout', '0')
    Assert-True ($invalidTimeoutResult.ExitCode -eq 2) 'invalid connection timeouts should be usage errors'

    $mockSshPath = Join-Path $fixtureRoot 'ssh.cmd'
    Set-Content -LiteralPath $mockSshPath -Encoding ASCII -Value @(
        '@echo off',
        'echo %* >"%HEALTH_SSH_CAPTURE%"',
        'findstr /C:"Usage: health-check.sh" >nul',
        'if errorlevel 1 exit /b 91',
        'if defined HEALTH_SSH_STATUS exit /b %HEALTH_SSH_STATUS%',
        "echo disk`tpass`tmock remote disk output",
        'exit /b 0'
    )
    $mockIdentityPath = Join-Path $fixtureRoot 'mock identity'
    Set-Content -LiteralPath $mockIdentityPath -Value 'fixture only' -NoNewline
    $sshCapturePath = Join-Path $fixtureRoot 'ssh-arguments.txt'
    $previousPath = $env:PATH
    $previousSshCapture = $env:HEALTH_SSH_CAPTURE
    $previousSshStatus = $env:HEALTH_SSH_STATUS
    try {
        $env:PATH = $fixtureRoot + [IO.Path]::PathSeparator + $env:PATH
        $env:HEALTH_SSH_CAPTURE = $sshCapturePath
        Remove-Item Env:HEALTH_SSH_STATUS -ErrorAction SilentlyContinue

        $remoteResult = Invoke-HealthCheck @('--disk', '--plain', '--disk-warning', '91',
            '--remote', 'user@example.test', '--identity', $mockIdentityPath,
            '--connect-timeout', '17')
        Assert-True ($remoteResult.ExitCode -eq 0) 'mock SSH execution should pass'
        Assert-Lines @("disk`tpass`tmock remote disk output") $remoteResult.Output `
            'mock SSH output differs'

        $sshArguments = Get-Content -LiteralPath $sshCapturePath -Raw
        foreach ($requiredArgument in @('-T', 'BatchMode=yes', 'StrictHostKeyChecking=yes',
                'ClearAllForwardings=yes', 'IdentitiesOnly=yes', 'ConnectTimeout=17',
                $mockIdentityPath, 'user@example.test', 'sh -s -- --disk --plain',
                '--disk-warning 91')) {
            Assert-True ($sshArguments.Contains($requiredArgument)) `
                ('mock SSH arguments omitted: {0}' -f $requiredArgument)
        }

        foreach ($sshFailureCode in @(255, 7)) {
            $env:HEALTH_SSH_STATUS = [string] $sshFailureCode
            $sshFailureResult = Invoke-HealthCheck @('--disk', '--plain',
                '--remote', 'user@example.test')
            Assert-True ($sshFailureResult.ExitCode -eq 2) `
                ('SSH status {0} should map to exit 2' -f $sshFailureCode)
        }
    }
    finally {
        $env:PATH = $previousPath
        if ($null -eq $previousSshCapture) {
            Remove-Item Env:HEALTH_SSH_CAPTURE -ErrorAction SilentlyContinue
        }
        else { $env:HEALTH_SSH_CAPTURE = $previousSshCapture }
        if ($null -eq $previousSshStatus) {
            Remove-Item Env:HEALTH_SSH_STATUS -ErrorAction SilentlyContinue
        }
        else { $env:HEALTH_SSH_STATUS = $previousSshStatus }
    }

    $helpResult = Invoke-HealthCheck @('--help')
    Assert-True ($helpResult.ExitCode -eq 0) '--help should exit 0'
    $expectedHelp = @(
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
    Assert-Lines $expectedHelp $helpResult.Output '--help output differs'

    $shortHelpResult = Invoke-HealthCheck @('-h')
    Assert-True ($shortHelpResult.ExitCode -eq 0) '-h should exit 0'
    Assert-Lines $expectedHelp $shortHelpResult.Output '-h output differs'

    $versionResult = Invoke-HealthCheck @('--version')
    Assert-True ($versionResult.ExitCode -eq 0) '--version should exit 0'
    Assert-Lines @('health-check.ps1 0.1.0') $versionResult.Output '--version output differs'

    Write-Output ('Windows health-check tests passed under PowerShell {0}.' -f $PSVersionTable.PSVersion)
}
finally {
    if ($null -eq $previousFixtureRoot) { Remove-Item Env:HEALTH_FIXTURE_ROOT -ErrorAction SilentlyContinue }
    else { $env:HEALTH_FIXTURE_ROOT = $previousFixtureRoot }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
