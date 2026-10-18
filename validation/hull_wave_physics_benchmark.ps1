param(
    [string]$Godot = 'C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe',
    [ValidateSet('Benchmark','Response')][string]$Mode = 'Benchmark',
    [int]$Seconds = 12,
    [int]$Warmup = 8,
    [string]$Batch = 'matrix'
)
$ErrorActionPreference = 'Stop'
$hullProject = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hullOutput = Join-Path $hullProject ('temp/hull_wave_physics/'+$Batch)
$hullCases = if ($Mode -eq 'Response') {
    @(@{name='response_zero';boats=2;physical='on';mode='response';response='zero'},
      @{name='response_wave';boats=2;physical='on';mode='response';response='wave'})
} else {
    # Alternate ordering, including reversed pairs to reduce warm/cache bias.
    @(@{name='b1_off';boats=1;physical='off'},@{name='b1_on';boats=1;physical='on'},
      @{name='b4_on';boats=4;physical='on'},@{name='b4_off';boats=4;physical='off'},
      @{name='b6_off';boats=6;physical='off'},@{name='b6_on';boats=6;physical='on'},
      @{name='b12_on';boats=12;physical='on'},@{name='b12_off';boats=12;physical='off'})
}
foreach ($hullCase in $hullCases) {
    $hullCaseDir = Join-Path $hullOutput $hullCase.name
    New-Item -ItemType Directory -Path $hullCaseDir -Force | Out-Null
    foreach ($hullGenerated in @('measure_started.json','measure_ended.json','result.json','frames.json','process.json')) {
        $hullGeneratedPath = Join-Path $hullCaseDir $hullGenerated
        if (Test-Path -LiteralPath $hullGeneratedPath) { Remove-Item -LiteralPath $hullGeneratedPath }
    }
    $hullRunArgs = @('--path',('"'+$hullProject+'"'),'--script','res://validation/hull_wave_physics_runtime.gd',
        '--resolution','1280x720','--disable-vsync','--',('--boats='+$hullCase.boats),('--physical='+$hullCase.physical),
        ('--mode='+$(if ($Mode -eq 'Response') {'response'} else {'bench'})),
        ('--seconds='+$Seconds),('--warmup='+$Warmup),('--out=res://temp/hull_wave_physics/'+$Batch+'/'+$hullCase.name))
    if ($Mode -eq 'Response') { $hullRunArgs += '--response='+$hullCase.response }
    $hullChild = Start-Process -FilePath $Godot -ArgumentList $hullRunArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $hullCaseDir 'run.out') -RedirectStandardError (Join-Path $hullCaseDir 'run.err')
    $hullWall = [Diagnostics.Stopwatch]::StartNew()
    $hullSamples = [Collections.Generic.List[object]]::new()
    while (-not $hullChild.HasExited) {
        if ($hullWall.Elapsed.TotalSeconds -gt 150) {
            Stop-Process -Id $hullChild.Id
            throw "Isolated test timed out: $($hullCase.name)"
        }
        $hullChild.Refresh()
        if ((Test-Path (Join-Path $hullCaseDir 'measure_started.json')) -and -not (Test-Path (Join-Path $hullCaseDir 'measure_ended.json'))) {
            $hullMarker = Get-Content -LiteralPath (Join-Path $hullCaseDir 'measure_started.json') -Raw | ConvertFrom-Json
            $hullEngine = [Diagnostics.Process]::GetProcessById([int]$hullMarker.pid)
            $hullEngine.Refresh()
            $hullSamples.Add([pscustomobject]@{pid=$hullEngine.Id;seconds=$hullWall.Elapsed.TotalSeconds;cpu_s=$hullEngine.TotalProcessorTime.TotalSeconds;
                private_bytes=$hullEngine.PrivateMemorySize64;working_bytes=$hullEngine.WorkingSet64})
        }
        Start-Sleep -Milliseconds 500
    }
    $hullSamples | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $hullCaseDir 'process.json') -Encoding UTF8
    $hullErrors = Get-Content -LiteralPath (Join-Path $hullCaseDir 'run.err') -Raw
    if ($hullErrors -or -not (Test-Path (Join-Path $hullCaseDir 'result.json'))) {
        throw "Isolated test failed: $($hullCase.name). See its run.err."
    }
    Write-Output ('PASS '+$hullCase.name)
}
