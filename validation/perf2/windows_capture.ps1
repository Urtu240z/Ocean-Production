[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Status','Validate')][string]$Mode = 'Status',
    [switch]$ElevatedChild,
    [string]$ResultPath = '',
    [string]$GameReportPath = ''
)
$ErrorActionPreference = 'Stop'
$perf2Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\temp\perf2-windows'))
$perf2Profile = Join-Path $PSScriptRoot 'Perf2.wprp'
$perf2Wpr = Join-Path $env:WINDIR 'system32\wpr.exe'
. (Join-Path $PSScriptRoot 'windows_capture_core.ps1')
if (-not $GameReportPath) { $GameReportPath = Join-Path $env:APPDATA 'Godot\app_userdata\Ocean Production\perf1\latest.json' }

if ($Mode -in @('Status','Validate')) {
    if ($Mode -eq 'Validate') { Invoke-Perf2NativeWpr -Executable $perf2Wpr -WprArguments @('-profiledetails', "$perf2Profile!Perf2") }
    else { Invoke-Perf2NativeWpr -Executable $perf2Wpr -WprArguments @('-status','profiles','collectors') }
    exit 0
}

New-Item -ItemType Directory -Path $perf2Root -Force | Out-Null
if (-not $ResultPath) { $ResultPath = Join-Path $perf2Root ('operation_' + $Mode.ToLowerInvariant() + '_' + [Guid]::NewGuid().ToString('N') + '.json') }
$ResultPath = [IO.Path]::GetFullPath($ResultPath)
if (-not $ResultPath.StartsWith($perf2Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'La ruta del resultado esta fuera de la carpeta de diagnostico.' }
$perf2Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$perf2Administrator = ([Security.Principal.WindowsPrincipal]::new($perf2Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $perf2Administrator -and -not $ElevatedChild) {
    Write-Host "PERF-2 $Mode : Windows solicitara permiso de administrador."
    try {
        # Preserve the calling user's report path across elevation.
        $perf2Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -ElevatedChild -ResultPath "{2}" -GameReportPath "{3}"' -f $PSCommandPath,$Mode,$ResultPath,$GameReportPath
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $perf2Arguments -PassThru -Wait | Out-Null
        if (-not (Test-Path -LiteralPath $ResultPath)) { throw 'La ventana elevada no dejo un resultado. Comprueba el permiso de Windows.' }
        $perf2Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
    } catch { $perf2Result = @{success=$false;message="No se pudo completar la elevacion: $($_.Exception.Message)";warnings=@()} }
    Write-Perf2Json -Path $ResultPath -Value $perf2Result
} else {
    $perf2Log = [IO.Path]::ChangeExtension($ResultPath,'log')
    $perf2TranscriptStarted = $false
    try {
        Start-Transcript -LiteralPath $perf2Log | Out-Null
        $perf2TranscriptStarted = $true
        if (-not $perf2Administrator) { throw 'La operacion requiere permisos de administrador de Windows.' }
        $perf2Result = Invoke-Perf2Capture -Mode $Mode -Root $perf2Root -ProfilePath $perf2Profile -GameReportPath $GameReportPath -WprPath $perf2Wpr
    } catch { $perf2Result = @{success=$false;message=$_.Exception.Message;warnings=@()} }
    finally { if ($perf2TranscriptStarted) { Stop-Transcript | Out-Null } }
    $perf2Result.log_path = $perf2Log
    Write-Perf2Json -Path $ResultPath -Value $perf2Result
}

if ($perf2Result.success) { Write-Host $perf2Result.message -ForegroundColor Green }
else { Write-Host ('ERROR: ' + $perf2Result.message) -ForegroundColor Red }
if ($perf2Result.session_directory) { Write-Host ('Carpeta: ' + $perf2Result.session_directory) }
foreach ($perf2Warning in $perf2Result.warnings) { Write-Host ('AVISO: ' + $perf2Warning) -ForegroundColor Yellow }
if ($perf2Result.log_path) { Write-Host ('Registro: ' + $perf2Result.log_path) }
Write-Host ('Resultado: ' + $ResultPath)
if ($perf2Result.success) { exit 0 } else { exit 1 }
