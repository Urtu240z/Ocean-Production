$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_capture_core.ps1')
$perf2TestRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf2-helper-tests\' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $perf2TestRoot -Force | Out-Null
$perf2TestReport = Join-Path $perf2TestRoot 'game.json'
Write-Perf2Json -Path $perf2TestReport -Value @{metadata=@{capture='PERF-2';scene='res://gameplay/jet_ski_ocean.tscn';windows_correlation=@{process_id=1234}};saved_utc=[DateTime]::UtcNow.AddMinutes(2).ToString('yyyy-MM-ddTHH:mm:ss')}
$script:perf2FakeActive = $false
$script:perf2FakeOther = $false
$script:perf2FakeFailStop = $false
$script:perf2FakeStopCalls = 0
function Fake-Perf2Wpr {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
    $global:LASTEXITCODE = 0
    if ($Remaining[0] -eq '-status') {
        if (-not $script:perf2FakeActive) { return 'WPR is not recording' }
        if ($Remaining -notcontains 'profiles') { return 'WPR recording is in progress... Time since start: 00:01:00' }
        if ($script:perf2FakeOther) { return "WPR recording is in progress...`nProfile : CPU.Verbose.Memory" }
        return "WPR recording is in progress...`nProfile : Perf2.Verbose.Memory`nCollector Name : Perf2 game markers"
    }
    if ($Remaining[0] -eq '-profiledetails') { return 'Perf2.Verbose.Memory profile validated' }
    if ($Remaining[0] -eq '-start') { $script:perf2FakeActive=$true; return 'WPR started' }
    if ($Remaining[0] -eq '-stop') {
        $script:perf2FakeStopCalls++
        if ($script:perf2FakeFailStop) { $global:LASTEXITCODE=5; return 'access denied fixture' }
        # Fake trace is only a file-system fixture, never a real ETW recording.
        [IO.File]::WriteAllText($Remaining[1], 'MOCK_ETL_ONLY_NOT_A_WINDOWS_TRACE')
        $script:perf2FakeActive=$false
        return 'WPR stopped'
    }
    throw 'Unexpected fake WPR arguments'
}
function Assert-Perf2Helper([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$perf2Invoke = @{Root=$perf2TestRoot;ProfilePath=(Join-Path $PSScriptRoot 'Perf2.wprp');GameReportPath=$perf2TestReport;WprPath='Fake-Perf2Wpr'}
$perf2Started = Invoke-Perf2Capture -Mode Start @perf2Invoke
Assert-Perf2Helper $perf2Started.success 'Start failed'
$perf2Duplicate = Invoke-Perf2Capture -Mode Start @perf2Invoke
Assert-Perf2Helper ($perf2Duplicate.session_directory -eq $perf2Started.session_directory) 'Duplicate start changed active session'
$perf2Stopped = Invoke-Perf2Capture -Mode Stop @perf2Invoke
Assert-Perf2Helper (Test-Path -LiteralPath (Join-Path $perf2Stopped.session_directory 'windows.etl')) 'ETL path absent'
Assert-Perf2Helper (Test-Path -LiteralPath (Join-Path $perf2Stopped.session_directory 'manifest.json')) 'manifest absent'
Assert-Perf2Helper (Test-Path -LiteralPath (Join-Path $perf2Stopped.session_directory 'latest.json')) 'game report absent'
Assert-Perf2Helper (-not (Test-Path -LiteralPath (Join-Path $perf2TestRoot 'active_capture.json'))) 'State not archived'

# Stale ownership file must not block the next capture.
$perf2Stale = Join-Path $perf2TestRoot 'stale'; New-Item -ItemType Directory -Path $perf2Stale | Out-Null
Write-Perf2Json -Path (Join-Path $perf2TestRoot 'active_capture.json') -Value @{session_directory=$perf2Stale;started_utc=[DateTime]::UtcNow.ToString('o')}
$perf2Restart = Invoke-Perf2Capture -Mode Start @perf2Invoke
Assert-Perf2Helper (Test-Path -LiteralPath (Join-Path $perf2Stale 'manifest.json')) 'Stale capture diagnosis absent'
$script:perf2FakeFailStop=$true
$perf2Failed=$false
try { Invoke-Perf2Capture -Mode Stop @perf2Invoke | Out-Null } catch { $perf2Failed=$true }
Assert-Perf2Helper $perf2Failed 'Native failure silently ignored'
Assert-Perf2Helper (Test-Path -LiteralPath (Join-Path $perf2TestRoot 'active_capture.json')) 'Ownership lost after stop failure'
$script:perf2FakeFailStop=$false
$script:perf2FakeOther=$true
$perf2Refused=$false
$perf2CallsBefore=$script:perf2FakeStopCalls
try { Invoke-Perf2Capture -Mode Stop @perf2Invoke | Out-Null } catch { $perf2Refused=$true }
Assert-Perf2Helper ($perf2Refused -and $script:perf2FakeStopCalls -eq $perf2CallsBefore) 'Another recording was stopped'
$script:perf2FakeOther=$false
Invoke-Perf2Capture -Mode Stop @perf2Invoke | Out-Null
Write-Host 'PERF2_HELPER_VALIDATION PASS: detailed status, start/stop bundle, stale state, errors, other recording protection. Mock WPR only.'
