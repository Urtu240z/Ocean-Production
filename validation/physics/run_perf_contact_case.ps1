param(
    [ValidateSet('A','B')][string]$Variant = 'A',
    [string]$Label = 'A1',
    [switch]$Diagnostic,
    [switch]$Replay
)
$ErrorActionPreference = 'Stop'
$contactRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$contactOutput = Join-Path $contactRoot 'temp/async_fft/perf_contact_1'
New-Item -ItemType Directory -Path $contactOutput -Force | Out-Null
$contactScript = if ($Replay) { 'res://validation/physics/perf_contact_deterministic_scene.gd' } else { 'res://validation/physics/perf_contact_real_scene_profile.gd' }
if ($Diagnostic) { $contactScript = 'res://validation/physics/perf_contact_diagnostic_scene_profile.gd' }
$contactArguments = @('--path',('"'+$contactRoot+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script',$contactScript,'--','--workers=1','--boats=6',('--label='+$Label),'--warmup=8','--seconds=2','--settle=0.5','--travel-x-seconds=4','--travel-z-seconds=14','--capture-folder=perf_contact_1','--layout=two_state_test',('--contact-variant='+$Variant),('--contact-diagnostic='+$Diagnostic.IsPresent.ToString().ToLower()),'--ticks=720')
$contactStarted = [DateTime]::UtcNow
$contactProcess = Start-Process -FilePath 'C:/Users/ehort/Documents/Godot 4.7/Godot_v4.7.1-stable_win64.exe' -ArgumentList $contactArguments -WorkingDirectory $contactRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $contactOutput ($Label+'.log')) -RedirectStandardError (Join-Path $contactOutput ($Label+'.stderr.log'))
$contactProcess.WaitForExit()
$contactRecord = [ordered]@{label=$Label;variant=$Variant;diagnostic=$Diagnostic.IsPresent;replay=$Replay.IsPresent;start_utc=$contactStarted.ToString('o');end_utc=[DateTime]::UtcNow.ToString('o');exit_code=$contactProcess.ExitCode}
$contactRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $contactOutput ($Label+'.run.json')) -Encoding utf8
Write-Output ('FINISHED '+$Label+' exit='+$contactProcess.ExitCode)
if ($contactProcess.ExitCode -ne 0) { throw ('Inspect '+$Label+'.stderr.log') }
