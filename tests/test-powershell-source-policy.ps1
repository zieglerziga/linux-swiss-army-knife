param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectorPath = Join-Path $repositoryRoot 'swiss.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $collectorPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw 'PowerShell parser rejected swiss.ps1 during the source-policy audit'
}

$allowedCommands = @(
    'ConvertTo-Json',
    'Get-CimInstance',
    'Get-Command',
    'Get-DnsClientServerAddress',
    'Get-NetAdapter',
    'Get-NetIPAddress',
    'Get-NetRoute',
    'New-Object',
    'Select-Object',
    'Set-StrictMode',
    'Sort-Object',
    'Write-Output'
)
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name })

$observedCommands = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)
$commandAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
foreach ($commandAst in $commandAsts) {
    $commandName = $commandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        throw ('Dynamic PowerShell command invocation is forbidden: {0}' -f `
            $commandAst.Extent.Text)
    }
    if ($commandName -notin $allowedCommands -and $commandName -notin $functions) {
        throw ('PowerShell command is not allowlisted: {0}' -f $commandName)
    }
    [void] $observedCommands.Add($commandName)
}

foreach ($allowedCommand in $allowedCommands) {
    if (-not $observedCommands.Contains($allowedCommand)) {
        throw ('PowerShell allowlist entry is not used: {0}' -f $allowedCommand)
    }
}

$forbiddenTypes = '(?i)System\.Net\.|System\.IO\.File|Microsoft\.Win32\.Registry'
$forbiddenMembers = '(?i)::(WriteAll|AppendAll|Create|Delete|Move|Copy|SetAccessControl)'
if ($ast.Extent.Text -match $forbiddenTypes -or $ast.Extent.Text -match $forbiddenMembers) {
    throw 'swiss.ps1 references a forbidden networking or mutating .NET API'
}

Write-Output 'PowerShell command/API allowlist audit passed.'
