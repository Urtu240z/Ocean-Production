[CmdletBinding()]
param(
    [string]$GodotExe, [string]$PythonExe,
    [ValidateSet('template_release')][string]$Configuration='template_release',
    [switch]$SkipBuild, [switch]$Quick, [switch]$Full, [switch]$WorkerSweep,
    [switch]$SmokeOnly, [switch]$PreflightOnly, [string]$OutputDirectory,
    [ValidateRange(-1,32)][int]$GpuIndex=-1
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this script with PowerShell 7 (pwsh).' }
if (@($Quick,$Full,$SmokeOnly,$PreflightOnly | Where-Object { $_ }).Count -gt 1) { throw 'Choose one of Quick, Full, SmokeOnly or PreflightOnly.' }
if (-not ($Quick -or $Full -or $SmokeOnly -or $PreflightOnly)) { $Quick=$true }
. (Join-Path $PSScriptRoot 'target_validation_common.ps1')
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $script:TargetRepo ('.godot/target_validation/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory=(Resolve-Path $OutputDirectory).Path
$relativeOutput=[IO.Path]::GetRelativePath($script:TargetRepo,$OutputDirectory)
if($relativeOutput -notmatch '^\.\.' -and -not [IO.Path]::IsPathRooted($relativeOutput)) {
    $ignoreProof=Invoke-TargetProcess 'git' @('check-ignore','--',([IO.Path]::Combine($relativeOutput,'summary.json')))
    if($ignoreProof.exit_code) { throw 'OutputDirectory inside the repository must be Git-ignored. Use .godot/target_validation or an external output directory.' }
}
$lockDirectory=Join-Path $script:TargetRepo '.godot/target_validation'
New-Item -ItemType Directory $lockDirectory -Force | Out-Null
try { $runnerLock=[IO.File]::Open((Join-Path $lockDirectory '.runner.lock'),'OpenOrCreate','ReadWrite','None') }
catch { throw 'Another target validation runner owns this checkout. Wait for it to finish; fixed legacy artifacts cannot be shared concurrently.' }
$logs=Join-Path $OutputDirectory 'logs'; New-Item -ItemType Directory $logs -Force | Out-Null
$results=[ordered]@{}
$summary=[ordered]@{ schema_version=1; preparation='RUNNING'; target_acceptance='NOT RUN'; mode=$(if($Full){'Full'}elseif($SmokeOnly){'SmokeOnly'}elseif($PreflightOnly){'PreflightOnly'}else{'Quick'});
    source_commit=''; results=$results; failure=$null; selected_workers=4; target_hardware_tested=$false }
$project=Join-Path $script:TargetRepo 'project.godot'; $projectHash=(Get-FileHash $project).Hash
$cleanImports=@()
function Invoke-TargetPhase([string]$Name,[string]$Runner,[string]$Artifact,[string[]]$UserArgs=@(),[switch]$Headless,[switch]$Separate,[scriptblock]$Check) {
    Write-Host "RUN $Name"
    $prefix=Join-Path $logs $Name
    $arguments=@('--path',$script:TargetRepo,'--log-file',"$prefix.godot.log",'--script',"res://validation/physics/$Runner")
    if ($Headless) { $arguments+='--headless' } else { $arguments+=@('--rendering-method','forward_plus','--rendering-driver','d3d12') }
    if(-not $Headless -and $GpuIndex -ge 0) { $arguments+=@('--gpu-index',[string]$GpuIndex) }
    if ($Separate) { $arguments+=@('--render-thread','separate') }
    if ($UserArgs -and $UserArgs.Count -gt 0) { $arguments+='--'; $arguments+=$UserArgs }
    $start=[DateTime]::UtcNow
    $run=Invoke-TargetProcess $environment.godot_executable $arguments $prefix
    if ($run.exit_code -ne 0) { throw "$Name failed (exit $($run.exit_code)); see $prefix.stderr.log" }
    if (($run.stdout+$run.stderr) -match '(?m)SCRIPT ERROR:|Parse Error:|PHYS_[A-Z_]*FAIL') { throw "$Name contains script/validation errors despite exit zero." }
    if (-not (Test-Path $Artifact) -or (Get-Item $Artifact).LastWriteTimeUtc -lt $start) { throw "$Name did not produce a fresh result. Stale files are never accepted." }
    $data=Get-Content -Raw $Artifact | ConvertFrom-Json -AsHashtable
    if ($Check -and -not (& $Check $data $run)) { throw "$Name failed its existing correctness gate." }
    $destination=Join-Path $OutputDirectory "$Name.json"
    if ([IO.Path]::GetFullPath($Artifact) -ne [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $Artifact -Destination $destination }
    $results[$Name]=@{ passed=$true; seconds=$run.seconds; artifact="$Name.json"; command=@($environment.godot_executable)+$arguments; data=$data }
    Save-TargetJson $summary (Join-Path $OutputDirectory 'summary.json')
    Write-Host "PASS $Name"
    return $data
}
function Invoke-Recovery([string]$Name,[int]$Ticks,[int]$Workers,[int]$Load=0) {
    $suffix=if($Workers -eq 5){''}else{"_w$Workers"}
    $artifact=Join-Path $script:TargetRepo ".godot/phys_recovery_${Ticks}_${Load}_0$suffix.json"
    return Invoke-TargetPhase $Name 'phys_recovery_runner.gd' $artifact @("--ticks=$Ticks","--workers=$Workers","--load-ms=$Load")
}
function Invoke-Performance([string]$Name,[int]$Ticks,[switch]$Integrated,[switch]$Weather,[switch]$Separate) {
    $artifact=Join-Path $OutputDirectory "$Name.json"
    $probeArgs=@("--ticks=$Ticks",'--warmup=180',"--workers=$($summary.selected_workers)","--output=$artifact")
    if($Integrated){$probeArgs+='--integrated'}; if($Weather){$probeArgs+='--weather'}
    return Invoke-TargetPhase $Name 'phys_target_performance_runner.gd' $artifact $probeArgs -Separate:$Separate -Check {param($d,$r) $d.passed -and $d.build_id -eq $environment.expected_native_build_id}
}
function Invoke-OptionalSeparate([string]$Name,[int]$Ticks) {
    try { return Invoke-Performance $Name $Ticks -Integrated -Weather -Separate }
    catch {
        # This engine mode is explicitly conditional on support/safety. Never
        # qualify timings from a process with script/native/teardown errors.
        $reason=$_.Exception.Message
        $artifact=Join-Path $OutputDirectory "$Name.json"
        if(Test-Path $artifact) { Copy-Item -LiteralPath $artifact -Destination (Join-Path $OutputDirectory "$Name.raw.unqualified.json") }
        $d=@{schema_version=1; supported_and_safe=$false; qualified=$false; status='UNSAFE OR UNSUPPORTED'; reason=$reason; logs="logs/$Name.*"; timings_excluded_from_acceptance=$true}
        $stderrPath=Join-Path $logs "$Name.stderr.log"
        if(Test-Path $stderrPath) {
            $stderr=Get-Content -Raw $stderrPath
            $d.error_lines=@($stderr -split '\r?\n' | Where-Object { $_ -match 'SCRIPT ERROR:|^ERROR:' })
            $d.engine_experimental_warning=($stderr -match 'separate rendering thread feature is experimental')
        }
        Save-TargetJson $d $artifact
        $results[$Name]=@{passed=$false; status='UNSAFE OR UNSUPPORTED'; seconds=$null; artifact="$Name.json"; data=$d}
        Write-Warning "$Name is not qualified; retained diagnostics. Default renderer remains the mandatory integrated test."
        return $d
    }
}
try {
    $environment=Get-TargetEnvironment $GodotExe $PythonExe $OutputDirectory
    Save-TargetJson $environment (Join-Path $OutputDirectory 'environment.json')
    $summary.source_commit=$environment.source_commit
    if ($environment.branch -ne 'wip/phys-opt-2') { throw 'Expected branch wip/phys-opt-2; runner never changes branches.' }
    $ancestor=Invoke-TargetProcess 'git' @('merge-base','--is-ancestor','d51ba47528ded38a4a77b8245b2ed74c96460202','HEAD')
    if ($ancestor.exit_code) { throw 'Source does not contain the validated d51ba47 checkpoint.' }
    if ($Full -and $environment.working_tree) { throw 'Full acceptance requires a clean working tree.' }
    if ($PreflightOnly) { $summary.preparation='PREFLIGHT PASS'; return }
    $build=Build-TargetNative $environment $OutputDirectory -SkipBuild:$SkipBuild
    Save-TargetJson $build (Join-Path $OutputDirectory 'native_build.json')
    # Track importer sidecars that were clean before the owned editor import.
    # Restore only those files, preserving any pre-existing user edits.
    $tracked=Invoke-TargetProcess 'git' @('ls-files','*.import')
    foreach ($file in ($tracked.stdout -split '\r?\n' | Where-Object { $_ })) {
        $dirty=Invoke-TargetProcess 'git' @('status','--porcelain','--',$file)
        if (-not $dirty.stdout.Trim()) { $cleanImports+=$file }
    }
    $import=Invoke-TargetProcess $environment.godot_executable @('--headless','--path',$script:TargetRepo,'--editor','--import','--quit') (Join-Path $logs 'import')
    if ($import.exit_code -or ($import.stdout+$import.stderr) -match 'SCRIPT ERROR:|Parse Error:|Error loading extension') { throw 'Clean import failed; inspect import logs. Close another editor if its reload-copy DLL is locked.' }
    $load=Invoke-TargetPhase 'native_load' 'phys_target_package_smoke.gd' (Join-Path $script:TargetRepo '.godot/phys_target_package_smoke.json') -Check {param($d,$r) $d.passed -and $d.build_id -eq $environment.expected_native_build_id -and $d.renderer -eq 'forward_plus' -and $d.driver -eq 'd3d12'}
    $environment.runtime_renderer=$load
    Save-TargetJson $environment (Join-Path $OutputDirectory 'environment.json')
    if($Full -and $environment.is_exact_target -and $load.gpu -notmatch 'RTX\s*4070.*Laptop') { throw 'Target dGPU is installed but Godot is rendering on another adapter. Choose the intended adapter with -GpuIndex and rerun; no target acceptance.' }
    $summary.target_hardware_tested=[bool]($Full -and $environment.is_exact_target)
    if ($SmokeOnly) {
        $null=Invoke-TargetPhase 'spectrum_identity_smoke' 'phys_spectrum_port_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_spectrum_port.json') -Headless
        $null=Invoke-TargetPhase 'world_exact_smoke' 'phys_world_parity_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_world_parity.json') -Check {param($d,$r) $d.passed}
        $null=Invoke-Recovery 'recovery_smoke' 120 4
        $null=Invoke-Performance 'package_smoke' 120
        $null=Invoke-Performance 'integrated_smoke' 120 -Integrated -Weather
        $null=Invoke-OptionalSeparate 'integrated_separate_smoke' 120
        $null=Invoke-TargetPhase 'contact_cost_smoke' 'phys_target_contact_cost_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_branch_continuity.json') @('--smoke') -Check {param($d,$r) $d.passed -and $d.local_probe.local_reacquisition_ms.count -gt 0}
        $summary.preparation='LOCAL PACKAGE SMOKE PASS'
        $summary.target_acceptance='NOT RUN: SmokeOnly cannot qualify target acceptance'
        return
    }
    # Existing authoritative tests are unchanged; their own tolerances decide pass.
    $null=Invoke-TargetPhase 'spectrum_identity' 'phys_spectrum_port_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_spectrum_port.json') -Headless
    $null=Invoke-TargetPhase 'PHYS3' 'phys3_coastal_probe_runner.gd' (Join-Path $env:TEMP 'PHYS-3.2-REPORT.json') -Check {param($d,$r) [string]$d.result -like 'PHYS-3-A*'}
    $velocityArgs=if($Full){@()}else{@('--smoke')}
    $null=Invoke-TargetPhase 'velocity_2G' 'phys_weather_velocity_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_weather_velocity.json') $velocityArgs -Check {param($d,$r) $r.stdout -match 'PHYS_OPT_2G_VELOCITY=PASS'}
    $null=Invoke-TargetPhase 'coverage_2I' 'phys_coastal_coverage_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_coastal_coverage.json') -Check {param($d,$r) $d.geometry_checks_passed}
    $null=Invoke-TargetPhase 'internal_masks_2I' 'phys_coastal_coverage_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_coastal_coverage_internal.json') @('--internal-only') -Check {param($d,$r) $d.geometry_checks_passed}
    $null=Invoke-TargetPhase 'world_exact_2J' 'phys_world_parity_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_world_parity.json') -Check {param($d,$r) $d.passed}
    if($Full) { $null=Invoke-TargetPhase 'world_sweep_2J' 'phys_world_parity_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_world_parity_sweep.json') @('--sweep') -Check {param($d,$r) $d.passed} }
    $null=Invoke-TargetPhase 'branch_controlled' 'phys_branch_continuity_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_branch_continuity.json') -Check {param($d,$r) $d.passed}
    $null=Invoke-TargetPhase 'branch_live' 'phys_branch_live_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_branch_live.json') -Check {param($d,$r) $d.passed}
    $null=Invoke-TargetPhase 'runtime_weather' 'phys_weather_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_weather.json') -Check {param($d,$r) $r.stdout -match 'PHYS_WEATHER_COMPLETE'}
    Save-TargetJson @{schema_version=1; passed=$true; suites=@($results.Keys); full=[bool]$Full} (Join-Path $OutputDirectory 'correctness.json')
    $null=Invoke-TargetPhase 'branch_contacts' 'phys_target_contact_cost_runner.gd' (Join-Path $script:TargetRepo '.godot/phys_branch_continuity.json') @('--smoke') -Check {param($d,$r) $d.passed -and $d.local_probe.local_reacquisition_ms.count -gt 0}
    if ($Full -or $WorkerSweep) {
        $sweep=@(); $sweepTicks=if($Full){3600}else{600}
        foreach ($workerCount in @(3,4,5,6,8)) {
            $actual=[int]$load.worker_probe[[string]$workerCount]
            if($actual -ne $workerCount) {
                $sweep+=@{workers=$workerCount; actual=$actual; status='UNSUPPORTED: native worker clamp'; measured=$false}
                continue
            }
            $d=Invoke-Recovery "worker_$workerCount" $sweepTicks $workerCount
            if($d.workers -ne $workerCount) { throw 'Worker sweep report did not use the requested worker count.' }
            $sweep+=@{workers=$workerCount; actual=$d.workers; measured=$true; build_ms=$d.build_ms; age_ticks=$d.age_ticks; main_wait_ms=$d.wait_ms; report="worker_$workerCount.json"}
        }
        # Freshness first, then producer tail; never select solely by average.
        $chosen=$sweep | Where-Object measured | Sort-Object @{Expression={$_.age_ticks.p99}},@{Expression={$_.build_ms.p99}} | Select-Object -First 1
        $summary.selected_workers=$chosen.workers
        Save-TargetJson @{schema_version=1; candidates=$sweep; selected=$chosen.workers; policy='age p99 then producer p99; validation-only runtime count'} (Join-Path $OutputDirectory 'worker_sweep.json')
    }
    $steadyTicks=if($Full){10000}else{600}; $loadTicks=if($Full){3600}else{600}
    $steady=Invoke-Recovery 'steady_10000' $steadyTicks $summary.selected_workers
    $load2=Invoke-Recovery 'load_2ms' $loadTicks $summary.selected_workers 2
    $load4=Invoke-Recovery 'load_4ms' $loadTicks $summary.selected_workers 4
    $weather=Invoke-Performance 'weather' $(if($Full){2400}else{600}) -Weather
    $integrated=Invoke-Performance 'integrated_renderer' $(if($Full){3600}else{600}) -Integrated -Weather
    $separate=Invoke-OptionalSeparate 'integrated_renderer_separate' $(if($Full){3600}else{600})
    if($Full) { $sustained=Invoke-Performance 'sustained_30000' 30000 -Integrated -Weather }
    $summary.preparation='PACKAGE EXECUTION PASS'
    $summary.old_pc_reference=@{ steady_mean_ms=@(9.0,10.16); steady_p99_ms=@(11.5,13.6); weather_mean_ms=@(11.5,12.2); query_mean_ms=@(0.01,0.03); context='Final old-PC ranges; integrated comparisons require identical render load.' }
    $summary.old_pc_ratios=@{ steady_mean=@($steady.build_ms.mean/10.16,$steady.build_ms.mean/9.0); steady_p99=@($steady.build_ms.p99/13.6,$steady.build_ms.p99/11.5); weather_mean=@($weather.build_ms.mean/12.2,$weather.build_ms.mean/11.5) }
    $summary.strong_indicators=@{ steady_mean_le_8=($steady.build_ms.mean -le 8.0); steady_p99_le_12=($steady.build_ms.p99 -le 12.0);
        integrated_weather_p99_under_tick=($integrated.build_ms.p99 -lt (1000.0/60.0)); age_p99_le_1=($integrated.field_age_ticks.p99 -le 1.0); age_max_lt_2=($integrated.field_age_ticks.max -lt 2.0) }
    $summary.target_hardware_tested=[bool]($Full -and $environment.is_exact_target)
    $summary.target_acceptance=if(-not $environment.is_exact_target){'TARGET HARDWARE NOT TESTED'}elseif(-not $Full){'PENDING: Quick is not acceptance'}else{'REVIEW REQUIRED'}
    if($Full -and $environment.is_exact_target) {
        $healthy=$steady.build_ms.p99 -lt (1000.0/60.0) -and $integrated.build_ms.p99 -lt (1000.0/60.0) -and $sustained.build_ms.p99 -lt (1000.0/60.0)
        $summary.acceptance_gates=@{correctness=$true; clean_build=$build.clean_rebuilt; integrated_producer_p99=$healthy;
            no_systematic_age_ge_2=($sustained.field_age_ticks.p95 -lt 2.0); query_N4_below_0_2_ms=($sustained.query_benchmark.material_N4_ms.p99 -lt 0.2);
            sustained_ticks=($sustained.ticks -ge 30000); frame_gpu_measured=$sustained.renderer.gpu_timer_available;
            memory_growth='REVIEW: compare process private-byte trace and capture growth'; thermal_collapse='REVIEW: first/final thirds and available power/temperature evidence'}
        if(-not $healthy -or $sustained.field_age_ticks.p95 -ge 2.0) { $summary.target_acceptance='FAIL: producer/freshness target gate' }
        # No automatic PASS while memory/thermal evidence still needs review.
    }
} catch {
    $summary.preparation='FAIL'; $summary.failure=$_.Exception.Message
    if($summary.target_hardware_tested) { $summary.target_acceptance='FAIL: correctness/build/harness; acceptance halted' }
    throw
} finally {
    if((Get-FileHash $project).Hash -ne $projectHash) { $summary.preparation='FAIL'; $summary.failure='project.godot changed unexpectedly; preserved for inspection.' }
    foreach ($file in $cleanImports) {
        $dirty=Invoke-TargetProcess 'git' @('status','--porcelain','--',$file)
        if($dirty.stdout.Trim()) { $null=Invoke-TargetProcess 'git' @('restore','--worktree','--',$file) }
    }
    if(-not $summary.target_hardware_tested) { $summary.target_acceptance='TARGET HARDWARE NOT TESTED' }
    Save-TargetJson $summary (Join-Path $OutputDirectory 'summary.json')
    $lines=@('# Target physics validation result','',"Preparation: **$($summary.preparation)**",'',"Target acceptance: **$($summary.target_acceptance)**",'',"Source: $($summary.source_commit)","Mode: $($summary.mode)","Workers: $($summary.selected_workers)",'',
        'See summary.json for commands, original gates and all results. Logs and process-memory captures are retained beside it. No PHYS-4 integration or master merge is performed.')
    if($summary.failure) { $lines+=@('',"Failure: $($summary.failure)") }
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'REPORT.md'),$lines,[Text.UTF8Encoding]::new($false))
    $reportPath=Join-Path $PSScriptRoot 'TARGET-PHYSICS-VALIDATION-REPORT.md'
    if(Test-Path $reportPath) {
        $generated=@('<!-- target-run:start -->',"Preparation execution: **$($summary.preparation)**",'',"Target validation: **$($summary.target_acceptance)**",'',"Mode: $($summary.mode); source: $($summary.source_commit); workers: $($summary.selected_workers).",'')
        if($results.Count) {
            $generated+=@('| Suite | Execution | Seconds |','|---|---|---:|')
            foreach($name in $results.Keys) {
                $status=if($results[$name].Contains('status')){$results[$name].status}else{'PASS'}
                $duration=if($null -eq $results[$name].seconds){'—'}else{[Math]::Round($results[$name].seconds,3)}
                $generated+="| $name | $status | $duration |"
            }
            $generated+=@('','| Producer run | Mean ms | p95 ms | p99 ms | Max ms | Age p99 ticks |','|---|---:|---:|---:|---:|---:|')
            foreach($name in $results.Keys) {
                $data=$results[$name].data
                if($data -isnot [Collections.IDictionary] -or -not $data.Contains('build_ms')) { continue }
                $age=if($data.Contains('field_age_ticks')){$data.field_age_ticks}elseif($data.Contains('age_ticks')){$data.age_ticks}else{$null}
                $b=$data.build_ms
                if($b.Contains('mean')) { $generated+="| $name | $($b.mean) | $($b.p95) | $($b.p99) | $($b.max) | $($age.p99) |" }
            }
            if($summary.Contains('old_pc_ratios')) { $generated+=@('',('Old-PC timing ratio intervals (target/current run divided by old-PC reference): `'+($summary.old_pc_ratios|ConvertTo-Json -Compress)+'`. Render load must match before interpreting these ratios.')) }
        }
        $generated+=@('','Detailed commands, distributions and machine-specific metadata: ignored run directory `summary.json`, `environment.json`, `REPORT.md` and logs.','<!-- target-run:end -->')
        $text=Get-Content -Raw $reportPath
        $replacement=$generated -join "`n"
        $text=[regex]::Replace($text,'(?s)<!-- target-run:start -->.*?<!-- target-run:end -->',[Text.RegularExpressions.MatchEvaluator]{param($m) $replacement})
        [IO.File]::WriteAllText($reportPath,$text,[Text.UTF8Encoding]::new($false))
    }
    Write-Host "RESULT $($summary.preparation) | $($summary.target_acceptance) | $OutputDirectory"
    $runnerLock.Dispose()
}
