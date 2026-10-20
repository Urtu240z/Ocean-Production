$ErrorActionPreference = 'Stop'
$hullRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$hullOutput = Join-Path $hullRoot 'temp/hull_native_1'
New-Item -ItemType Directory -Path $hullOutput -Force | Out-Null
$hullDll = Join-Path $hullRoot 'addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll'
$hullBackup = Join-Path $hullOutput 'baseline_native.dll'
if (-not (Test-Path -LiteralPath $hullBackup)) { Copy-Item -LiteralPath $hullDll -Destination $hullBackup }
$hullVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$hullVs = & $hullVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$hullVcVars = Join-Path $hullVs 'VC/Auxiliary/Build/vcvars64.bat'
$hullNative = Join-Path $hullRoot 'addons/ocean/physics/native/ocean_query'
$hullLog = Join-Path $hullOutput 'extension_build.log'
$hullCommand = 'call "{0}" >nul && "C:\Python314\python.exe" -m SCons -C "{1}" platform=windows target=template_release -j8 > "{2}" 2>&1' -f $hullVcVars,$hullNative,$hullLog
& $env:COMSPEC /d /c $hullCommand
if ($LASTEXITCODE -ne 0) { throw "Native build failed: $hullLog" }
Write-Output 'HULL_NATIVE_BUILD_OK'
