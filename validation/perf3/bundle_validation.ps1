$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\perf2\windows_capture_core.ps1')
$perf3TestRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf3-bundle-tests\' + [Guid]::NewGuid().ToString('N'))))
$perf3SourceDir = Join-Path $perf3TestRoot 'game'
$perf3BundleDir = Join-Path $perf3TestRoot 'capture'
New-Item -ItemType Directory -Path $perf3SourceDir,$perf3BundleDir -Force | Out-Null
$perf3File = 'fft_1234_b0_p0_f100.bin'
[IO.File]::WriteAllText((Join-Path $perf3SourceDir $perf3File),'TEST_BLOB_NOT_A_REAL_IFFT')
$perf3Game = @{metadata=@{capture='PERF-2';scene='res://test';windows_correlation=@{process_id=1234};fft_snapshot_files=@($perf3File,'../outside.bin')};saved_utc=[DateTime]::UtcNow.ToString('o')}
$perf3Frozen = Join-Path $perf3BundleDir 'latest.json'
Write-Perf2Json -Path $perf3Frozen -Value $perf3Game
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Perf3.wprp') -Destination (Join-Path $perf3BundleDir 'capture_profile.wprp')
$perf3Manifest = Save-Perf2Bundle -Directory $perf3BundleDir -State @{started_utc=[DateTime]::UtcNow.AddSeconds(-10).ToString('o')} -GameReportPath $perf3Frozen -TraceAvailable $true -SnapshotDirectory $perf3SourceDir
if ($perf3Manifest.fft_snapshots.Count -ne 1 -or $perf3Manifest.hardware_counters_requested.Count -ne 4 -or $perf3Manifest.warnings.Count -ne 1) {throw 'Bundle metadata failed'}
if ([IO.File]::ReadAllText((Join-Path $perf3BundleDir $perf3File)) -ne 'TEST_BLOB_NOT_A_REAL_IFFT') {throw 'Snapshot was not copied from original source after JSON freeze'}
$script:perf3FakeStartCount = 0
function Fake-Perf3Wpr {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
    $global:LASTEXITCODE=0
    switch ($Remaining[0]) {
        '-status' {return 'WPR is not recording'}
        '-profiledetails' {return 'mock'}
        '-pmcsources' {return '33 InstructionsRetiredFixed 65536 4096 999999'}
        '-start' {$script:perf3FakeStartCount++;return 'mock'}
    }
    throw 'Unexpected WPR operation'
}
$perf3Refused=$false
try { Invoke-Perf2Capture -Mode Start -Root $perf3TestRoot -ProfilePath (Join-Path $PSScriptRoot 'Perf3.wprp') -GameReportPath $perf3Frozen -WprPath 'Fake-Perf3Wpr' | Out-Null } catch { $perf3Refused=$true }
if (-not $perf3Refused -or $script:perf3FakeStartCount -ne 0) {throw 'Missing hardware counter silently accepted'}
Write-Host 'PERF3_BUNDLE PASS: binary copy after JSON freeze, path validation, requested counters, unavailable-counter preflight. No real ETW session.'
