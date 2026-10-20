param([int]$Boats=6,[string]$Label='arcade_cost6',[ValidateSet('trace','cost','benchmark','replay')][string]$Kind='cost',[switch]$ArcadeDisabled,[switch]$FreeMotion,[string]$Select='all',[double]$Seconds=2)
$ErrorActionPreference='Stop'
$cp3Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$cp3Output=Join-Path $cp3Root 'temp/contact_pipeline_3'
New-Item -ItemType Directory -Path $cp3Output -Force | Out-Null
$cp3Script=if($Kind -eq 'replay'){'res://validation/physics/contact_pipeline_3_replay.gd'}else{'res://validation/physics/contact_pipeline_3_scene.gd'}
$cp3Arguments=@('--path',('"'+$cp3Root+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script',$cp3Script,'--','--workers=1',('--boats='+$Boats),('--label='+$Label),'--warmup=8',('--seconds='+$Seconds),('--select='+$Select),'--settle=0.5','--travel-x-seconds=4','--travel-z-seconds=14','--capture-folder=../contact_pipeline_3','--layout=two_state_test','--contact-variant=B','--source-variant=B','--ticks=720',('--cp3-free-motion='+$FreeMotion.IsPresent.ToString().ToLower()),('--cp3-kind='+$Kind),('--cp3-arcade='+$(if($ArcadeDisabled){'false'}else{'saved'})))
$cp3Start=[DateTime]::UtcNow
function Get-CP3Fingerprint {
    $cp3Hashes=[ordered]@{}
    foreach($cp3Relative in @('project.godot','validation/hull_wave_physics_playground.tscn','.godot/extension_list.cfg','addons/ocean/ocean.gd','addons/ocean/fft/open_ocean_fft.gd','addons/ocean/areas/ocean_local_sea_state.gd','addons/ocean/core/ocean_wave_band_profile.gd','addons/ocean/physics/water/cpu_fft_water_provider.gd','addons/jet_ski/common/core/jet_ski_controller.gd','addons/jet_ski/common/handling/jet_ski_arcade_handling.gd','addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd','addons/jet_ski/common/systems/jet_ski_water_physics_system.gd','addons/ocean/areas/ocean_wave_area_runtime.gd','addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll')){
        $cp3Hashes[$cp3Relative]=(Get-FileHash -LiteralPath (Join-Path $cp3Root $cp3Relative) -Algorithm SHA256).Hash.ToLower()
    }
    return $cp3Hashes
}
$cp3FingerprintBefore=Get-CP3Fingerprint
$cp3Hook=Select-String -LiteralPath (Join-Path $cp3Root 'addons/jet_ski/common/handling/jet_ski_arcade_handling.gd') -SimpleMatch '_cp3_classic_callback' -Quiet
if($Kind -in @('trace','cost') -and -not $cp3Hook){throw 'Apply validation/fixtures/contact_pipeline_3_arcade_diagnostic.patch for diagnostic runs only'}
if($Kind -in @('benchmark','replay') -and $cp3Hook){throw 'Remove Arcade diagnostic hook before parity or performance runs'}
$cp3Process=Start-Process -FilePath 'C:/Users/ehort/Documents/Godot 4.7/Godot_v4.7.1-stable_win64.exe' -ArgumentList $cp3Arguments -WorkingDirectory $cp3Root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $cp3Output ($Label+'.log')) -RedirectStandardError (Join-Path $cp3Output ($Label+'.stderr.log'))
$cp3Process.WaitForExit()
$cp3FingerprintAfter=Get-CP3Fingerprint
[ordered]@{label=$Label;boats=$Boats;kind=$Kind;arcade_disabled=$ArcadeDisabled.IsPresent;select=$Select;seconds=$Seconds;start_utc=$cp3Start.ToString('o');end_utc=[DateTime]::UtcNow.ToString('o');exit_code=$cp3Process.ExitCode;fingerprint_before=$cp3FingerprintBefore;fingerprint_after=$cp3FingerprintAfter}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $cp3Output ($Label+'.run.json')) -Encoding utf8
Write-Output ('FINISHED '+$Label+' exit='+$cp3Process.ExitCode)
if($cp3Process.ExitCode -ne 0){throw ('Inspect '+$Label+'.stderr.log')}
if(($cp3FingerprintBefore|ConvertTo-Json -Compress) -ne ($cp3FingerprintAfter|ConvertTo-Json -Compress)){throw 'Environment changed during capture; do not accept this run'}
if(Select-String -LiteralPath (Join-Path $cp3Output ($Label+'.stderr.log')) -Pattern 'ERROR:|SCRIPT ERROR' -Quiet){throw 'Capture contains errors; inspect stderr before accepting it'}
