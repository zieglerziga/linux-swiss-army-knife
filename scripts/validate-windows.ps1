[CmdletBinding()]
param()

# This validator reads runner metadata and parses project source. It never
# invokes project entry points, installs tools, or changes runner configuration.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Expected,

        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    if ($Actual -ne $Expected) {
        throw ('Expected {0} to be {1}, got {2}' -f $Description, $Expected, $Actual)
    }
}

$requiredEnvironment = @(
    'RUNNER_LABEL',
    'EXPECTED_RUNNER_OS',
    'EXPECTED_RUNNER_ARCH',
    'EXPECTED_OS_FAMILY',
    'EXPECTED_VS_MAJOR',
    'ACTUAL_RUNNER_OS',
    'ACTUAL_RUNNER_ARCH'
)

foreach ($name in $requiredEnvironment) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw ('Required environment variable is missing: {0}' -f $name)
    }
}

Assert-Equal -Expected $env:EXPECTED_RUNNER_OS -Actual $env:ACTUAL_RUNNER_OS `
    -Description 'runner operating system'
Assert-Equal -Expected $env:EXPECTED_RUNNER_ARCH -Actual $env:ACTUAL_RUNNER_ARCH `
    -Description 'runner architecture'

if ($env:EXPECTED_RUNNER_OS -ne 'Windows') {
    throw ('Unsupported expected runner OS: {0}' -f $env:EXPECTED_RUNNER_OS)
}

$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Expected a 64-bit Windows operating system'
}

switch ($env:EXPECTED_RUNNER_ARCH) {
    'X64' {
        if ($processor.Architecture -ne 9) {
            throw ('Expected native x64 processor architecture, got CIM value {0}' -f `
                $processor.Architecture)
        }
    }
    'ARM64' {
        if ($processor.Architecture -ne 12) {
            throw ('Expected native ARM64 processor architecture, got CIM value {0}' -f `
                $processor.Architecture)
        }
    }
    default {
        throw ('Unsupported expected architecture: {0}' -f $env:EXPECTED_RUNNER_ARCH)
    }
}

switch ($env:EXPECTED_OS_FAMILY) {
    'server-2022' {
        if ($operatingSystem.Caption -notmatch 'Windows Server 2022') {
            throw ('Expected Windows Server 2022, got {0}' -f $operatingSystem.Caption)
        }
    }
    'server-2025' {
        if ($operatingSystem.Caption -notmatch 'Windows Server 2025') {
            throw ('Expected Windows Server 2025, got {0}' -f $operatingSystem.Caption)
        }
    }
    'windows-11' {
        if ($operatingSystem.Caption -notmatch 'Windows 11') {
            throw ('Expected Windows 11, got {0}' -f $operatingSystem.Caption)
        }
    }
    default {
        throw ('Unsupported expected OS family: {0}' -f $env:EXPECTED_OS_FAMILY)
    }
}

if ($env:EXPECTED_VS_MAJOR -ne 'none' -and $env:EXPECTED_VS_MAJOR -ne 'any') {
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswherePath = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
        throw ('vswhere is unavailable at {0}' -f $vswherePath)
    }

    $versionRange = '[{0}.0,{1}.0)' -f $env:EXPECTED_VS_MAJOR, ([int] $env:EXPECTED_VS_MAJOR + 1)
    $visualStudioVersion = & $vswherePath -latest -products '*' -version $versionRange `
        -property installationVersion
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($visualStudioVersion)) {
        throw ('Visual Studio major version {0} was not found' -f $env:EXPECTED_VS_MAJOR)
    }
    if ($visualStudioVersion -notmatch ('^{0}\.' -f $env:EXPECTED_VS_MAJOR)) {
        throw ('Unexpected Visual Studio version: {0}' -f $visualStudioVersion)
    }
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $repositoryRoot
try {
    $powerShellFiles = @(& git ls-files --cached --others --exclude-standard -- `
        '*.ps1' '*.psm1' '*.psd1')
    if ($LASTEXITCODE -ne 0) {
        throw 'git failed while enumerating PowerShell source'
    }

    foreach ($file in $powerShellFiles) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            continue
        }

        $tokens = $null
        $parseErrors = $null
        $path = Join-Path $repositoryRoot $file
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref] $tokens,
            [ref] $parseErrors
        )

        if (@($parseErrors).Count -gt 0) {
            foreach ($parseError in $parseErrors) {
                Write-Error ('{0}: {1}' -f $file, $parseError.Message)
            }
            throw ('PowerShell parser rejected {0}' -f $file)
        }

        Write-Host ('PowerShell parser accepted: {0}' -f $file)
    }

    $bash = Get-Command -Name bash -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $shellFiles = @(& git ls-files --cached --others --exclude-standard -- '*.sh')
    if ($LASTEXITCODE -ne 0) {
        throw 'git failed while enumerating shell source'
    }
    if ($shellFiles.Count -eq 0) {
        throw 'No shell scripts were found'
    }

    foreach ($file in $shellFiles) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            continue
        }

        Write-Host ('Parsing with Git Bash without execution: {0}' -f $file)
        & $bash.Source -n -- $file
        if ($LASTEXITCODE -ne 0) {
            throw ('Bash parser rejected {0}' -f $file)
        }
    }
}
finally {
    Pop-Location
}

Write-Host ('Runner label: {0}' -f $env:RUNNER_LABEL)
Write-Host ('Runner context: {0}/{1}' -f $env:ACTUAL_RUNNER_OS, $env:ACTUAL_RUNNER_ARCH)
Write-Host ('Operating system: {0} {1} build {2}' -f `
    $operatingSystem.Caption, $operatingSystem.Version, $operatingSystem.BuildNumber)
Write-Host ('Process architecture: {0}' -f $env:PROCESSOR_ARCHITECTURE)
Write-Host ('Runner image: {0} {1}' -f $env:ImageOS, $env:ImageVersion)
Write-Host ('PowerShell: {0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
