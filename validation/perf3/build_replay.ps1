$ErrorActionPreference = 'Stop'
$perf3Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$perf3Tools = Join-Path $perf3Root 'temp\perf3-tools'
New-Item -ItemType Directory -Path $perf3Tools -Force | Out-Null
$perf3VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$perf3Vs = & $perf3VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$perf3VcVars = Join-Path $perf3Vs 'VC\Auxiliary\Build\vcvars64.bat'
$perf3Native = Join-Path $perf3Root 'addons\ocean\physics\native\ocean_query\src'
$perf3Replay = Join-Path $PSScriptRoot 'fft_replay.cpp'
$perf3Kernel = Join-Path $perf3Native 'dynamic_ocean_fft_avx2.cpp'
$perf3Exe = Join-Path $perf3Tools 'fft_replay.exe'
$perf3BuildLog = Join-Path $perf3Tools 'build.log'
$perf3Command = 'call "{0}" >nul && cl /nologo /std:c++17 /EHsc /O2 /W4 /arch:AVX2 /DOQ_FFT_REPLAY_ONLY /I"{1}" "{2}" "{3}" /Fo"{4}\\" /Fe"{5}" > "{6}" 2>&1' -f $perf3VcVars,$perf3Native,$perf3Replay,$perf3Kernel,$perf3Tools,$perf3Exe,$perf3BuildLog
& $env:COMSPEC /d /c $perf3Command
if ($LASTEXITCODE -ne 0) { throw "Fallo compilando la repeticion. Registro: $perf3BuildLog" }
Write-Output $perf3Exe
