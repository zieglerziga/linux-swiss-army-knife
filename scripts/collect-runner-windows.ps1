# Collect public, read-only specifications from a GitHub-hosted Windows runner.
# The workflow supplies the selected label and Actions context.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-EnvironmentValue {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "runner collection failed: $Name is not set"
    }

    return $value
}

$runnerLabel = Require-EnvironmentValue 'RUNNER_LABEL'
$runnerOs = Require-EnvironmentValue 'RUNNER_OS'
$runnerArchitecture = Require-EnvironmentValue 'RUNNER_ARCH'

# Get-CimInstance queries the local operating-system and computer inventory; it
# does not modify the runner. No network calls or package tools are invoked.
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem

$record = [ordered]@{
    schema_version = '1'
    collected_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    runner = [ordered]@{
        label = $runnerLabel
        os = $runnerOs
        architecture = $runnerArchitecture
    }
    image = [ordered]@{
        os = [string]$env:ImageOS
        version = [string]$env:ImageVersion
    }
    system = [ordered]@{
        name = [string]$operatingSystem.Caption
        version = [string]$operatingSystem.Version
        build = [string]$operatingSystem.BuildNumber
        kernel_name = 'Windows NT'
        kernel_release = [string]$operatingSystem.Version
        machine_architecture = [string]$computerSystem.SystemType
    }
    tools = [ordered]@{
        xcode_version = ''
    }
}

$record | ConvertTo-Json -Compress -Depth 4
