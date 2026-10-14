$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows_capture_core.ps1')
$perf2NativeRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf2-native-error-tests\' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $perf2NativeRoot -Force | Out-Null
$perf2NativeExe=Join-Path $perf2NativeRoot 'fake_native_wpr.exe'
Add-Type -OutputAssembly $perf2NativeExe -OutputType ConsoleApplication -TypeDefinition @'
using System;
public class FakeNativeWpr {
    public static int Main(string[] args) {
        if(args[0]=="-status") {Console.WriteLine("WPR is not recording");return 0;}
        if(args[0]=="-profiledetails") {Console.WriteLine("Mock validated");return 0;}
        if(args[0]=="--warning") {Console.Error.WriteLine("warning with success fixture");Console.WriteLine("valid stdout fixture");return 0;}
        Console.Error.WriteLine("");
        Console.Error.WriteLine("Hardware resource error fixture 0x800700AA");
        Console.WriteLine("Additional diagnostic stdout fixture");
        return 87;
    }
}
'@
$perf2Message=''
try {Invoke-Perf2NativeWpr -Executable $perf2NativeExe -WprArguments @('-start','fake profile') | Out-Null} catch {$perf2Message=$_.Exception.Message}
if($perf2Message -notlike '*codigo 87*' -or $perf2Message -notlike '*0x800700AA*' -or $perf2Message -notlike '*Additional diagnostic stdout*') {throw 'Lost native error after blank stderr line'}
if($ErrorActionPreference -ne 'Stop') {throw 'Caller error policy changed'}
$perf2Output=Invoke-Perf2NativeWpr -Executable $perf2NativeExe -WprArguments @('--warning')
if($perf2Output -notlike '*warning with success*' -or $perf2Output -notlike '*valid stdout*') {throw 'Success with stderr warning was rejected'}
$perf2MissingRejected=$false
try {Invoke-Perf2NativeWpr -Executable (Join-Path $perf2NativeRoot 'missing.exe') -WprArguments @('-status') | Out-Null} catch {$perf2MissingRejected=$true}
if(-not $perf2MissingRejected) {throw 'Missing executable accepted with stale exit code'}
$perf2Failed=$false
try {Invoke-Perf2Capture -Mode Start -Root $perf2NativeRoot -ProfilePath (Join-Path $PSScriptRoot 'Perf2.wprp') -GameReportPath (Join-Path $perf2NativeRoot 'absent.json') -WprPath $perf2NativeExe | Out-Null} catch {$perf2Failed=$true}
if(-not $perf2Failed) {throw 'Failed native start accepted'}
$perf2State=Get-Content (Join-Path $perf2NativeRoot 'active_capture.json') -Raw | ConvertFrom-Json
$perf2Stored=Get-Content (Join-Path $perf2State.session_directory 'wpr_start_error.txt') -Raw
if($perf2Stored -notlike '*0x800700AA*' -or $perf2Stored -notlike '*codigo 87*') {throw 'Start error not persisted'}
Write-Host 'PERF2_NATIVE_ERROR PASS: real native stderr/blank lines, exit code, warnings, preference restoration, missing executable and stored start error. Mock executable; no Windows trace.'
