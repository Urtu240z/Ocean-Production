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
	$candidateVersion = (& $candidate --version 2>&1 | Out-String).Trim()
	if ($LASTEXITCODE -eq 0 -and $candidateVersion -match '^Python\s+\d+\.\d+') {
		$pythonExe = $candidate
		$pythonVersion = $candidateVersion
		break
	}
}
if ($null -eq $pythonExe) { throw 'A working Python 3 interpreter was not found. Install Python and add it to PATH; this script does not install Python.' }
$sconsVersionText = (& $pythonExe -m SCons --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $sconsVersionText -notmatch 'SCons:\s*v4\.11\.1') {
	Write-Host '  Installing the small, pinned SCons package into the selected Python environment.'
	& $pythonExe -m pip install --disable-pip-version-check --no-input 'scons==4.11.1'
	if ($LASTEXITCODE -ne 0) { throw 'Could not install SCons 4.11.1 with the selected Python interpreter.' }
	$sconsVersionText = (& $pythonExe -m SCons --version 2>&1 | Out-String).Trim()
	if ($LASTEXITCODE -ne 0 -or $sconsVersionText -notmatch 'SCons:\s*v4\.11\.1') { throw 'The selected Python environment does not provide SCons 4.11.1.' }
}
Write-Host "  $pythonVersion ($pythonExe)"
Write-Host "  $($sconsVersionText -split "`r?`n" | Select-Object -First 1)"

Write-Host '[3/7] Locate Visual Studio 2022 Build Tools x64 environment'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "Visual Studio Installer's vswhere.exe was not found at $vswhere" }
$vsInstall = (& $vswhere -latest -products Microsoft.VisualStudio.Product.BuildTools -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vsInstall)) {
	throw 'Visual Studio C++ x64 Build Tools were not found. Install VS 2022 Build Tools with the x64 C++ component and Windows SDK; no installer is launched here.'
}
$vcvars64 = Join-Path $vsInstall 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars64)) { throw "vcvars64.bat was not found at $vcvars64" }
Write-Host "  Visual Studio environment: $vcvars64"

Write-Host '[4/7] Build OceanQueryNative for Windows x86_64 template_release'
$buildStarted = [System.Diagnostics.Stopwatch]::StartNew()
$buildExitCode = 0
if (-not $SkipBuild) {
	$batchPath = Join-Path $env:TEMP ("ocean-native-build-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
	$batchContent = @"
@echo off
call "$vcvars64"
if errorlevel 1 exit /b %ERRORLEVEL%
echo [TOOLCHAIN] compiler path:
where cl
echo [TOOLCHAIN] compiler version:
cl /Bv /? 2>&1 | findstr /R /C:"19\.[0-9][0-9]\."
if not defined WindowsSdkDir (
  echo [FAIL] WindowsSdkDir is undefined.
  exit /b 21
)
if not defined WindowsSDKVersion (
  echo [FAIL] WindowsSDKVersion is undefined.
  exit /b 22
)
if not defined INCLUDE (
  echo [FAIL] INCLUDE is undefined.
  exit /b 23
)
if not defined LIB (
  echo [FAIL] LIB is undefined.
  exit /b 24
)
echo [TOOLCHAIN] Windows SDK %WindowsSDKVersion% at %WindowsSdkDir%
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
