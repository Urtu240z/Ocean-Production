[CmdletBinding()]
param([string]$GodotExe,[string]$PythonExe,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'target_validation_common.ps1')
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $script:TargetRepo '.godot/target_validation/preflight' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$environment=Get-TargetEnvironment $GodotExe $PythonExe $OutputDirectory
Save-TargetJson $environment (Join-Path $OutputDirectory 'environment.json')
Write-Host "PREFLIGHT PASS | $($environment.godot) | MSVC $($environment.msvc) | SDK $($environment.windows_sdk) | exact target=$($environment.is_exact_target)"
