function Invoke-Perf2NativeWpr {
    param([string]$Executable, [string[]]$WprArguments)
    # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects. A blank
    # stderr line with ErrorActionPreference=Stop can throw before the actual
    # WPR error arrives, leaving an empty Exception.Message and no exit code.
    $perf2Command = Get-Command -Name $Executable -ErrorAction Stop
    $perf2PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $perf2NativeLines = @(& $perf2Command @WprArguments 2>&1)
        $perf2NativeExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $perf2PreviousPreference }
    $perf2NativeOutput = ($perf2NativeLines | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { [string]$_.Exception.Message }
        else { $_.ToString() }
    }) -join [Environment]::NewLine
    if ($perf2NativeExitCode -ne 0) { throw "WPR ha fallado (codigo $perf2NativeExitCode; $($WprArguments -join ' ')): $perf2NativeOutput" }
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
    param([string]$Directory, [object]$State, [string]$GameReportPath, [bool]$TraceAvailable, [string]$SnapshotDirectory = '')
    if (-not $SnapshotDirectory) { $SnapshotDirectory = Split-Path -Parent $GameReportPath }
    $perf2Report = $null
    $perf2Manifest = [ordered]@{
        started_utc=$State.started_utc; stopped_utc=[DateTime]::UtcNow.ToString('o')
        status=$(if ($TraceAvailable) {'saved'} else {'trace_missing'})
        trace=$(if ($TraceAvailable) {'windows.etl'} else {$null})
        game_report=$null; warnings=@()
    }
    if (Test-Path -LiteralPath $GameReportPath) {
        try {
            if ([IO.Path]::GetFullPath($GameReportPath) -ne [IO.Path]::GetFullPath((Join-Path $Directory 'latest.json'))) {
                Copy-Item -LiteralPath $GameReportPath -Destination (Join-Path $Directory 'latest.json')
            }
            $perf2Manifest.game_report = 'latest.json'
            $perf2Report = Get-Content -LiteralPath (Join-Path $Directory 'latest.json') -Raw | ConvertFrom-Json
            $perf2Manifest.process_id = $perf2Report.metadata.windows_correlation.process_id
            $perf2Manifest.fft_snapshots = @()
            foreach ($perf3File in $perf2Report.metadata.fft_snapshot_files) {
                if ($perf3File -notmatch ('^fft_' + $perf2Manifest.process_id + '_b[0-2]_p[01]_f[0-9]+\.bin$')) {
                    $perf2Manifest.warnings += 'Nombre de snapshot FFT no valido.'; continue
                }
                $perf3Source = Join-Path $SnapshotDirectory $perf3File
                if (Test-Path -LiteralPath $perf3Source) {
                    $perf3Target = Join-Path $Directory $perf3File
                    if ([IO.Path]::GetFullPath($perf3Source) -ne [IO.Path]::GetFullPath($perf3Target)) { Copy-Item -LiteralPath $perf3Source -Destination $perf3Target }
                    $perf2Manifest.fft_snapshots += $perf3File
                } else { $perf2Manifest.warnings += "Snapshot FFT ausente: $perf3File" }
            }
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
    $perf3ProfileCopy = Join-Path $Directory 'capture_profile.wprp'
    if (Test-Path -LiteralPath $perf3ProfileCopy) {
        $perf2Manifest.capture_profile = 'capture_profile.wprp'
        [xml]$perf3ProfileXml = [IO.File]::ReadAllText($perf3ProfileCopy)
        $perf2Manifest.hardware_counters_requested = @($perf3ProfileXml.SelectNodes('//HardwareCounter/Counters/Counter') | ForEach-Object {$_.Value})
        if ($perf2Manifest.hardware_counters_requested.Count) { $perf2Manifest.hardware_counter_status = 'requested_not_verified_in_etl' }
        else { $perf2Manifest.hardware_counter_status = 'not_requested' }
    }
    if (Test-Path -LiteralPath (Join-Path $Directory 'trigger.json')) {
        $perf2Manifest.trigger = Get-Content -LiteralPath (Join-Path $Directory 'trigger.json') -Raw | ConvertFrom-Json
        $perf2Manifest.trigger_report_status = 'unverified'
        if ($perf2Report -and (Test-Perf2TriggerReport -Report $perf2Report -Trigger $perf2Manifest.trigger)) {
            $perf2Manifest.trigger_report_status = 'matched_with_context'
        } else { $perf2Manifest.warnings += 'El JSON no confirma el fotograma disparador con 32 anteriores y 32 posteriores. Conserva tambien el informe final del juego.' }
    }
    Write-Perf2Json -Path (Join-Path $Directory 'manifest.json') -Value $perf2Manifest
    return $perf2Manifest
}

function Test-Perf2TriggerReport {
    param([object]$Report, [object]$Trigger)
    if ($Report.metadata.windows_correlation.process_id -ne $Trigger.process_id) { return $false }
    $perf2Seen = @{}
    foreach ($perf2Frame in $Report.perf2.frames) { $perf2Seen[[string]$perf2Frame.process_frame] = $true }
    foreach ($perf2Window in $Report.perf2.frame_hitch_windows) {
        foreach ($perf2Frame in $perf2Window.frames) { $perf2Seen[[string]$perf2Frame.process_frame] = $true }
    }
    for ($perf2Required = [long]$Trigger.process_frame - 32; $perf2Required -le [long]$Trigger.process_frame + 32; $perf2Required++) {
        if (-not $perf2Seen.ContainsKey([string]$perf2Required)) { return $false }
    }
    return $true
}

function Wait-Perf2TriggerReport {
    param([string]$Directory, [string]$GameReportPath, [object]$Trigger, [int]$TimeoutSeconds = 15)
    $perf2Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $perf2Text = [IO.File]::ReadAllText($GameReportPath)
            $perf2Parsed = $perf2Text | ConvertFrom-Json
            if (Test-Perf2TriggerReport -Report $perf2Parsed -Trigger $Trigger) {
                $perf2Frozen = Join-Path $Directory 'latest.json'
                [IO.File]::WriteAllText($perf2Frozen,$perf2Text,[Text.UTF8Encoding]::new($false))
                return $perf2Frozen
            }
        } catch { } # The game may currently be publishing its atomic report.
        if ([DateTime]::UtcNow -ge $perf2Deadline) { return $GameReportPath }
        Start-Sleep -Milliseconds 500
    } while ($true)
}

