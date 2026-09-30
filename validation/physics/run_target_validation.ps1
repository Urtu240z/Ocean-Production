[CmdletBinding()]
param(
	[string]$GodotExe,
	[string]$OutputDirectory = (Join-Path $env:TEMP ("phys-target-ready-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
	[switch]$SkipBuild,
	[switch]$SmokeOnly,
	[switch]$FocusedPhysCorrectnessOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$setupScript = Join-Path $PSScriptRoot 'setup_native_windows.ps1'
$projectFile = Join-Path $repoRoot 'project.godot'

if ([string]::IsNullOrWhiteSpace($GodotExe)) {
	$godotCommand = Get-Command 'Godot_v4.7.1-stable_win64_console.exe' -ErrorAction SilentlyContinue
	if ($null -eq $godotCommand) { $godotCommand = Get-Command 'godot.exe' -ErrorAction SilentlyContinue }
	if ($null -eq $godotCommand) { throw 'Pass -GodotExe with the installed Godot 4.7.1 console executable path.' }
	$GodotExe = $godotCommand.Source
}
if (-not (Test-Path $GodotExe)) { throw "Godot executable does not exist: $GodotExe" }
$versionStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$versionStartInfo.FileName = $GodotExe
$versionStartInfo.UseShellExecute = $false
$versionStartInfo.RedirectStandardOutput = $true
$versionStartInfo.RedirectStandardError = $true
$versionStartInfo.CreateNoWindow = $true
if ($null -eq $versionStartInfo.ArgumentList) { throw 'This runner requires a .NET runtime with ProcessStartInfo.ArgumentList support.' }
$versionStartInfo.ArgumentList.Add('--version')
$versionProcess = [System.Diagnostics.Process]::new()
$versionProcess.StartInfo = $versionStartInfo
try {
	if (-not $versionProcess.Start()) { throw "Could not start Godot executable: $GodotExe" }
	$versionStdoutTask = $versionProcess.StandardOutput.ReadToEndAsync()
	$versionStderrTask = $versionProcess.StandardError.ReadToEndAsync()
	$versionProcess.WaitForExit()
	$godotVersion = ($versionStdoutTask.GetAwaiter().GetResult() + $versionStderrTask.GetAwaiter().GetResult()).Trim()
	$versionExitCode = $versionProcess.ExitCode
} finally {
	$versionProcess.Dispose()
}
if ($versionExitCode -ne 0 -or $godotVersion -notmatch '^4\.7\.1') { throw "Godot 4.7.1 is required; found '$godotVersion' (exit code $versionExitCode)." }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$settingsHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectFile).Hash

function Invoke-GodotPhase([string]$Name, [string[]]$Arguments, [string[]]$RequiredMarkers = @()) {
	$logPath = Join-Path $OutputDirectory ($Name + '.log')
	$stdoutLogPath = Join-Path $OutputDirectory ($Name + '.stdout.log')
	$stderrLogPath = Join-Path $OutputDirectory ($Name + '.stderr.log')
	$godotLogPath = Join-Path $OutputDirectory ($Name + '.godot.log')
	$allArguments = [System.Collections.Generic.List[string]]::new()
	$logOptionAdded = $false
	foreach ($argument in $Arguments) {
		if ($argument -eq '--' -and -not $logOptionAdded) {
			$allArguments.Add('--log-file')
			$allArguments.Add($godotLogPath)
			$logOptionAdded = $true
		}
		$allArguments.Add($argument)
	}
	if (-not $logOptionAdded) {
		$allArguments.Add('--log-file')
		$allArguments.Add($godotLogPath)
	}
	$godotArgumentArray = $allArguments.ToArray()
	Write-Host "[$Name] Starting; log: $logPath"
	$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$startInfo.FileName = $GodotExe
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$startInfo.CreateNoWindow = $true
	if ($null -eq $startInfo.ArgumentList) {
		throw 'This runner requires a .NET runtime with ProcessStartInfo.ArgumentList support.'
	}
	foreach ($argument in $godotArgumentArray) { $startInfo.ArgumentList.Add($argument) }
	$process = [System.Diagnostics.Process]::new()
	$process.StartInfo = $startInfo
	try {
		if (-not $process.Start()) { throw "Could not start Godot for $Name." }
		$stdoutTask = $process.StandardOutput.ReadToEndAsync()
		$stderrTask = $process.StandardError.ReadToEndAsync()
		$process.WaitForExit()
		$stdoutText = $stdoutTask.GetAwaiter().GetResult()
		$stderrText = $stderrTask.GetAwaiter().GetResult()
		$exitCode = $process.ExitCode
	} finally {
		$process.Dispose()
	}
	$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
	[System.IO.File]::WriteAllText($stdoutLogPath, $stdoutText, $utf8WithoutBom)
	[System.IO.File]::WriteAllText($stderrLogPath, $stderrText, $utf8WithoutBom)
	$logText = $stdoutText + $stderrText
	[System.IO.File]::WriteAllText($logPath, $logText, $utf8WithoutBom)
	if ($exitCode -ne 0) { throw "$Name failed with exit code $exitCode. Logs: stdout=$stdoutLogPath; stderr=$stderrLogPath; combined=$logPath" }
	foreach ($marker in $RequiredMarkers) {
		if (-not $logText.Contains($marker)) { throw "$Name exited 0 but did not emit required marker '$marker'. Logs: stdout=$stdoutLogPath; stderr=$stderrLogPath; combined=$logPath" }
	}
	Write-Host "[$Name] ExitCode=$exitCode"
	Get-Content -LiteralPath $logPath -Tail 12 | ForEach-Object { Write-Host $_ }
	return $logPath
}

if ($FocusedPhysCorrectnessOnly) {
	Write-Host "PHYS-TARGET-FOCUSED | repo=$repoRoot | godot=$godotVersion | output=$OutputDirectory"
	$focusedLog = Invoke-GodotPhase 'phys-correctness' @('--path', $repoRoot, '--script', 'res://validation/physics/phys3_coastal_probe_runner.gd') @('PHYS3_COASTAL_COMPLETE', 'PHYS-3-A')
	Write-Host "[PASS] Focused PHYS correctness process completed. Combined log: $focusedLog"
	return
}

Write-Host "PHYS-TARGET-READY | repo=$repoRoot | godot=$godotVersion | output=$OutputDirectory"
Write-Host '[1/7] Rebuild or verify native extension.'
if ($SkipBuild) {
	& $setupScript -SkipBuild
} else {
	& $setupScript
}
if (-not $?) { throw 'Native setup/build phase failed.' }

Write-Host '[2/7] Import project sources for this clean checkout.'
$cleanTrackedImportFiles = [System.Collections.Generic.List[string]]::new()
foreach ($importPath in @(& git -C $repoRoot ls-files -- '*.import')) {
	& git -C $repoRoot diff --quiet HEAD -- $importPath
	if ($LASTEXITCODE -eq 0) { $cleanTrackedImportFiles.Add($importPath) }
}
Invoke-GodotPhase 'godot-import' @('--headless', '--editor', '--path', $repoRoot, '--import') | Out-Null
foreach ($importPath in $cleanTrackedImportFiles) {
	& git -C $repoRoot diff --quiet -- $importPath
	if ($LASTEXITCODE -eq 1) {
		& git -C $repoRoot restore --worktree -- $importPath
		if ($LASTEXITCODE -ne 0) { throw "Could not restore generated import sidecar without staging: $importPath" }
	}
}

Write-Host '[3/7] Direct GDExtension load / class / instance smoke.'
Invoke-GodotPhase 'native-load' @('--headless', '--path', $repoRoot, '--script', 'res://validation/physics/phys_target_native_load_smoke.gd') @('TARGET_NATIVE_LOAD_PASS') | Out-Null
if ($SmokeOnly) {
	Write-Host '[PASS] Smoke-only target setup, build, and GDExtension load completed.'
	return
}

Write-Host '[4/7] PHYS-1/2/3 correctness, Coastal parity, world-XZ, batch, normals, and clock.'
Invoke-GodotPhase 'phys-correctness' @('--path', $repoRoot, '--script', 'res://validation/physics/phys3_coastal_probe_runner.gd') @('PHYS3_COASTAL_COMPLETE', 'PHYS-3-A') | Out-Null

Write-Host '[5/7] Native scalar/batch performance at 1, 4, 16, 64, and 256 queries.'
Invoke-GodotPhase 'phys-native-performance' @('--path', $repoRoot, '--script', 'res://validation/physics/phys_target_native_benchmark.gd') @('TARGET_PHYS_NATIVE_COMPLETE') | Out-Null

Write-Host '[6/7] Controlled Ocean feature matrix at 1920x1080.'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$oceanOutput = Join-Path $OutputDirectory "ocean-$stamp.txt"
Invoke-GodotPhase 'ocean-benchmark' @(
	'--path', $repoRoot,
	'--scene', 'res://validation/ocean_benchmark.tscn',
	'--', '--ocean-benchmark=matrix', '--ocean-resolution=1920x1080', "--ocean-output=$oceanOutput"
) @('BLOCK B FEATURE MATRIX', 'BLOCK G GEOMETRY AND SHADOW MATRIX', 'BENCH ENV', 'RESULTS | txt=') | Out-Null

Write-Host '[7/7] Breaker B0 complete OFF / B1 lifecycle / B2 normal route.'
$breakerLog = Invoke-GodotPhase 'breaker-b0-b1-b2' @(
	'--path', $repoRoot,
	'--script', 'res://validation/physics/phys_target_breaker_benchmark.gd'
	) @('"label":"B0_R1"', '"label":"B1_R1"', '"label":"B2_R1"', 'TARGET_BREAKER_COMPLETE')

$sampleRows = @()
foreach ($line in (Get-Content -LiteralPath $breakerLog)) {
	if ($line.StartsWith('TARGET_BREAKER_SAMPLE ')) {
		try { $sampleRows += ($line.Substring('TARGET_BREAKER_SAMPLE '.Length) | ConvertFrom-Json) } catch { throw "Could not parse breaker sample line: $line" }
	}
}
$breakerSummary = @{}
foreach ($state in @('B0', 'B1', 'B2')) {
	$rows = @($sampleRows | Where-Object { $_.label -like "$state`_R*" })
	if ($rows.Count -ne 3) { throw "Expected three repeats for $state; found $($rows.Count)." }
	$breakerSummary[$state] = @{
		'repeats' = $rows.Count
		'gpu_mean_ms' = [math]::Round((($rows | Measure-Object -Property gpu_mean_ms -Average).Average), 6)
		'gpu_p95_ms' = [math]::Round((($rows | Measure-Object -Property gpu_p95_ms -Average).Average), 6)
		'cpu_mean_ms' = [math]::Round((($rows | Measure-Object -Property cpu_mean_ms -Average).Average), 6)
		'cpu_p95_ms' = [math]::Round((($rows | Measure-Object -Property cpu_p95_ms -Average).Average), 6)
		'frame_mean_ms' = [math]::Round((($rows | Measure-Object -Property frame_mean_ms -Average).Average), 6)
		'frame_p95_ms' = [math]::Round((($rows | Measure-Object -Property frame_p95_ms -Average).Average), 6)
	}
}
$breakerDeltas = @{}
foreach ($pair in @(@('B1-B0', 'B1', 'B0'), @('B2-B1', 'B2', 'B1'), @('B2-B0', 'B2', 'B0'))) {
	$breakerDeltas[$pair[0]] = @{
		'gpu_mean_ms' = [math]::Round($breakerSummary[$pair[1]].gpu_mean_ms - $breakerSummary[$pair[2]].gpu_mean_ms, 6)
		'cpu_mean_ms' = [math]::Round($breakerSummary[$pair[1]].cpu_mean_ms - $breakerSummary[$pair[2]].cpu_mean_ms, 6)
		'frame_mean_ms' = [math]::Round($breakerSummary[$pair[1]].frame_mean_ms - $breakerSummary[$pair[2]].frame_mean_ms, 6)
	}
}
$summary = [ordered]@{
	classification = 'TARGET VALIDATION CAPTURE'
	repository = $repoRoot
	godot = $godotVersion
	cpu = $null
	output_directory = $OutputDirectory
	benchmark_resolution = '1920x1080'
	project_settings_sha256_before = $settingsHashBefore
	project_settings_sha256_after = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectFile).Hash
	project_settings_unchanged = ($settingsHashBefore -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $projectFile).Hash)
	breaker = @{ states = $breakerSummary; deltas = $breakerDeltas }
}
$targetEnvironmentLine = Get-Content -LiteralPath $breakerLog | Where-Object { $_.StartsWith('TARGET_BREAKER_ENV ') } | Select-Object -First 1
if ($targetEnvironmentLine) {
	$targetEnvironment = $targetEnvironmentLine.Substring('TARGET_BREAKER_ENV '.Length) | ConvertFrom-Json
	$summary.cpu = $targetEnvironment.cpu
	$summary.gpu = $targetEnvironment.gpu
	$summary.breaker_camera_transform = $targetEnvironment.camera_transform
}
$runtimeErrors = @(
	Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.log' -File |
		ForEach-Object { Get-Content -LiteralPath $_.FullName } |
		Where-Object { $_ -match '^ERROR:' }
)
$summary.runtime_error_count = $runtimeErrors.Count
$summary.runtime_error_samples = @($runtimeErrors | Select-Object -First 20)
$summaryPath = Join-Path $OutputDirectory 'target-validation-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if (-not $summary.project_settings_unchanged) { throw 'project.godot changed during target validation; inspect the checkout before continuing.' }
Write-Host "[PASS] Target validation completed. Summary: $summaryPath"
if ($runtimeErrors.Count -gt 0) { Write-Warning "Captured $($runtimeErrors.Count) Godot ERROR line(s); full logs and the first 20 lines are in the output summary." }
Write-Host "Breaker deltas: $((ConvertTo-Json -InputObject $breakerDeltas -Compress))"
