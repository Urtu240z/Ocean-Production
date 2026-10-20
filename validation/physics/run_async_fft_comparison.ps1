param(
    [int[]]$Boats = @(1,4,6),
    [int]$Passes = 3,
    [double]$Seconds = 2,
    [double]$Warmup = 8,
    [double]$Settle = 0.5,
    [double]$TravelXSeconds = 4,
    [double]$TravelZSeconds = 14,
    [string]$OutputName = 'real_profiler',
    [string]$Select = 'all',
    [string]$Layout = 'two_state_test',
    [string]$GodotExe = 'C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64.exe'
)
$ErrorActionPreference = 'Stop'
# The Windows console binary is a tiny launcher, not the engine process.
# Sample the GUI sibling directly so CPU and memory belong to Godot itself.
if ($GodotExe.EndsWith('_console.exe')) {
    $asyncEngineExe = $GodotExe.Substring(0,$GodotExe.Length-'_console.exe'.Length)+'.exe'
    if (-not (Test-Path -LiteralPath $asyncEngineExe)) { throw "Engine sibling missing: $asyncEngineExe" }
    $GodotExe = $asyncEngineExe
}
$asyncRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$asyncOutput = Join-Path $asyncRepo ('temp\async_fft\'+$OutputName)
New-Item -ItemType Directory -Path $asyncOutput -Force | Out-Null
$asyncCpu = Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed
$asyncManifest = [ordered]@{started_utc=[DateTime]::UtcNow.ToString('o'); cpu=$asyncCpu; runs=@(); layout=$Layout; warmup=$Warmup; seconds=$Seconds; settle=$Settle; travel_x_seconds=$TravelXSeconds; travel_z_seconds=$TravelZSeconds; physics_hz=60; resolution='1920x1080'; affinity='unchanged'; stern_mist=$false}
$asyncManifestPath = Join-Path $asyncOutput 'manifest.json'
$asyncManifest['process_sampler'] = 'engine_direct_v2'
$asyncManifest['engine_executable'] = $GodotExe
$asyncGpuSampler = $null
$asyncNvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($asyncNvidia) {
    $asyncGpuArgs = @('--query-gpu=timestamp,temperature.gpu,clocks.current.graphics,clocks.current.memory,utilization.gpu,power.draw','--format=csv,nounits','--loop-ms=1000','-f',('"'+(Join-Path $asyncOutput 'gpu_telemetry.csv')+'"'))
    $asyncGpuSampler = Start-Process -FilePath $asyncNvidia.Source -ArgumentList $asyncGpuArgs -WindowStyle Hidden -PassThru
}
try {
$asyncOrder = @(@(0,1,2),@(2,0,1),@(1,2,0))
foreach ($asyncBoatCount in $Boats) {
    for ($asyncPass=0; $asyncPass -lt $Passes; $asyncPass++) {
        foreach ($asyncMode in $asyncOrder[$asyncPass % 3]) {
            $asyncLabel = 'b{0}_p{1}_m{2}' -f $asyncBoatCount,$asyncPass,$asyncMode
            $asyncStdout = Join-Path $asyncOutput ($asyncLabel+'.log')
            $asyncStderr = Join-Path $asyncOutput ($asyncLabel+'.stderr.log')
            $asyncArgs = @('--path',('"'+$asyncRepo+'"'),'--debug','--skip-breakpoints','--ignore-error-breaks','--rendering-method','forward_plus','--rendering-driver','d3d12','--script','res://validation/physics/async_fft_real_scene_profile.gd','--',('--workers='+$asyncMode),('--boats='+$asyncBoatCount),('--label='+$asyncLabel),('--warmup='+$Warmup),('--seconds='+$Seconds),('--settle='+$Settle),('--travel-x-seconds='+$TravelXSeconds),('--travel-z-seconds='+$TravelZSeconds),('--capture-folder='+$OutputName),('--select='+$Select),('--layout='+$Layout))
            $asyncStarted = [DateTime]::UtcNow
            $asyncProcess = Start-Process -FilePath $GodotExe -ArgumentList $asyncArgs -WorkingDirectory $asyncRepo -WindowStyle Hidden -PassThru -RedirectStandardOutput $asyncStdout -RedirectStandardError $asyncStderr
            $asyncSamples = @()
            $asyncPreviousCpu = 0.0
            $asyncPreviousTime = [DateTime]::UtcNow
            while (-not $asyncProcess.HasExited) {
                Start-Sleep -Milliseconds 1000
                $asyncProcess.Refresh()
                if ($asyncProcess.HasExited) { break }
                $asyncNow = [DateTime]::UtcNow
                $asyncCpuSeconds = $asyncProcess.TotalProcessorTime.TotalSeconds
                $asyncElapsed = ($asyncNow-$asyncPreviousTime).TotalSeconds
                $asyncSamples += [ordered]@{utc=$asyncNow.ToString('o'); cpu_percent_machine=100*($asyncCpuSeconds-$asyncPreviousCpu)/[Math]::Max(0.01,$asyncElapsed)/[Environment]::ProcessorCount; working_set_bytes=$asyncProcess.WorkingSet64; private_bytes=$asyncProcess.PrivateMemorySize64}
                $asyncPreviousCpu = $asyncCpuSeconds; $asyncPreviousTime = $asyncNow
            }
            $asyncProcess.WaitForExit()
            $asyncResult = Join-Path $asyncOutput ($asyncLabel+'.json')
            $asyncRun = [ordered]@{label=$asyncLabel; boats=$asyncBoatCount; pass=$asyncPass; mode=$asyncMode; start_utc=$asyncStarted.ToString('o'); end_utc=[DateTime]::UtcNow.ToString('o'); exit_code=$asyncProcess.ExitCode; result_present=(Test-Path -LiteralPath $asyncResult); process_samples=$asyncSamples}
            $asyncManifest.runs += $asyncRun
            $asyncManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $asyncManifestPath -Encoding utf8
            Write-Output ('FINISHED '+$asyncLabel+' exit='+$asyncProcess.ExitCode+' data='+$asyncRun.result_present)
            if ($asyncProcess.ExitCode -ne 0 -or -not $asyncRun.result_present) { throw "Benchmark failed: $asyncLabel. Inspect $asyncStdout and $asyncStderr" }
        }
    }
}
$asyncManifest['finished_utc'] = [DateTime]::UtcNow.ToString('o')
$asyncManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $asyncManifestPath -Encoding utf8
} finally {
    if ($asyncGpuSampler -and -not $asyncGpuSampler.HasExited) { Stop-Process -Id $asyncGpuSampler.Id }
}
