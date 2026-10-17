$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\perf2\windows_capture_core.ps1')
[xml]$perf3Normal=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Perf3.wprp'))
[xml]$perf3Sensors=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Perf3-Sensors.wprp'))
if($perf3Sensors.SelectNodes('//HardwareCounter | //HardwareCounterId').Count) {throw 'Sensors mode still requests PMU'}
if($perf3Normal.SelectNodes('//HardwareCounter/Counters/Counter').Count -ne 4) {throw 'Original PMU profile changed'}
foreach($perf3Query in @('//SystemProvider/Keywords/Keyword','//SystemProvider/Stacks/Stack','//SystemCollector/BufferSize','//SystemCollector/Buffers','//EventCollector/BufferSize','//EventCollector/Buffers')) {
    $perf3A=@($perf3Normal.SelectNodes($perf3Query) | ForEach-Object {$_.Value}) -join ','
    $perf3B=@($perf3Sensors.SelectNodes($perf3Query) | ForEach-Object {$_.Value}) -join ','
    if($perf3A -ne $perf3B) {throw "Sensor mode changed capture settings: $perf3Query"}
}
if($perf3Sensors.SelectSingleNode('//EventProvider').Name -ne $perf3Normal.SelectSingleNode('//EventProvider').Name -or $perf3Sensors.SelectSingleNode('//EventProvider').Level -ne $perf3Normal.SelectSingleNode('//EventProvider').Level) {throw 'Game marker provider changed'}
$perf3SensorRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\..\temp\perf3-sensor-tests\'+[Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $perf3SensorRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Perf3-Sensors.wprp') -Destination (Join-Path $perf3SensorRoot 'capture_profile.wprp')
$perf3Manifest=Save-Perf2Bundle -Directory $perf3SensorRoot -State @{started_utc=[DateTime]::UtcNow.ToString('o')} -GameReportPath (Join-Path $perf3SensorRoot 'absent.json') -TraceAvailable $false
if($perf3Manifest.hardware_counter_status -ne 'not_requested' -or $perf3Manifest.hardware_counters_requested.Count -ne 0) {throw 'Manifest misrepresents absent counters'}
$perf3ParsedTokens=$null;$perf3ParseErrors=$null
$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\perf2\windows_capture.ps1'),[ref]$perf3ParsedTokens,[ref]$perf3ParseErrors)
if($perf3ParseErrors.Count) {throw 'Launcher parser errors'}
Write-Host 'PERF3_SENSORS PASS: original PMU intact; sensor profile keeps scheduler, faults, markers and buffers; no PMU; honest manifest; launcher parses.'
