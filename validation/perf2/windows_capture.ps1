[CmdletBinding()]
param([ValidateSet('Start','Stop','Status','Validate')][string]$Mode = 'Status')
$ErrorActionPreference = 'Stop'
$perf2Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\temp\perf2-windows'))
$perf2Profile = Join-Path $PSScriptRoot 'Perf2.wprp'
$perf2StatePath = Join-Path $perf2Root 'active_capture.json'
$perf2Wpr = Join-Path $env:WINDIR 'system32\wpr.exe'

function Invoke-Perf2Wpr([string[]]$WprArguments) {
    $perf2Output = & $perf2Wpr @WprArguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "WPR: $perf2Output" }
    return $perf2Output
}

if ($Mode -in @('Status','Validate')) {
    if ($Mode -eq 'Validate') { Invoke-Perf2Wpr @('-profiledetails', "$perf2Profile!Perf2") }
    else { Invoke-Perf2Wpr @('-status') }
    exit 0
}

$perf2Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$perf2Administrator = ([Security.Principal.WindowsPrincipal]::new($perf2Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $perf2Administrator) {
    $perf2Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $PSCommandPath, $Mode
    $perf2Elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $perf2Arguments -PassThru -Wait
    exit $perf2Elevated.ExitCode
}

if ($Mode -eq 'Start') {
    if (Test-Path -LiteralPath $perf2StatePath) { throw 'Ya hay una captura PERF-2 pendiente. Usa Stop-Perf2.cmd.' }
    $perf2Status = Invoke-Perf2Wpr @('-status')
    if ($perf2Status -notmatch 'WPR is not recording') {
        throw "No inicio la captura porque hay otra sesion WPR o su estado es desconocido: $perf2Status"
    }
    Invoke-Perf2Wpr @('-profiledetails', "$perf2Profile!Perf2") | Out-Null
    New-Item -ItemType Directory -Path $perf2Root -Force | Out-Null
    $perf2Session = Join-Path $perf2Root ('capture_' + [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $perf2Session | Out-Null
    Invoke-Perf2Wpr @('-start', "$perf2Profile!Perf2")
    try {
        @{session_directory=$perf2Session; started_utc=[DateTime]::UtcNow.ToString('o'); profile=$perf2Profile} |
            ConvertTo-Json | Set-Content -LiteralPath $perf2StatePath -Encoding UTF8
    } catch {
        # This script just started this session. Save it rather than leaving WPR active.
        Invoke-Perf2Wpr @('-stop', (Join-Path $perf2Session 'recovery.etl')) | Out-Null
        throw
    }
    Write-Host 'Captura PERF-2 activa en memoria. Juega hasta el paron, detiene el juego y usa Stop-Perf2.cmd.'
    Write-Host 'Detenla poco despues del paron: los buffers de Windows son circulares.'
} else {
    if (-not (Test-Path -LiteralPath $perf2StatePath)) { throw 'No hay una captura PERF-2 iniciada por este ayudante. No detengo otras sesiones WPR.' }
    $perf2State = Get-Content -LiteralPath $perf2StatePath -Raw | ConvertFrom-Json
    $perf2Session = [IO.Path]::GetFullPath($perf2State.session_directory)
    if (-not $perf2Session.StartsWith($perf2Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'La ruta de la sesion esta fuera de la carpeta de capturas.'
    }
    $perf2Status = Invoke-Perf2Wpr @('-status')
    if ($perf2Status -notmatch 'Perf2') { throw 'La sesion WPR actual no se identifica como PERF-2. No la detengo.' }
    Invoke-Perf2Wpr @('-stop', (Join-Path $perf2Session 'windows.etl'))
    Move-Item -LiteralPath $perf2StatePath -Destination (Join-Path $perf2Session 'capture_state.json')
    $perf2Source = Join-Path $env:APPDATA 'Godot\app_userdata\Ocean Production\perf1\latest.json'
    $perf2Manifest = @{started_utc=$perf2State.started_utc; stopped_utc=[DateTime]::UtcNow.ToString('o'); trace='windows.etl'; game_report=$null; warnings=@()}
    if (Test-Path -LiteralPath $perf2Source) {
        Copy-Item -LiteralPath $perf2Source -Destination (Join-Path $perf2Session 'latest.json')
        $perf2Report = Get-Content -LiteralPath (Join-Path $perf2Session 'latest.json') -Raw | ConvertFrom-Json
        $perf2Manifest.game_report = 'latest.json'
        $perf2Manifest.process_id = $perf2Report.metadata.windows_correlation.process_id
        if ($perf2Report.metadata.capture -ne 'PERF-2') { $perf2Manifest.warnings += 'Informe antiguo: reiniciar Godot para cargar la DLL PERF-2.' }
        if (-not $perf2Report.metadata.scene) { $perf2Manifest.warnings += 'El JSON no identifica una escena; comprueba que corresponde a la prueba del jet ski.' }
        $perf2DateStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $perf2SavedUtc = [DateTime]::Parse($perf2Report.saved_utc, [Globalization.CultureInfo]::InvariantCulture, $perf2DateStyles)
        if ($perf2SavedUtc -lt [DateTime]::Parse($perf2State.started_utc).ToUniversalTime()) {
            $perf2Manifest.warnings += 'El JSON es anterior a la captura Windows.'
        }
    } else { $perf2Manifest.warnings += 'No se encontro latest.json; la traza Windows se ha conservado.' }
    $perf2Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $perf2Session 'manifest.json') -Encoding UTF8
    Write-Host "Captura guardada: $perf2Session"
    foreach ($perf2Warning in $perf2Manifest.warnings) { Write-Warning $perf2Warning }
    Write-Host 'Comparte windows.etl, latest.json y manifest.json de esa misma carpeta.'
}
