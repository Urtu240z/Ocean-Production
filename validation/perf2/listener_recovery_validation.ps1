$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_auto_capture.ps1')
$perf2TestRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf2-recovery-tests\' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $perf2TestRoot -Force | Out-Null
$perf2Exe = Join-Path $perf2TestRoot 'auto_capture_listener.exe'
$perf2Ready = Join-Path $perf2TestRoot 'listener_ready_test.json'
$perf2Cancel = Join-Path $perf2TestRoot 'listener.cancel'
[IO.File]::WriteAllText($perf2Ready,'{"ready":true,"listener_pid":4242}')
$script:perf2Candidate = [pscustomobject]@{ProcessId=4242;ExecutablePath=$perf2Exe;CommandLine=('"{0}" --ready "{1}" --cancel "{2}"' -f $perf2Exe,$perf2Ready,$perf2Cancel)}
function Get-CimInstance {param([string]$ClassName,[string]$Filter);return $script:perf2Candidate}
function Get-Process {param([int]$Id,[string]$ErrorAction);return $null}
Stop-Perf2PreviousListener -Root $perf2TestRoot -ListenerPath $perf2Exe
if (-not (Test-Path -LiteralPath $perf2Cancel)) {throw 'Owned listener was not cancelled'}
Remove-Item -LiteralPath $perf2Cancel
function Assert-Refused {
    $perf2Refused=$false
    try {Stop-Perf2PreviousListener -Root $perf2TestRoot -ListenerPath $perf2Exe} catch {$perf2Refused=$true}
    if (-not $perf2Refused -or (Test-Path -LiteralPath $perf2Cancel)) {throw 'Unsafe listener takeover'}
}
$script:perf2Candidate.ExecutablePath = Join-Path $perf2TestRoot 'other.exe'
Assert-Refused
$script:perf2Candidate.ExecutablePath = $perf2Exe
$script:perf2Candidate.CommandLine = 'auto_capture_listener.exe --ready "C:\outside\ready.json" --cancel "C:\outside\listener.cancel"'
Assert-Refused
$script:perf2Candidate.CommandLine = '"{0}" --ready "{1}" --cancel "{2}"' -f $perf2Exe,$perf2Ready,$perf2Cancel
$script:perf2Candidate.ProcessId = 4243
Assert-Refused
$script:perf2Candidate.ProcessId = 4242
function Get-Process {param([int]$Id,[string]$ErrorAction);$perf2Fake=[pscustomobject]@{};$perf2Fake | Add-Member ScriptMethod WaitForExit {param($Milliseconds);return $false};return $perf2Fake}
$perf2Refused=$false
try {Stop-Perf2PreviousListener -Root $perf2TestRoot -ListenerPath $perf2Exe} catch {$perf2Refused=$true}
if (-not $perf2Refused) {throw 'Started a new listener while the old one was still alive'}
Write-Host 'PERF2_RECOVERY PASS: cooperative cancellation; foreign paths/processes, wrong PID and non-exiting listener rejected. No Windows trace touched.'
