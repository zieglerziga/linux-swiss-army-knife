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

    $helpResult = Invoke-HealthCheck @('--help')
    Assert-True ($helpResult.ExitCode -eq 0) '--help should exit 0'
    Assert-Lines @('Usage: health-check.ps1 [--sudo] [--disk] [--processes] [--updates] [--all] [--plain] [--disk-warning PERCENT] [--remote USER@HOST] [--identity PATH] [--connect-timeout SECONDS] [--help]') `
        $helpResult.Output '--help output differs'

    Write-Output ('Windows health-check tests passed under PowerShell {0}.' -f $PSVersionTable.PSVersion)
}
finally {
    if ($null -eq $previousFixtureRoot) { Remove-Item Env:HEALTH_FIXTURE_ROOT -ErrorAction SilentlyContinue }
    else { $env:HEALTH_FIXTURE_ROOT = $previousFixtureRoot }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
