param([ValidateSet('A','B')][string]$Variant='A',[string]$Label='A1',[switch]$Replay)
$ErrorActionPreference='Stop'
$hullRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$hullOutput=Join-Path $hullRoot 'temp/hull_native_1/real'
New-Item -ItemType Directory -Path $hullOutput -Force | Out-Null
$hullScript=if ($Replay) {'res://validation/physics/hull_native_deterministic_scene.gd'} else {'res://validation/physics/hull_native_real_scene_profile.gd'}
$hullMode=if ($Variant -eq 'A') {0} else {1}
$hullArguments=@('--path',('"'+$hullRoot+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script',$hullScript,'--','--workers=1','--boats=6',('--label='+$Label),'--warmup=8','--seconds=2','--settle=0.5','--travel-x-seconds=4','--travel-z-seconds=14','--capture-folder=../hull_native_1/real','--layout=two_state_test','--contact-variant=B',('--hull-geometry='+$hullMode),'--ticks=720')
$hullStarted=[DateTime]::UtcNow
$hullProcess=Start-Process -FilePath 'C:/Users/ehort/Documents/Godot 4.7/Godot_v4.7.1-stable_win64.exe' -ArgumentList $hullArguments -WorkingDirectory $hullRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $hullOutput ($Label+'.log')) -RedirectStandardError (Join-Path $hullOutput ($Label+'.stderr.log'))
$hullProcess.WaitForExit()
[ordered]@{label=$Label;variant=$Variant;replay=$Replay.IsPresent;start_utc=$hullStarted.ToString('o');end_utc=[DateTime]::UtcNow.ToString('o');exit_code=$hullProcess.ExitCode} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $hullOutput ($Label+'.run.json')) -Encoding utf8
Write-Output ('FINISHED '+$Label+' exit='+$hullProcess.ExitCode)
if ($hullProcess.ExitCode -ne 0) {throw ('Inspect '+$Label+'.stderr.log')}
