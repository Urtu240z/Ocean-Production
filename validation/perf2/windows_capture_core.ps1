function Invoke-Perf2NativeWpr {
    param([string]$Executable, [string[]]$WprArguments)
    $perf2NativeOutput = & $Executable @WprArguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "WPR ha fallado (codigo $LASTEXITCODE): $perf2NativeOutput" }
    return $perf2NativeOutput
}

function Write-Perf2Json {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Get-Perf2SessionDirectory {
    param([string]$Root, [object]$State)
    $perf2Directory = [IO.Path]::GetFullPath($State.session_directory)
    if (-not $perf2Directory.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'La ruta de la sesion esta fuera de la carpeta de capturas.'
    }
    return $perf2Directory
}

function Test-Perf2OwnedRecording {
    param([string]$Status)
    $perf2Profiles = [regex]::Matches($Status, '(?im)^\s*Profile\s*:\s*(\S+)')
    return $perf2Profiles.Count -eq 1 -and $perf2Profiles[0].Groups[1].Value -eq 'Perf2.Verbose.Memory'
}

function Save-Perf2Bundle {
    param([string]$Directory, [object]$State, [string]$GameReportPath, [bool]$TraceAvailable)
    $perf2Manifest = [ordered]@{
        started_utc=$State.started_utc; stopped_utc=[DateTime]::UtcNow.ToString('o')
        status=$(if ($TraceAvailable) {'saved'} else {'trace_missing'})
        trace=$(if ($TraceAvailable) {'windows.etl'} else {$null})
        game_report=$null; warnings=@()
    }
    if (Test-Path -LiteralPath $GameReportPath) {
        try {
            Copy-Item -LiteralPath $GameReportPath -Destination (Join-Path $Directory 'latest.json')
            $perf2Manifest.game_report = 'latest.json'
            $perf2Report = Get-Content -LiteralPath (Join-Path $Directory 'latest.json') -Raw | ConvertFrom-Json
            $perf2Manifest.process_id = $perf2Report.metadata.windows_correlation.process_id
            if ($perf2Report.metadata.capture -ne 'PERF-2') { $perf2Manifest.warnings += 'Informe antiguo: reiniciar Godot para cargar la DLL PERF-2.' }
            if (-not $perf2Report.metadata.scene) { $perf2Manifest.warnings += 'El JSON no identifica la escena del juego.' }
            $perf2Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            $perf2Saved = [DateTime]::Parse($perf2Report.saved_utc, [Globalization.CultureInfo]::InvariantCulture, $perf2Styles)
            if ($perf2Saved -lt [DateTime]::Parse($State.started_utc).ToUniversalTime()) {
                $perf2Manifest.warnings += 'El JSON es anterior a la captura Windows.'
            }
        } catch { $perf2Manifest.warnings += "No se pudo validar el JSON: $($_.Exception.Message)" }
    } else { $perf2Manifest.warnings += "No se encontro el informe del juego: $GameReportPath" }
    if (-not $TraceAvailable) { $perf2Manifest.warnings += 'Windows no tiene una traza activa ni un ETL guardado. Es necesario iniciar una captura nueva.' }
    Write-Perf2Json -Path (Join-Path $Directory 'manifest.json') -Value $perf2Manifest
    return $perf2Manifest
}

function Invoke-Perf2Capture {
    param([string]$Mode, [string]$Root, [string]$ProfilePath, [string]$GameReportPath, [string]$WprPath)
    $perf2StatePath = Join-Path $Root 'active_capture.json'
    # Plain -status omits profile names. Request profiles on both start and stop.
    $perf2Status = Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-status','profiles','collectors')
    $perf2Inactive = $perf2Status -match 'WPR is not recording'
    $perf2Warnings = @()
    if ($Mode -eq 'Start') {
        if (Test-Path -LiteralPath $perf2StatePath) {
            $perf2OldState = Get-Content -LiteralPath $perf2StatePath -Raw | ConvertFrom-Json
            $perf2OldDirectory = Get-Perf2SessionDirectory -Root $Root -State $perf2OldState
            if (-not $perf2Inactive) {
                if (Test-Perf2OwnedRecording -Status $perf2Status) {
                    return @{success=$true;message='CAPTURA ACTIVA: PERF-2 ya estaba grabando. Puedes jugar y usar Stop-Perf2.cmd.';session_directory=$perf2OldDirectory;warnings=@()}
                }
                throw "Hay otra captura WPR activa o su perfil es desconocido. No la modifico. $perf2Status"
            }
            New-Item -ItemType Directory -Path $perf2OldDirectory -Force | Out-Null
            $perf2OldTrace = Test-Path -LiteralPath (Join-Path $perf2OldDirectory 'windows.etl')
            Save-Perf2Bundle -Directory $perf2OldDirectory -State $perf2OldState -GameReportPath $GameReportPath -TraceAvailable $perf2OldTrace | Out-Null
            Move-Item -LiteralPath $perf2StatePath -Destination (Join-Path $perf2OldDirectory ('inactive_state_' + [Guid]::NewGuid().ToString('N') + '.json'))
            $perf2Warnings += 'Se ha archivado el estado anterior porque Windows ya no estaba grabando.'
        }
        if (-not $perf2Inactive) { throw "WPR tiene otra captura activa o un estado desconocido. No inicio otra: $perf2Status" }
        Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-profiledetails', "$ProfilePath!Perf2") | Out-Null
        $perf2Directory = Join-Path $Root ('capture_' + [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff'))
        New-Item -ItemType Directory -Path $perf2Directory | Out-Null
        $perf2State = @{session_directory=$perf2Directory;started_utc=[DateTime]::UtcNow.ToString('o');profile=$ProfilePath}
        # Persist ownership before starting so a failed state write cannot orphan a trace.
        Write-Perf2Json -Path $perf2StatePath -Value $perf2State
        $perf2StartOutput = Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-start', "$ProfilePath!Perf2")
        $perf2Verified = Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-status','profiles','collectors')
        [IO.File]::WriteAllText((Join-Path $perf2Directory 'wpr_status_after_start.txt'), $perf2Verified)
        if (-not (Test-Perf2OwnedRecording -Status $perf2Verified)) {
            throw "WPR no confirma el perfil PERF-2 activo. Estado conservado para diagnostico. $perf2StartOutput $perf2Verified"
        }
        return @{success=$true;message='CAPTURA ACTIVA: juega hasta el paron, detiene el juego y ejecuta Stop-Perf2.cmd.';session_directory=$perf2Directory;warnings=$perf2Warnings;wpr_status=$perf2Verified}
    }
    if (-not (Test-Path -LiteralPath $perf2StatePath)) { throw 'No hay una captura PERF-2 iniciada por este ayudante. Ejecuta Start-Perf2.cmd primero.' }
    $perf2State = Get-Content -LiteralPath $perf2StatePath -Raw | ConvertFrom-Json
    $perf2Directory = Get-Perf2SessionDirectory -Root $Root -State $perf2State
    $perf2Etl = Join-Path $perf2Directory 'windows.etl'
    if ($perf2Inactive) {
        $perf2TraceAvailable = Test-Path -LiteralPath $perf2Etl
        Save-Perf2Bundle -Directory $perf2Directory -State $perf2State -GameReportPath $GameReportPath -TraceAvailable $perf2TraceAvailable | Out-Null
        Move-Item -LiteralPath $perf2StatePath -Destination (Join-Path $perf2Directory ('inactive_state_' + [Guid]::NewGuid().ToString('N') + '.json'))
        if (-not $perf2TraceAvailable) { throw "Windows ya no estaba grabando. No se puede recuperar windows.etl. He conservado el estado y manifest.json en $perf2Directory. Ejecuta Start-Perf2.cmd de nuevo." }
    } else {
        if (-not (Test-Perf2OwnedRecording -Status $perf2Status)) { throw "La captura activa contiene otros perfiles o no se identifica como PERF-2. No la detengo: $perf2Status" }
        [IO.File]::WriteAllText((Join-Path $perf2Directory 'wpr_status_before_stop.txt'), $perf2Status)
        Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-stop',$perf2Etl) | Out-Null
        if (-not (Test-Path -LiteralPath $perf2Etl) -or (Get-Item -LiteralPath $perf2Etl).Length -eq 0) { throw 'WPR no ha generado un windows.etl valido. El estado se conserva para diagnostico.' }
        Move-Item -LiteralPath $perf2StatePath -Destination (Join-Path $perf2Directory 'capture_state.json')
    }
    $perf2Manifest = Save-Perf2Bundle -Directory $perf2Directory -State $perf2State -GameReportPath $GameReportPath -TraceAvailable $true
    return @{success=$true;message='CAPTURA GUARDADA: comparte windows.etl, latest.json y manifest.json de esta carpeta.';session_directory=$perf2Directory;warnings=$perf2Manifest.warnings}
}
