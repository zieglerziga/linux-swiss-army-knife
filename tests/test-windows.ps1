param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectorPath = Join-Path $repositoryRoot 'swiss.ps1'
$fieldPath = Join-Path $repositoryRoot 'schema/fields-v1.txt'
Assert-True (Test-Path -LiteralPath $collectorPath -PathType Leaf) `
    'swiss.ps1 is missing'

$versionOutput = (& $collectorPath --version | Out-String).Trim()
Assert-True ($versionOutput -eq 'linux-swiss-army-knife 0.1.0') `
    '--version output is incorrect'
$helpOutput = (& $collectorPath --help | Out-String)
Assert-True ($helpOutput -match '^Usage: swiss\.ps1') '--help output is incorrect'

$jsonText = (& $collectorPath --json | Out-String)
$report = $jsonText | ConvertFrom-Json
Assert-True ($report.schema_version -eq '1') 'schema version is incorrect'
Assert-True (@($report.facts).Count -eq 42) 'report does not contain 42 facts'

$expectedFields = @(Get-Content -LiteralPath $fieldPath)
$actualFields = @($report.facts | ForEach-Object { $_.key })
Assert-True ($actualFields.Count -eq $expectedFields.Count) 'field count differs from manifest'
for ($index = 0; $index -lt $expectedFields.Count; $index++) {
    Assert-True ($actualFields[$index] -eq $expectedFields[$index]) `
        ('field mismatch at index {0}: expected {1}, got {2}' -f `
            $index, $expectedFields[$index], $actualFields[$index])
}
Assert-True (@($actualFields | Sort-Object -Unique).Count -eq 42) 'fact keys are duplicated'

$validStatuses = @('ok', 'unknown', 'unsupported', 'missing', 'denied', 'error')
$validConfidence = @('exact', 'derived', 'heuristic')
foreach ($fact in $report.facts) {
    Assert-True ($fact.status -in $validStatuses) ('invalid status for {0}' -f $fact.key)
    Assert-True ($fact.confidence -in $validConfidence) `
        ('invalid confidence for {0}' -f $fact.key)
    Assert-True (-not [string]::IsNullOrWhiteSpace($fact.source)) `
        ('empty source for {0}' -f $fact.key)
}

if ($env:OS -eq 'Windows_NT') {
    Assert-True ($report.collector.platform -eq 'windows') 'Windows adapter was not selected'
    $family = $report.facts | Where-Object key -eq 'system.os.family'
    Assert-True ($family.value -eq 'windows' -and $family.status -eq 'ok') `
        'Windows OS family probe failed'
}
else {
    Assert-True ($report.collector.platform -eq 'unknown') `
        'non-Windows test host should use the unknown adapter'

    $previousTestWindows = $env:SWISS_TEST_WINDOWS
    try {
        $env:SWISS_TEST_WINDOWS = '1'
        $emulatedReport = (& $collectorPath --json | Out-String) | ConvertFrom-Json
    }
    finally {
        $env:SWISS_TEST_WINDOWS = $previousTestWindows
    }
    Assert-True ($emulatedReport.collector.platform -eq 'windows') `
        'emulated Windows adapter was not selected'
    Assert-True (@($emulatedReport.facts).Count -eq 42) `
        'emulated Windows adapter did not emit 42 facts'
    $emulatedFields = @($emulatedReport.facts | ForEach-Object { $_.key })
    for ($index = 0; $index -lt $expectedFields.Count; $index++) {
        Assert-True ($emulatedFields[$index] -eq $expectedFields[$index]) `
            ('emulated Windows field mismatch at index {0}' -f $index)
    }
    $emulatedFamily = $emulatedReport.facts | Where-Object key -eq 'system.os.family'
    Assert-True ($emulatedFamily.value -eq 'windows') `
        'emulated Windows OS family probe failed'
}

$plainLines = @(& $collectorPath --plain)
Assert-True ($plainLines.Count -eq 42) 'plain output does not contain 42 lines'
foreach ($line in $plainLines) {
    Assert-True (($line -split "`t").Count -eq 4) 'plain output is not four columns'
}
$debugLines = @(& $collectorPath --plain --debug)
Assert-True ($debugLines.Count -eq 42) 'debug output does not contain 42 lines'
foreach ($line in $debugLines) {
    Assert-True (($line -split "`t").Count -eq 5) 'debug output is not five columns'
}

$fullReport = (& $collectorPath --json --full | Out-String) | ConvertFrom-Json
Assert-True ($fullReport.collector.mode -eq 'full') '--full mode was not recorded'

Write-Output ('Windows collector tests passed under PowerShell {0}.' -f `
    $PSVersionTable.PSVersion)
