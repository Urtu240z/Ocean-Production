[CmdletBinding()]
param(
	[string]$GodotExe,
	[switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$nativePath = Join-Path $repoRoot 'addons\ocean\physics\native\ocean_query'
$godotCppPath = Join-Path $repoRoot 'addons\ocean\physics\native\godot-cpp'
$expectedGodotCppCommit = '507ed9d840c01a3c5b2a39af8bb4000bfac30bf5'
$expectedGodotCppTag = '10.0.0-stable'
$expectedDll = Join-Path $nativePath 'bin\ocean_query_native.windows.template_release.x86_64.dll'
$descriptor = Join-Path $nativePath 'ocean_query_native.gdextension'

function Invoke-NativeGit([string[]]$GitArgs) {
	& git @GitArgs
	if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

function Invoke-NativeCapture([string]$Executable, [string[]]$Arguments) {
	$previousErrorActionPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$output = (& $Executable @Arguments 2>&1 | Out-String).Trim()
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousErrorActionPreference
	}
	return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

if (-not (Test-Path (Join-Path $repoRoot 'project.godot'))) {
	throw "Could not resolve the repository root from $PSScriptRoot"
}

Write-Host '[1/7] Resolve pinned godot-cpp dependency'
if (-not (Test-Path (Join-Path $godotCppPath '.git'))) {
	if (Test-Path $godotCppPath) {
		throw "A non-Git path already exists at $godotCppPath; preserve it and resolve it manually."
	}
	Invoke-NativeGit @('clone', '--branch', $expectedGodotCppTag, '--depth', '1', 'https://github.com/godotengine/godot-cpp.git', $godotCppPath)
}
$actualGodotCppCommit = (& git -C $godotCppPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read godot-cpp HEAD.' }
if ($actualGodotCppCommit -ne $expectedGodotCppCommit) {
	throw "godot-cpp revision mismatch. Expected $expectedGodotCppCommit ($expectedGodotCppTag), found $actualGodotCppCommit. The script will not switch an existing checkout."
}
$actualGodotCppTag = (& git -C $godotCppPath describe --tags --exact-match HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $actualGodotCppTag -ne $expectedGodotCppTag) {
	throw "godot-cpp HEAD is not exactly tagged $expectedGodotCppTag. Found '$actualGodotCppTag'."
}
if (-not (Test-Path (Join-Path $godotCppPath 'SConstruct'))) { throw "Pinned godot-cpp has no SConstruct at $godotCppPath" }
$gdignore = Join-Path $godotCppPath '.gdignore'
if (-not (Test-Path $gdignore)) {
	Set-Content -LiteralPath $gdignore -Value 'Local pinned C++ dependency. Exclude generated C++/build files from Godot resource scanning.' -Encoding ascii
}
$ignoreResult = & git -C $repoRoot check-ignore -v (Join-Path $godotCppPath 'SConstruct')
if ($LASTEXITCODE -ne 0) { throw 'The local godot-cpp checkout is not ignored by Git. Check the repository .gitignore.' }
Write-Host "  tag=$expectedGodotCppTag commit=$actualGodotCppCommit path=$godotCppPath"
Write-Host "  Git ignore: $ignoreResult"

Write-Host '[2/7] Resolve Python and pinned SCons'
$pythonCandidates = [System.Collections.Generic.List[string]]::new()
foreach ($commandName in @('python', 'python3')) {
	$pythonCommand = Get-Command $commandName -ErrorAction SilentlyContinue
	if ($null -ne $pythonCommand -and -not $pythonCandidates.Contains($pythonCommand.Source)) { $pythonCandidates.Add($pythonCommand.Source) }
}
# Prefer a working user-local Python if PATH only exposes the disabled Microsoft Store alias.
$localPython = Join-Path $env:LOCALAPPDATA 'phys1-python312\Scripts\python.exe'
if ((Test-Path $localPython) -and -not $pythonCandidates.Contains($localPython)) { $pythonCandidates.Add($localPython) }
$pythonExe = $null
$pythonVersion = $null
foreach ($candidate in $pythonCandidates) {
	$pythonProbe = Invoke-NativeCapture $candidate @('--version')
	if ($pythonProbe.ExitCode -eq 0 -and $pythonProbe.Output -match '^Python\s+\d+\.\d+') {
		$pythonExe = $candidate
		$pythonVersion = $pythonProbe.Output
		break
	}
}
if ($null -eq $pythonExe) { throw 'A working Python 3 interpreter was not found. Install Python and add it to PATH; this script does not install Python.' }
$sconsProbe = Invoke-NativeCapture $pythonExe @('-m', 'SCons', '--version')
if ($sconsProbe.ExitCode -ne 0 -or $sconsProbe.Output -notmatch 'SCons:\s*v4\.11\.1') {
	Write-Host '  Installing the small, pinned SCons package into the selected Python environment.'
	$installResult = Invoke-NativeCapture $pythonExe @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', 'scons==4.11.1')
	if ($installResult.Output) { Write-Host $installResult.Output }
	if ($installResult.ExitCode -ne 0) { throw 'Could not install SCons 4.11.1 with the selected Python interpreter.' }
	$sconsProbe = Invoke-NativeCapture $pythonExe @('-m', 'SCons', '--version')
	if ($sconsProbe.ExitCode -ne 0 -or $sconsProbe.Output -notmatch 'SCons:\s*v4\.11\.1') { throw 'The selected Python environment does not provide SCons 4.11.1.' }
}
$sconsVersionText = $sconsProbe.Output
Write-Host "  $pythonVersion ($pythonExe)"
Write-Host "  $sconsVersionText"

Write-Host '[3/7] Locate Build Tools with the pinned MSVC 14.44 toolset'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "Visual Studio Installer's vswhere.exe was not found at $vswhere" }
$vswhereJson = (& $vswhere -all -products Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'vswhere could not enumerate Visual Studio Build Tools instances.' }
$vsInstances = @()
foreach ($parsedInstance in (ConvertFrom-Json -InputObject $vswhereJson)) {
	if ($null -ne $parsedInstance) { $vsInstances += $parsedInstance }
}
$compatibleBuildTools = @()
foreach ($instance in $vsInstances) {
	if ($instance.installationPath -isnot [string] -or $instance.installationVersion -isnot [string]) {
		throw 'vswhere returned a Build Tools instance with a non-scalar installation path or version.'
	}
	$installationPath = [string]$instance.installationPath
	$installationVersionText = [string]$instance.installationVersion
	$installationVersion = $null
	if (-not [version]::TryParse($installationVersionText, [ref]$installationVersion)) {
		throw "vswhere returned an invalid installation version '$installationVersionText'."
	}
	$toolsetRoot = Join-Path $installationPath 'VC\Tools\MSVC'
	if (-not (Test-Path $toolsetRoot)) { continue }
	$toolsetCandidates = @()
	foreach ($toolsetDirectory in @(Get-ChildItem -LiteralPath $toolsetRoot -Directory -Filter '14.44.*' -ErrorAction SilentlyContinue)) {
		$toolsetVersionText = [string]$toolsetDirectory.Name
		$toolsetVersion = $null
		if (-not [version]::TryParse($toolsetVersionText, [ref]$toolsetVersion)) { continue }
		$toolsetCandidates += [pscustomobject]@{
			Directory = $toolsetDirectory
			Version = $toolsetVersion
		}
	}
	$selectedToolset = $toolsetCandidates | Sort-Object -Property Version -Descending | Select-Object -First 1
	if ($null -eq $selectedToolset) { continue }
	$compatibleBuildTools += [pscustomobject]@{
		Instance = $instance
		InstallationPath = $installationPath
		InstallationVersion = $installationVersion
		Toolset = $selectedToolset.Directory
	}
}
if ($compatibleBuildTools.Count -eq 0) {
	throw 'No Visual Studio Build Tools instance with the x64 C++ component and an installed MSVC 14.44.* toolset was found.'
}
$selectedBuildTools = $compatibleBuildTools | Sort-Object -Property InstallationVersion -Descending | Select-Object -First 1
$vsInstall = $selectedBuildTools.InstallationPath
$selectedToolsetPath = $selectedBuildTools.Toolset.FullName
$selectedToolsetVersion = $selectedBuildTools.Toolset.Name
$vcvars64 = Join-Path $vsInstall 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars64)) { throw "vcvars64.bat was not found at $vcvars64" }
Write-Host "  Selected Build Tools: $($selectedBuildTools.Instance.displayName) $($selectedBuildTools.InstallationVersion)"
Write-Host "  Selected VS installation: $vsInstall"
Write-Host "  Selected VC toolset: $selectedToolsetVersion"
Write-Host "  vcvars command: `"$vcvars64`" -vcvars_ver=14.44"

Write-Host '[4/7] Build OceanQueryNative for Windows x86_64 template_release'
$buildStarted = [System.Diagnostics.Stopwatch]::StartNew()
$buildExitCode = 0
if (-not $SkipBuild) {
	$batchPath = Join-Path $env:TEMP ("ocean-native-build-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
	$batchContent = @"
@echo off
call "$vcvars64" -vcvars_ver=14.44
if errorlevel 1 exit /b %ERRORLEVEL%
echo [TOOLCHAIN] compiler path:
where cl
set "CL_PATH="
for /f "delims=" %%C in ('where cl') do if not defined CL_PATH set "CL_PATH=%%C"
echo [TOOLCHAIN] selected VC toolset: $selectedToolsetVersion
echo [TOOLCHAIN] actual compiler path: %CL_PATH%
if /I "%CL_PATH%"=="$selectedToolsetPath\bin\HostX64\x64\cl.exe" goto cl_path_ok
echo [FAIL] Active cl.exe is not from the selected MSVC 14.44 toolset.
exit /b 25
:cl_path_ok
echo [TOOLCHAIN] compiler version:
cl /Bv 2>&1 | findstr /I /R /C:"19\.44\.[0-9][0-9]*"
if errorlevel 1 (
  echo [FAIL] Active compiler version is not 19.44.x.
  exit /b 26
)
if not defined WindowsSdkDir (
  echo [FAIL] WindowsSdkDir is undefined.
  exit /b 21
)
if exist "%WindowsSdkDir%" goto sdk_dir_ok
echo [FAIL] WindowsSdkDir does not exist: %WindowsSdkDir%
exit /b 27
:sdk_dir_ok
if not defined WindowsSDKVersion (
  echo [FAIL] WindowsSDKVersion is undefined.
  exit /b 22
)
set "SDK_VERSION=%WindowsSDKVersion:\=%"
echo [TOOLCHAIN] Windows SDK %SDK_VERSION% at %WindowsSdkDir%
echo %SDK_VERSION%| findstr /R /C:"^10\.0\.26100\.[0-9][0-9]*$" >nul
if errorlevel 1 (
  echo [FAIL] Windows SDK must be from the validated 10.0.26100 family.
  exit /b 28
)
if not defined INCLUDE (
  echo [FAIL] INCLUDE is undefined.
  exit /b 23
)
if not defined LIB (
  echo [FAIL] LIB is undefined.
  exit /b 24
)
echo [TOOLCHAIN] INCLUDE and LIB are initialized.
echo [TOOLCHAIN] Python:
"$pythonExe" --version
echo [TOOLCHAIN] SCons:
"$pythonExe" -m SCons --version
echo [BUILD] working directory: $nativePath
echo [BUILD] command: "$pythonExe" -m SCons platform=windows target=template_release
pushd "$nativePath"
"$pythonExe" -m SCons platform=windows target=template_release
set "BUILD_EXIT=%ERRORLEVEL%"
popd
exit /b %BUILD_EXIT%
"@
	Set-Content -LiteralPath $batchPath -Value $batchContent -Encoding ascii
	try {
		& $env:ComSpec /d /c $batchPath
		$buildExitCode = $LASTEXITCODE
	} finally {
		Remove-Item -LiteralPath $batchPath -Force -ErrorAction SilentlyContinue
	}
	$buildStarted.Stop()
	if ($buildExitCode -ne 0) { throw "Native build failed with exit code $buildExitCode after $([math]::Round($buildStarted.Elapsed.TotalSeconds, 2)) seconds." }
} else {
	$buildStarted.Stop()
	Write-Host '  Build skipped by -SkipBuild.'
}

Write-Host '[5/7] Verify generated DLL and GDExtension descriptor'
if (-not (Test-Path $expectedDll)) { throw "Expected native DLL was not generated: $expectedDll" }
if ((Get-Item -LiteralPath $expectedDll).Length -le 0) { throw "Generated native DLL is empty: $expectedDll" }
if (-not (Test-Path $descriptor)) { throw "SCons did not generate the active descriptor: $descriptor" }
$descriptorText = Get-Content -LiteralPath $descriptor -Raw
if ($descriptorText -notmatch 'entry_symbol\s*=\s*"ocean_query_native_library_init"') { throw 'Generated descriptor has the wrong entry symbol.' }
if ($descriptorText -notmatch 'windows\.x86_64\s*=\s*"res://addons/ocean/physics/native/ocean_query/bin/ocean_query_native\.windows\.template_release\.x86_64\.dll"') {
	throw 'Generated descriptor does not map Windows x86_64 template_release to the built DLL.'
}
Write-Host "  DLL=$expectedDll bytes=$((Get-Item -LiteralPath $expectedDll).Length)"
Write-Host "  descriptor=$descriptor entry=ocean_query_native_library_init"
Write-Host "  build_elapsed_seconds=$([math]::Round($buildStarted.Elapsed.TotalSeconds, 2))"

Write-Host '[6/7] Ensure compiler outputs remain ignored'
foreach ($sample in @(
	$expectedDll,
	(Join-Path $nativePath 'build\obj\ocean_query_core.windows.template_release.x86_64.obj'),
	(Join-Path $nativePath '.sconsign.dblite'),
	$descriptor,
	("$descriptor.uid")
)) {
	$ignored = & git -C $repoRoot check-ignore -v $sample
	if ($LASTEXITCODE -ne 0) { throw "Generated native path is not ignored: $sample" }
	Write-Host "  $ignored"
}

Write-Host '[7/7] Optional direct Godot load test'
if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
	if (-not (Test-Path $GodotExe)) { throw "Godot executable does not exist: $GodotExe" }
	$smokeLog = Join-Path $env:TEMP ("phys-target-load-{0}.log" -f [guid]::NewGuid().ToString('N'))
	& $GodotExe --headless --path $repoRoot --script 'res://validation/physics/phys_target_native_load_smoke.gd' --log-file $smokeLog
	if ($LASTEXITCODE -ne 0) { throw "Godot native load smoke failed with exit code $LASTEXITCODE. Log: $smokeLog" }
	$smokeText = Get-Content -LiteralPath $smokeLog -Raw
	if (-not $smokeText.Contains('TARGET_NATIVE_LOAD_PASS') -or $smokeText.Contains('TARGET_NATIVE_LOAD_FAIL')) {
		throw "Godot exited without proving native registration and instantiation. Log: $smokeLog"
	}
	Write-Host "  load_smoke=PASS log=$smokeLog"
} else {
	Write-Host '  Skipped. Pass -GodotExe to test native class registration and instantiation.'
}

Write-Host '[PASS] Native Windows build prerequisites and artifact contract are verified.'
