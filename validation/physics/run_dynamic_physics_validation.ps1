[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [ValidateRange(600, 100000)][int]$SteadyTicks = 10000,
    [ValidateRange(600, 100000)][int]$LoadTicks = 3600,
    [switch]$IncludeDirectOracle
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$godot = (Resolve-Path -LiteralPath $GodotExe).Path
$outputRoot = Join-Path $repoRoot '.godot'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

function Invoke-PhysicsValidation([string]$Name, [string]$Runner, [string[]]$UserArgs = @(), [switch]$Headless) {
    $arguments = @('--path', ('"{0}"' -f $repoRoot), '--log-file', ('"{0}"' -f (Join-Path $outputRoot "$Name.log")), '--script', "res://validation/physics/$Runner")
    if ($Headless) { $arguments += '--headless' }
    else { $arguments += @('--rendering-method', 'forward_plus', '--rendering-driver', 'd3d12') }
    if ($UserArgs.Count) { $arguments += '--'; $arguments += $UserArgs }
    Write-Host "RUN $Name"
    $process = Start-Process -FilePath $godot -ArgumentList $arguments -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $outputRoot "$Name.stdout.log") -RedirectStandardError (Join-Path $outputRoot "$Name.stderr.log")
    if ($process.ExitCode -ne 0) { throw "$Name failed (exit $($process.ExitCode)); inspect .godot/$Name.log" }
    Write-Host "PASS $Name"
}

Invoke-PhysicsValidation 'phys_spectrum_port' 'phys_spectrum_port_runner.gd' -Headless
Invoke-PhysicsValidation 'phys_weather' 'phys_weather_runner.gd'
Invoke-PhysicsValidation 'phys_weather_freshness' 'phys_weather_freshness_runner.gd'
Invoke-PhysicsValidation 'phys_recovery_steady' 'phys_recovery_runner.gd' @("--ticks=$SteadyTicks", '--load-ms=0')
foreach ($load in @(2, 4)) {
    Invoke-PhysicsValidation "phys_recovery_load$load" 'phys_recovery_runner.gd' @("--ticks=$LoadTicks", "--load-ms=$load")
}
Invoke-PhysicsValidation 'phys_recovery_hitch' 'phys_recovery_runner.gd' @('--ticks=1200', '--load-ms=0', '--hitch-ms=250')
if ($IncludeDirectOracle) { Invoke-PhysicsValidation 'phys3_direct_oracle' 'phys3_coastal_probe_runner.gd' }
Write-Host "Validation completed. Results: $outputRoot"
