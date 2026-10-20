param([int]$Boats=6,[string]$Label='diagnostic6',[switch]$Replay,[switch]$Benchmark,[ValidateSet('A','B')][string]$SourceVariant='B',[string]$Select='all',[double]$Seconds=2)
$ErrorActionPreference='Stop'
$np2Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$np2Output=Join-Path $np2Root 'temp/native_performance_2'
New-Item -ItemType Directory -Path $np2Output -Force | Out-Null
$np2Script=if($Replay){'res://validation/physics/native_performance_2_replay.gd'}elseif($Benchmark){'res://validation/physics/hull_native_real_scene_profile.gd'}else{'res://validation/physics/scaling_2_diagnostic_scene.gd'}
$np2Arguments=@('--path',('"'+$np2Root+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script',$np2Script,'--','--workers=1',('--boats='+$Boats),('--label='+$Label),'--warmup=8',('--seconds='+$Seconds),('--select='+$Select),'--settle=0.5','--travel-x-seconds=4','--travel-z-seconds=14','--capture-folder=../native_performance_2','--layout=two_state_test','--contact-variant=B',('--contact-diagnostic='+(-not $Benchmark -and -not $Replay).ToString().ToLower()),('--source-variant='+$SourceVariant),'--ticks=720','--pipeline-diagnostic=true')
$np2Start=[DateTime]::UtcNow
function Get-NP2Fingerprint {
    $np2Hashes=[ordered]@{}
    foreach($np2Relative in @('project.godot','validation/hull_wave_physics_playground.tscn','.godot/extension_list.cfg','addons/ocean/ocean.gd','addons/ocean/fft/open_ocean_fft.gd','addons/ocean/areas/ocean_local_sea_state.gd','addons/ocean/core/ocean_wave_band_profile.gd','addons/ocean/physics/water/cpu_fft_water_provider.gd','addons/jet_ski/common/core/jet_ski_controller.gd','addons/jet_ski/common/systems/jet_ski_water_physics_system.gd','addons/ocean/areas/ocean_wave_area_runtime.gd','addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll')){
        $np2Hashes[$np2Relative]=(Get-FileHash -LiteralPath (Join-Path $np2Root $np2Relative) -Algorithm SHA256).Hash.ToLower()
    }
    return $np2Hashes
}
$np2FingerprintBefore=Get-NP2Fingerprint
if(-not $Benchmark -and -not $Replay -and -not (Select-String -LiteralPath (Join-Path $np2Root 'addons/jet_ski/common/core/jet_ski_controller.gd') -SimpleMatch '_scaling_integrate_body' -Quiet)){
    throw 'Diagnostic clocks absent. Apply validation/fixtures/native_performance_2_diagnostic.patch for diagnostic runs only, then reverse it before benchmarking.'
}
$np2Process=Start-Process -FilePath 'C:/Users/ehort/Documents/Godot 4.7/Godot_v4.7.1-stable_win64.exe' -ArgumentList $np2Arguments -WorkingDirectory $np2Root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $np2Output ($Label+'.log')) -RedirectStandardError (Join-Path $np2Output ($Label+'.stderr.log'))
$np2Process.WaitForExit()
$np2FingerprintAfter=Get-NP2Fingerprint
[ordered]@{label=$Label;boats=$Boats;diagnostic=(-not $Benchmark -and -not $Replay);source_variant=$SourceVariant;select=$Select;seconds=$Seconds;start_utc=$np2Start.ToString('o');end_utc=[DateTime]::UtcNow.ToString('o');exit_code=$np2Process.ExitCode;fingerprint_before=$np2FingerprintBefore;fingerprint_after=$np2FingerprintAfter}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $np2Output ($Label+'.run.json')) -Encoding utf8
Write-Output ('FINISHED '+$Label+' exit='+$np2Process.ExitCode)
if($np2Process.ExitCode -ne 0){throw ('Inspect '+$Label+'.stderr.log')}
if(($np2FingerprintBefore|ConvertTo-Json -Compress) -ne ($np2FingerprintAfter|ConvertTo-Json -Compress)){throw 'Environment changed during capture; do not accept this run'}
if(Select-String -LiteralPath (Join-Path $np2Output ($Label+'.stderr.log')) -Pattern 'ERROR:|SCRIPT ERROR' -Quiet){throw 'Capture contains errors; inspect stderr before accepting it'}
