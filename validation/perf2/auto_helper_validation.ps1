$ErrorActionPreference = 'Stop'
# This fixture uses a fake WPR and a fake listener, never a real Windows trace.
. (Join-Path $PSScriptRoot 'windows_capture_core.ps1')
. (Join-Path $PSScriptRoot 'windows_auto_capture.ps1')
$perf2AutoTestRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf2-auto-tests\' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $perf2AutoTestRoot -Force | Out-Null
$perf2FakeGame = Join-Path $perf2AutoTestRoot 'game.json'
$perf2FakeResult = Join-Path $perf2AutoTestRoot 'operation_auto.json'
$perf2FakeListener = Join-Path $perf2AutoTestRoot 'fake_listener.exe'
Add-Type -OutputAssembly $perf2FakeListener -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.IO; using System.Threading;
public class FakePerf2Listener {
    public static void Main(string[] args) {
        string output=null,ready=null,cancel=null;
        for(int i=0;i<args.Length-1;i+=2) {if(args[i]=="--output") output=args[i+1]; if(args[i]=="--ready") ready=args[i+1]; if(args[i]=="--cancel") cancel=args[i+1];}
        if(Path.GetFileName(cancel)=="listener.cancel" || File.Exists(cancel)) throw new Exception("Reused stale cancellation marker");
        File.WriteAllText(ready,"{\"ready\":true,\"listener_pid\":"+System.Diagnostics.Process.GetCurrentProcess().Id+"}");Thread.Sleep(600);
        File.WriteAllText(output,"{\"source\":\"realtime_etw\",\"process_id\":1234,\"process_frame\":100,\"interval_us\":63000,\"end_qpc\":1000}");
    }
}
'@
$perf2Context = @(68..132 | ForEach-Object { @{process_frame=$_} })
$perf2GoodReport = @{metadata=@{capture='PERF-2';scene='res://test';windows_correlation=@{process_id=1234}};saved_utc=[DateTime]::UtcNow.AddMinutes(1).ToString('o');perf2=@{frames=$perf2Context;frame_hitch_windows=@()}}
Write-Perf2Json -Path $perf2FakeGame -Value $perf2GoodReport
$script:perf2AutoFakeActive = $false
$script:perf2AutoFakeStopCount = 0
function Fake-Perf2AutoWpr {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
    $global:LASTEXITCODE = 0
    switch ($Remaining[0]) {
        '-status' { if ($script:perf2AutoFakeActive) {return 'Profile : Perf2.Verbose.Memory'} else {return 'WPR is not recording'} }
        '-profiledetails' {return 'Mock profile'}
        '-start' {$script:perf2AutoFakeActive=$true;return 'Mock started'}
        '-stop' {
            if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $Remaining[1]) 'trigger.json'))) {throw 'Trigger missing before WPR stop'}
            $script:perf2AutoFakeStopCount++
            [IO.File]::WriteAllText($Remaining[1],'MOCK_ETL_ONLY_NOT_A_WINDOWS_TRACE')
            $script:perf2AutoFakeActive=$false;return 'Mock stopped'
        }
    }
    throw 'Unexpected mock WPR argument'
}
$perf2AutoResult = Invoke-Perf2AutoCapture -Root $perf2AutoTestRoot -ProfilePath (Join-Path $PSScriptRoot 'Perf2.wprp') -GameReportPath $perf2FakeGame -WprPath 'Fake-Perf2AutoWpr' -ResultPath $perf2FakeResult -ListenerPath $perf2FakeListener
if (-not $perf2AutoResult.success -or $script:perf2AutoFakeStopCount -ne 1) {throw 'Automatic stop failed'}
$perf2AutoManifest = Get-Content -LiteralPath (Join-Path $perf2AutoResult.session_directory 'manifest.json') -Raw | ConvertFrom-Json
if ($perf2AutoManifest.trigger_report_status -ne 'matched_with_context') {throw 'Context was not validated'}
$perf2Trigger = @{process_id=1234;process_frame=100}
$perf2GoodReport.metadata.windows_correlation.process_id=9999
if (Test-Perf2TriggerReport -Report $perf2GoodReport -Trigger $perf2Trigger) {throw 'Accepted another process'}
$perf2GoodReport.metadata.windows_correlation.process_id=1234
$perf2GoodReport.perf2.frames=@($perf2Context | Where-Object {$_.process_frame -ne 99})
if (Test-Perf2TriggerReport -Report $perf2GoodReport -Trigger $perf2Trigger) {throw 'Accepted a gap inside context'}
$perf2GoodReport.perf2.frames=@(68..100 | ForEach-Object {@{process_frame=$_}})
if (Test-Perf2TriggerReport -Report $perf2GoodReport -Trigger $perf2Trigger) {throw 'Accepted incomplete post-context'}
$perf2Missing = Wait-Perf2TriggerReport -Directory $perf2AutoResult.session_directory -GameReportPath (Join-Path $perf2AutoTestRoot 'absent.json') -Trigger $perf2Trigger -TimeoutSeconds 0
if ($perf2Missing -notlike '*absent.json') {throw 'Missing report fallback failed'}
Write-Host 'PERF2_AUTO_HELPER PASS: automatic stop, trace before context wait, matching process/frame, incomplete report rejection. Mock Windows trace only.'

$perf2FailListener = Join-Path $perf2AutoTestRoot 'failed_listener.exe'
Add-Type -OutputAssembly $perf2FailListener -OutputType ConsoleApplication -TypeDefinition @'
public class FailedPerf2Listener {
    public static int Main(string[] args) {System.Console.Error.WriteLine("StartTrace error 183 (another listener is still active)");return 23;}
}
'@
$perf2Caught = ''
try { Invoke-Perf2AutoCapture -Root $perf2AutoTestRoot -ProfilePath (Join-Path $PSScriptRoot 'Perf2.wprp') -GameReportPath $perf2FakeGame -WprPath 'Fake-Perf2AutoWpr' -ResultPath $perf2FakeResult -ListenerPath $perf2FailListener | Out-Null }
catch { $perf2Caught = $_.Exception.Message }
if ($perf2Caught -notlike '*StartTrace error 183*' -or -not $script:perf2AutoFakeActive -or $script:perf2AutoFakeStopCount -ne 1) {throw 'Listener failure detail or WPR preservation failed'}
Write-Host 'PERF2_AUTO_ERROR PASS: exact startup error visible; WPR remains recording. Mock only.'
