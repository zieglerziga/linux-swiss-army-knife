param()

# Execute native Windows checks and validate the result rows. A warning is a
# successful smoke outcome because it is meaningful health data.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$healthCheck = Join-Path $repositoryRoot 'health-check.ps1'
$outputLines = @(& $healthCheck --plain --all)
$healthStatus = $LASTEXITCODE

if ($healthStatus -gt 1) {
    throw ('health-check.ps1 returned unexpected status {0}' -f $healthStatus)
}
if ($outputLines.Count -ne 4) {
    throw ('expected four health-check rows, got {0}' -f $outputLines.Count)
}

$seen = @{}
foreach ($line in $outputLines) {
    $columns = $line -split "`t", 3
    if ($columns.Count -ne 3) {
        throw ('health-check row is not three-column TSV: {0}' -f $line)
    }
    if ($columns[0] -notin @('sudo', 'disk', 'processes', 'updates')) {
        throw ('unexpected health-check name: {0}' -f $columns[0])
    }
    if ($columns[1] -notin @('pass', 'warn', 'unsupported')) {
        throw ('unexpected health-check status: {0}' -f $columns[1])
    }
    $seen[$columns[0]] = $true
}
foreach ($expectedCheck in @('sudo', 'disk', 'processes', 'updates')) {
    if (-not $seen.ContainsKey($expectedCheck)) {
        throw ('native health-check output omitted {0}' -f $expectedCheck)
    }
}

$outputLines | Write-Output
Write-Output 'Native Windows health-check output smoke passed.'
