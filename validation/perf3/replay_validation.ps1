$ErrorActionPreference = 'Stop'
$perf3Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$perf3Exe = Join-Path $perf3Root 'temp\perf3-tools\fft_replay.exe'
$perf3Fixture = Join-Path $perf3Root 'temp\perf3-fixture'
# Generate the fixture with snapshot_validation.gd before this script.
foreach ($perf3Band in 0..2) {
    $perf3Input = Join-Path $perf3Fixture "band_$perf3Band.bin"
    $perf3Report = Join-Path $perf3Fixture "replay_$perf3Band.json"
    & $perf3Exe $perf3Input $perf3Report 100 | Out-Null
    if ($LASTEXITCODE -ne 0) {throw "Replay failed for band $perf3Band"}
    $perf3Result = Get-Content -LiteralPath $perf3Report -Raw | ConvertFrom-Json
    if (-not $perf3Result.runs[0].bit_exact -or $perf3Result.runs[0].max_abs_error -ne 0) {throw 'Captured output is not bit exact'}
}
$perf3Corrupt = Join-Path $perf3Fixture 'corrupt_offset.bin'
$perf3Bytes = [IO.File]::ReadAllBytes((Join-Path $perf3Fixture 'band_0.bin'))
$perf3N = [BitConverter]::ToUInt32($perf3Bytes,8)
$perf3OffsetStart = 96 + 4*$perf3N + 48*($perf3N-1)
[Array]::Copy([BitConverter]::GetBytes([UInt64]::MaxValue),0,$perf3Bytes,$perf3OffsetStart,8)
[IO.File]::WriteAllBytes($perf3Corrupt,$perf3Bytes)
$perf3OriginalErrorAction = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue' # Expected native stderr on the malformed fixture.
    & $perf3Exe $perf3Corrupt (Join-Path $perf3Fixture 'invalid.json') 1 2> (Join-Path $perf3Fixture 'invalid.log')
} finally { $ErrorActionPreference = $perf3OriginalErrorAction }
if ($LASTEXITCODE -eq 0) {throw 'Invalid overflowing offset accepted'}
Write-Host 'PERF3_REPLAY PASS: three captured matrices match bit for bit; malformed offset rejected.'
