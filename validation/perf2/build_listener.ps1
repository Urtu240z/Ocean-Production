$ErrorActionPreference = 'Stop'
$perf2ToolDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\temp\perf2-tools'))
New-Item -ItemType Directory -Path $perf2ToolDirectory -Force | Out-Null
$perf2VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$perf2Vs = & $perf2VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $perf2Vs) { throw 'Se necesita MSVC para compilar el capturador PERF-2 independiente.' }
$perf2VcVars = Join-Path $perf2Vs 'VC\Auxiliary\Build\vcvars64.bat'
$perf2Source = Join-Path $PSScriptRoot 'auto_capture_listener.cpp'
$perf2Exe = Join-Path $perf2ToolDirectory 'auto_capture_listener.exe'
$perf2Object = Join-Path $perf2ToolDirectory 'auto_capture_listener.obj'
$perf2BuildLog = Join-Path $perf2ToolDirectory 'build.log'
$perf2Command = 'call "{0}" >nul && cl /nologo /std:c++17 /EHsc /O2 /W4 /DUNICODE /D_UNICODE "{1}" /Fo"{2}" /Fe"{3}" /link advapi32.lib tdh.lib > "{4}" 2>&1' -f $perf2VcVars,$perf2Source,$perf2Object,$perf2Exe,$perf2BuildLog
& $env:COMSPEC /d /c $perf2Command
if ($LASTEXITCODE -ne 0) { throw "No se pudo compilar el capturador. Registro: $perf2BuildLog" }
Write-Output $perf2Exe
