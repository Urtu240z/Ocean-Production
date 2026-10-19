param([int]$Ticks=720, [int[]]$Boats=@(1,4,6))
$ErrorActionPreference='Stop'
$replayRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$replayOutput=Join-Path $replayRoot 'temp\async_fft\deterministic'
New-Item -ItemType Directory -Path $replayOutput -Force | Out-Null
$replayGodot='C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe'
foreach($replayCount in $Boats) {
    foreach($replayMode in @(0,1,2)) {
        $replayLabel='b{0}_m{1}' -f $replayCount,$replayMode
        & $replayGodot --path $replayRoot --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/async_fft_deterministic_scene.gd -- "--boats=$replayCount" "--workers=$replayMode" "--label=$replayLabel" "--ticks=$Ticks" *> (Join-Path $replayOutput ($replayLabel+'.log'))
        if($LASTEXITCODE -ne 0) { throw "Deterministic scene failed: $replayLabel" }
        Write-Output "REPLAY_FINISHED $replayLabel"
    }
    $replayLabel='b{0}_m0_control' -f $replayCount
    & $replayGodot --path $replayRoot --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/async_fft_deterministic_scene.gd -- "--boats=$replayCount" '--workers=0' "--label=$replayLabel" "--ticks=$Ticks" *> (Join-Path $replayOutput ($replayLabel+'.log'))
    if($LASTEXITCODE -ne 0) { throw "Deterministic control failed: $replayLabel" }
    Write-Output "REPLAY_FINISHED $replayLabel"
}
