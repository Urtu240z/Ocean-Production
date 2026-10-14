function Stop-Perf2PreviousListener {
    param([string]$Root,[string]$ListenerPath)
    # Called with the launcher mutex held. Never kill a process or stop WPR.
    $perf2ExpectedExe = [IO.Path]::GetFullPath($ListenerPath)
    $perf2RootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($perf2Previous in @(Get-CimInstance Win32_Process -Filter "Name = 'auto_capture_listener.exe'")) {
        if (-not $perf2Previous.ExecutablePath -or -not $perf2Previous.CommandLine -or
            -not [string]::Equals($perf2Previous.ExecutablePath,$perf2ExpectedExe,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Hay otro escuchador activo (PID $($perf2Previous.ProcessId)) cuya propiedad no se puede verificar. No se ha cerrado."
        }
        $perf2ReadyMatch = [regex]::Match($perf2Previous.CommandLine,'--ready "([^"]+)"')
        $perf2CancelMatch = [regex]::Match($perf2Previous.CommandLine,'--cancel "([^"]+)"')
        if (-not $perf2ReadyMatch.Success -or -not $perf2CancelMatch.Success) { throw 'No se pueden verificar las rutas del escuchador anterior.' }
        $perf2OldReady = [IO.Path]::GetFullPath($perf2ReadyMatch.Groups[1].Value)
        $perf2OldCancel = [IO.Path]::GetFullPath($perf2CancelMatch.Groups[1].Value)
        if (-not $perf2OldReady.StartsWith($perf2RootPrefix,[StringComparison]::OrdinalIgnoreCase) -or
            -not $perf2OldCancel.StartsWith($perf2RootPrefix,[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $perf2OldReady) -ne (Split-Path $perf2OldCancel) -or -not (Test-Path -LiteralPath $perf2OldReady)) {
            throw 'Las rutas del escuchador anterior no pertenecen a esta captura.'
        }
        $perf2OldState = Get-Content -LiteralPath $perf2OldReady -Raw | ConvertFrom-Json
        if ($perf2OldState.listener_pid -ne $perf2Previous.ProcessId) { throw 'La identidad del escuchador anterior no coincide.' }
        Write-Host "Recuperando escuchador anterior PID $($perf2Previous.ProcessId); WPR se conserva."
        [IO.File]::WriteAllText($perf2OldCancel,'recover_previous_listener')
        $perf2PreviousProcess = Get-Process -Id $perf2Previous.ProcessId -ErrorAction SilentlyContinue
        if ($perf2PreviousProcess -and -not $perf2PreviousProcess.WaitForExit(5000)) { throw 'El escuchador anterior no se ha cerrado; no se iniciara otro.' }
    }
}

function Get-Perf2ListenerError {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw).Trim() }
    return 'Sin detalle del escuchador.'
}