function Invoke-Perf2Capture {
    param([string]$Mode, [string]$Root, [string]$ProfilePath, [string]$GameReportPath, [string]$WprPath, [object]$Trigger = $null)
    $perf2StatePath = Join-Path $Root 'active_capture.json'
    $perf3SnapshotDirectory = Split-Path -Parent $GameReportPath
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
                    if ([IO.Path]::GetFullPath($perf2OldState.profile) -ne [IO.Path]::GetFullPath($ProfilePath)) {
                        throw 'PERF-2 ya graba con otro perfil. Guarda esa captura con Stop-Perf2.cmd antes de iniciar el perfil PERF-3.'
                    }
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
        Copy-Item -LiteralPath $ProfilePath -Destination (Join-Path $perf2Directory 'capture_profile.wprp')
        [xml]$perf3RequestedProfile = [IO.File]::ReadAllText($ProfilePath)
        $perf3RequestedCounters = @($perf3RequestedProfile.SelectNodes('//HardwareCounter/Counters/Counter') | ForEach-Object {$_.Value})
        if ($perf3RequestedCounters.Count) {
            $perf3Available = Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-pmcsources')
            [IO.File]::WriteAllText((Join-Path $perf2Directory 'hardware_sources.txt'),$perf3Available)
            foreach ($perf3Counter in $perf3RequestedCounters) {
                if ($perf3Available -notmatch ('(?m)^\s*\d+\s+' + [regex]::Escape($perf3Counter) + '\s+')) {
                    throw "Windows no anuncia el contador $perf3Counter. No se ha iniciado WPR. Registro: $perf2Directory\hardware_sources.txt"
                }
            }
        }
        $perf2State = @{session_directory=$perf2Directory;started_utc=[DateTime]::UtcNow.ToString('o');profile=$ProfilePath}
        # Persist ownership before starting so a failed state write cannot orphan a trace.
        Write-Perf2Json -Path $perf2StatePath -Value $perf2State
        try {
            $perf2StartOutput = Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-start', "$ProfilePath!Perf2")
        } catch {
            [IO.File]::WriteAllText((Join-Path $perf2Directory 'wpr_start_error.txt'),$_.ToString())
            throw
        }
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
        if ($Trigger) {
            Write-Perf2Json -Path (Join-Path $perf2Directory 'trigger.json') -Value $Trigger
            Write-Perf2Json -Path (Join-Path $perf2Directory 'trace_stop_requested.json') -Value @{
                utc=[DateTime]::UtcNow.ToString('o');qpc=[Diagnostics.Stopwatch]::GetTimestamp();qpc_frequency=[Diagnostics.Stopwatch]::Frequency
            }
        }
        Invoke-Perf2NativeWpr -Executable $WprPath -WprArguments @('-stop',$perf2Etl) | Out-Null
        if (-not (Test-Path -LiteralPath $perf2Etl) -or (Get-Item -LiteralPath $perf2Etl).Length -eq 0) { throw 'WPR no ha generado un windows.etl valido. El estado se conserva para diagnostico.' }
        Move-Item -LiteralPath $perf2StatePath -Destination (Join-Path $perf2Directory 'capture_state.json')
    }
    # Freeze the Windows trace first. Wait for post-context only after it is saved.
    if ($Trigger) { $GameReportPath = Wait-Perf2TriggerReport -Directory $perf2Directory -GameReportPath $GameReportPath -Trigger $Trigger }
    $perf2Manifest = Save-Perf2Bundle -Directory $perf2Directory -State $perf2State -GameReportPath $GameReportPath -TraceAvailable $true -SnapshotDirectory $perf3SnapshotDirectory
    return @{success=$true;message='CAPTURA GUARDADA: comparte windows.etl, latest.json y manifest.json de esta carpeta.';session_directory=$perf2Directory;warnings=$perf2Manifest.warnings}
}
