param([int]$Rounds=2,[int]$Frames=720,[string]$Name='matrix',[string[]]$Modes=@('off','sides','tail3','tail4','all3','all4'),[int[]]$VehicleCounts=@(1,12),[int]$Warmup=180,[int]$FixedFps=60,[ValidateSet('on','stages','off')][string]$Diagnostics='on',[ValidateSet('on','off')][string]$RunningFoam='on',[ValidateSet('on','off')][string]$HullWaves='off',[double]$WaveRise=-1,[double]$WaveDuration=-1,[ValidateSet('current','before_live_front')][string]$WaveSource='current',[ValidateSet(20,30,60)][int]$FoamHz=30)
$ErrorActionPreference='Stop'
$projectRoot=(Get-Location).Path
$enginePath='C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe'
$matrixRoot=Join-Path $projectRoot "temp/hull_spray/$Name"
New-Item -ItemType Directory -Path $matrixRoot -Force | Out-Null
$allModes=@('off','sides','tail3','tail4','all3','all4')
for($round=0;$round -lt $Rounds;$round++) {
  $order=if(($round%2)-eq 1){@($allModes[($allModes.Count-1)..0])}else{$allModes}
  foreach($mode in @($order | Where-Object { $_ -in $Modes })) {
    $counts=if(($round%2)-eq 1){@($VehicleCounts[($VehicleCounts.Count-1)..0])}else{@($VehicleCounts)}
    foreach($count in $counts) {
      $runName="r${round}_${mode}_${count}"
      $outDir=Join-Path $matrixRoot $runName
      New-Item -ItemType Directory -Path $outDir -Force | Out-Null
      $clockArguments=if($FixedFps -gt 0){@('--fixed-fps',"$FixedFps")}else{@()}
      $arguments=@('--path',('"{0}"' -f $projectRoot))+$clockArguments+@('--disable-vsync','--script','res://validation/foam2d_probe.gd','--','--mode=combined',"--spray=$mode","--vehicles=$count","--frames=$Frames","--warmup=$Warmup",'--shots=no','--monitor=yes',"--diagnostics=$Diagnostics","--out=res://temp/hull_spray/$Name/$runName")
      $arguments+=@("--running-foam=$RunningFoam","--hull-waves=$HullWaves")
      $arguments+=@("--foam-hz=$FoamHz")
      $arguments+=@("--wave-source=$WaveSource")
      if($WaveRise -ge 0){$arguments+=@('--wave-rise='+$WaveRise.ToString([System.Globalization.CultureInfo]::InvariantCulture))}
      if($WaveDuration -ge 0){$arguments+=@('--wave-duration='+$WaveDuration.ToString([System.Globalization.CultureInfo]::InvariantCulture))}
      $process=Start-Process -FilePath $enginePath -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $outDir 'stdout.log') -RedirectStandardError (Join-Path $outDir 'stderr.log')
      $started=$false
      $clock=[System.Diagnostics.Stopwatch]::StartNew()
      $samples=[System.Collections.Generic.List[object]]::new()
      $cpuStart=0.0
      $startSeconds=0.0
      $measured=$null
      while(-not $process.HasExited) {
        $process.Refresh()
        if(Test-Path -LiteralPath (Join-Path $outDir 'measure_started.json')) {
          if(-not $started) {
            $started=$true
            # The console executable is only a launcher. Measure the PID
            # written by OS.get_process_id() inside the actual game.
            $marker=Get-Content -LiteralPath (Join-Path $outDir 'measure_started.json') -Raw | ConvertFrom-Json
            $measured=Get-Process -Id $marker.pid
            $cpuStart=$measured.TotalProcessorTime.TotalMilliseconds
            $startSeconds=$clock.Elapsed.TotalSeconds
          }
          $measured.Refresh()
          $samples.Add([pscustomobject]@{seconds=$clock.Elapsed.TotalSeconds-$startSeconds;cpu_ms=$measured.TotalProcessorTime.TotalMilliseconds-$cpuStart;private_bytes=$measured.PrivateMemorySize64;working_set_bytes=$measured.WorkingSet64})
          if(Test-Path -LiteralPath (Join-Path $outDir 'measure_ended.json')) {
            $cpuEnd=$measured.TotalProcessorTime.TotalMilliseconds
            $final=$samples[$samples.Count-1]
            $result=[pscustomobject]@{mode=$mode;vehicles=$count;round=$round;measured_frames=$Frames-$Warmup;cpu_total_ms=$cpuEnd-$cpuStart;cpu_ms_per_frame=($cpuEnd-$cpuStart)/($Frames-$Warmup);wall_seconds=$clock.Elapsed.TotalSeconds-$startSeconds;first_private_bytes=$samples[0].private_bytes;last_private_bytes=$final.private_bytes;first_working_set_bytes=$samples[0].working_set_bytes;last_working_set_bytes=$final.working_set_bytes;samples=$samples.ToArray();scope='OS process CPU across all threads; marker endpoints sampled at 20ms';diagnostics=$Diagnostics;fixed_fps=$FixedFps}
            $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outDir 'process_metrics.json') -Encoding utf8
            New-Item -ItemType File -Path (Join-Path $outDir 'cpu_collected.marker') -Force | Out-Null
            break
          }
        }
        Start-Sleep -Milliseconds 20
      }
      $process.WaitForExit()
      if($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $outDir 'report.json'))) { throw "Failed run: $runName, exit=$($process.ExitCode)" }
      Write-Output "HULL_SPRAY_RUN $runName exit=$($process.ExitCode)"
    }
  }
}