function Invoke-Perf2AutoCapture {
    param([string]$Root,[string]$ProfilePath,[string]$GameReportPath,[string]$WprPath,[string]$ResultPath,
        [double]$HitchThresholdMs=50,[double]$WarmupSeconds=5,[int]$AutoTimeoutSeconds=600,
        [string]$ListenerPath='')
    $perf2MutexCreated = $false
    $perf2Mutex = [Threading.Mutex]::new($true,'Local\OceanProduction.Perf2.AutoCapture',[ref]$perf2MutexCreated)
    if (-not $perf2MutexCreated) { $perf2Mutex.Dispose();throw 'Ya hay un capturador automatico PERF-2 abierto.' }
    $perf2ListenerProcess = $null
    $perf2Cancel = ''
    try {
        if (-not $ListenerPath) {
            $ListenerPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\temp\perf2-tools\auto_capture_listener.exe'))
            Stop-Perf2PreviousListener -Root $Root -ListenerPath $ListenerPath
            $perf2Source = Join-Path $PSScriptRoot 'auto_capture_listener.cpp'
            if (-not (Test-Path -LiteralPath $ListenerPath) -or (Get-Item -LiteralPath $ListenerPath).LastWriteTimeUtc -lt (Get-Item -LiteralPath $perf2Source).LastWriteTimeUtc) {
                $ListenerPath = & (Join-Path $PSScriptRoot 'build_listener.ps1')
            }
        }
        $perf2Started = Invoke-Perf2Capture -Mode Start -Root $Root -ProfilePath $ProfilePath -GameReportPath $GameReportPath -WprPath $WprPath
        $perf2Directory = $perf2Started.session_directory
        $perf2Attempt = [Guid]::NewGuid().ToString('N')
        $perf2Ready = Join-Path $perf2Directory ('listener_ready_' + $perf2Attempt + '.json')
        $perf2TriggerPath = Join-Path $perf2Directory 'trigger.json'
        $perf2Cancel = Join-Path $perf2Directory ('listener_' + $perf2Attempt + '.cancel')
        $perf2ErrorPath = Join-Path $perf2Directory 'listener_error.log'
        foreach ($perf2LogName in @('listener.log','listener_error.log')) {
            $perf2OldLog = Join-Path $perf2Directory $perf2LogName
            if (Test-Path -LiteralPath $perf2OldLog) { Move-Item -LiteralPath $perf2OldLog -Destination (Join-Path $perf2Directory ($perf2Attempt + '_' + $perf2LogName)) }
        }
        $perf2ThresholdString = $HitchThresholdMs.ToString([Globalization.CultureInfo]::InvariantCulture)
        $perf2WarmupString = $WarmupSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
        $perf2Args = '--output "{0}" --ready "{1}" --cancel "{2}" --threshold-ms {3} --warmup-seconds {4} --timeout-seconds {5} --owner-pid {6}' -f $perf2TriggerPath,$perf2Ready,$perf2Cancel,$perf2ThresholdString,$perf2WarmupString,$AutoTimeoutSeconds,$PID
        $perf2ListenerProcess = Start-Process -FilePath $ListenerPath -WindowStyle Hidden -ArgumentList $perf2Args -PassThru -RedirectStandardOutput (Join-Path $perf2Directory 'listener.log') -RedirectStandardError (Join-Path $perf2Directory 'listener_error.log')
        # Windows PowerShell 5.1 must retain the handle to expose ExitCode reliably.
        $null = $perf2ListenerProcess.Handle
        $perf2ReadyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $perf2Ready)) {
            if ($perf2ListenerProcess.HasExited) { throw "El capturador no pudo armarse: $(Get-Perf2ListenerError $perf2ErrorPath). WPR sigue grabando; puedes usar Stop-Perf2.cmd. Registro: $perf2ErrorPath" }
            if ([DateTime]::UtcNow -ge $perf2ReadyDeadline) { throw "No se confirmo el capturador automatico. Usa Stop-Perf2.cmd. Carpeta: $perf2Directory" }
            Start-Sleep -Milliseconds 100
        }
        $perf2ReadyState = Get-Content -LiteralPath $perf2Ready -Raw | ConvertFrom-Json
        if (-not $perf2ReadyState.ready -or $perf2ReadyState.listener_pid -ne $perf2ListenerProcess.Id -or $perf2ListenerProcess.HasExited) { throw 'El escuchador no confirma una identidad activa valida.' }
        Write-Perf2Json -Path $ResultPath -Value @{
            success=$true;state='armed';session_directory=$perf2Directory;warnings=$perf2Started.warnings
            message="CAPTURA ARMADA: juega con esta ventana abierta. Guardado automatico desde $HitchThresholdMs ms, tras $WarmupSeconds s iniciales."
        }
        Write-Host "CAPTURA ARMADA: juega con esta ventana abierta. Umbral $HitchThresholdMs ms; margen inicial $WarmupSeconds s."
        while (-not $perf2ListenerProcess.WaitForExit(500)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root 'active_capture.json'))) {
                [IO.File]::WriteAllText($perf2Cancel,'manual_stop')
            }
        }
        if ($perf2ListenerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $perf2TriggerPath)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root 'active_capture.json'))) {
                return @{success=$true;message='Captura detenida manualmente. Comprueba el resultado de Stop-Perf2.cmd.';session_directory=$perf2Directory;warnings=@()}
            }
            throw "El capturador termino sin un disparador (codigo $($perf2ListenerProcess.ExitCode)). WPR sigue grabando: usa Stop-Perf2.cmd. Registro: $perf2Directory\listener_error.log"
        }
        $perf2Trigger = Get-Content -LiteralPath $perf2TriggerPath -Raw | ConvertFrom-Json
        if ($perf2Trigger.source -ne 'realtime_etw') { throw 'El disparador no corresponde a una captura en tiempo real.' }
        Write-Perf2Json -Path $ResultPath -Value @{
            success=$true;state='saving';session_directory=$perf2Directory;warnings=@()
            message="PARON DETECTADO: fotograma $($perf2Trigger.process_frame), $([Math]::Round($perf2Trigger.interval_us / 1000.0,2)) ms. Guardando Windows y contexto del juego."
        }
        Write-Host "PARON DETECTADO: fotograma $($perf2Trigger.process_frame). Guardando la captura."
        return Invoke-Perf2Capture -Mode Stop -Root $Root -ProfilePath $ProfilePath -GameReportPath $GameReportPath -WprPath $WprPath -Trigger $perf2Trigger
    } finally {
        if ($perf2ListenerProcess -and -not $perf2ListenerProcess.HasExited -and $perf2Cancel) {
            [IO.File]::WriteAllText($perf2Cancel,'launcher_finished')
            $perf2ListenerProcess.WaitForExit(5000) | Out-Null
        }
        $perf2Mutex.ReleaseMutex();$perf2Mutex.Dispose()
    }
}
