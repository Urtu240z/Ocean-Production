$ErrorActionPreference = 'Stop'
$asyncRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$asyncTools = Join-Path $asyncRoot 'temp\async_fft'
New-Item -ItemType Directory -Path $asyncTools -Force | Out-Null
$asyncVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$asyncVs = & $asyncVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$asyncVcVars = Join-Path $asyncVs 'VC\Auxiliary\Build\vcvars64.bat'
$asyncNative = Join-Path $asyncRoot 'addons\ocean\physics\native\ocean_query\src'
$asyncLog = Join-Path $asyncTools 'native_build.log'
$asyncExe = Join-Path $asyncTools 'async_fft_lite_test.exe'
# Match production translation-unit flags: baseline code receives no /arch,
# AVX2 kernels alone receive /arch:AVX2. Keep default /fp:precise in both.
$asyncCommands = @('call "{0}" >nul' -f $asyncVcVars)
foreach ($asyncSource in @('dynamic_ocean_physics_field','dynamic_ocean_lite_async','ocean_query_core')) {
    $asyncCommands += 'cl /nologo /std:c++17 /EHsc /O2 /W4 /fp:precise /c /I"{0}" "{0}\{1}.cpp" /Fo"{2}\{1}.obj"' -f $asyncNative,$asyncSource,$asyncTools
}
foreach ($asyncSource in @('dynamic_ocean_fft_avx2','ocean_query_simd_avx2')) {
    $asyncCommands += 'cl /nologo /std:c++17 /EHsc /O2 /W4 /fp:precise /arch:AVX2 /c /I"{0}" "{0}\{1}.cpp" /Fo"{2}\{1}.obj"' -f $asyncNative,$asyncSource,$asyncTools
}
$asyncCommands += 'cl /nologo /std:c++17 /EHsc /O2 /W4 /fp:precise /I"{0}" "{1}\async_fft_lite_native_test.cpp" "{2}\dynamic_ocean_physics_field.obj" "{2}\dynamic_ocean_lite_async.obj" "{2}\dynamic_ocean_fft_avx2.obj" "{2}\ocean_query_core.obj" "{2}\ocean_query_simd_avx2.obj" /Fo"{2}\async_fft_lite_native_test.obj" /Fe"{3}"' -f $asyncNative,$PSScriptRoot,$asyncTools,$asyncExe
& $env:COMSPEC /d /c (($asyncCommands -join ' && ') + ' > "' + $asyncLog + '" 2>&1')
if ($LASTEXITCODE -ne 0) { throw "Native build failed: $asyncLog" }
Write-Output $asyncExe
