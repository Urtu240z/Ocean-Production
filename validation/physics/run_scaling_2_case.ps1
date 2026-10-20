param([int]$Boats=6,[string]$Label='diagnostic6',[switch]$Replay,[switch]$Benchmark,[ValidateSet('A','B')][string]$SourceVariant='B',[string]$Select='all',[double]$Seconds=2)
$ErrorActionPreference='Stop'
$scalingRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scalingOutput=Join-Path $scalingRoot 'temp/scaling_2'
New-Item -ItemType Directory -Path $scalingOutput -Force | Out-Null
$scalingScript=if($Replay){'res://validation/physics/hull_native_deterministic_scene.gd'}elseif($Benchmark){'res://validation/physics/hull_native_real_scene_profile.gd'}else{'res://validation/physics/scaling_2_diagnostic_scene.gd'}
$scalingArguments=@('--path',('"'+$scalingRoot+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script',$scalingScript,'--','--workers=1',('--boats='+$Boats),('--label='+$Label),'--warmup=8',('--seconds='+$Seconds),('--select='+$Select),'--settle=0.5','--travel-x-seconds=4','--travel-z-seconds=14','--capture-folder=../scaling_2','--layout=two_state_test','--contact-variant=B',('--contact-diagnostic='+(-not $Benchmark -and -not $Replay).ToString().ToLower()),('--source-variant='+$SourceVariant),'--ticks=720')
$scalingStart=[DateTime]::UtcNow
function Get-ScalingFingerprint {
    $scalingHashes=[ordered]@{}
    foreach($scalingRelative in @('project.godot','validation/hull_wave_physics_playground.tscn','.godot/extension_list.cfg','addons/ocean/ocean.gd','addons/ocean/fft/open_ocean_fft.gd','addons/ocean/physics/water/cpu_fft_water_provider.gd','addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll')){
        $scalingHashes[$scalingRelative]=(Get-FileHash -LiteralPath (Join-Path $scalingRoot $scalingRelative) -Algorithm SHA256).Hash.ToLower()
    }
    return $scalingHashes
}
$scalingFingerprintBefore=Get-ScalingFingerprint
if(-not $Benchmark -and -not $Replay -and -not (Select-String -LiteralPath (Join-Path $scalingRoot 'addons/jet_ski/common/core/jet_ski_controller.gd') -SimpleMatch '_scaling_integrate_body' -Quiet)){
    throw 'Diagnostic clocks absent. Apply validation/fixtures/scaling_2_diagnostic.patch for diagnostic runs only, then reverse it before benchmarking.'
}
$scalingProcess=Start-Process -FilePath 'C:/Users/ehort/Documents/Godot 4.7/Godot_v4.7.1-stable_win64.exe' -ArgumentList $scalingArguments -WorkingDirectory $scalingRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $scalingOutput ($Label+'.log')) -RedirectStandardError (Join-Path $scalingOutput ($Label+'.stderr.log'))
$scalingProcess.WaitForExit()
$scalingFingerprintAfter=Get-ScalingFingerprint
[ordered]@{label=$Label;boats=$Boats;diagnostic=(-not $Benchmark -and -not $Replay);source_variant=$SourceVariant;select=$Select;seconds=$Seconds;start_utc=$scalingStart.ToString('o');end_utc=[DateTime]::UtcNow.ToString('o');exit_code=$scalingProcess.ExitCode;fingerprint_before=$scalingFingerprintBefore;fingerprint_after=$scalingFingerprintAfter}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $scalingOutput ($Label+'.run.json')) -Encoding utf8
Write-Output ('FINISHED '+$Label+' exit='+$scalingProcess.ExitCode)
if($scalingProcess.ExitCode -ne 0){throw ('Inspect '+$Label+'.stderr.log')}
if(($scalingFingerprintBefore|ConvertTo-Json -Compress) -ne ($scalingFingerprintAfter|ConvertTo-Json -Compress)){throw 'Environment changed during capture; do not accept this run'}
if(Select-String -LiteralPath (Join-Path $scalingOutput ($Label+'.stderr.log')) -Pattern 'ERROR:|SCRIPT ERROR' -Quiet){throw 'Capture contains errors; inspect stderr before accepting it'}
