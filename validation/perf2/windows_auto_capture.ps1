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
            $perf2Source = Join-Path $PSScriptRoot 'auto_capture_listener.cpp'
            if (-not (Test-Path -LiteralPath $ListenerPath) -or (Get-Item -LiteralPath $ListenerPath).LastWriteTimeUtc -lt (Get-Item -LiteralPath $perf2Source).LastWriteTimeUtc) {
                $ListenerPath = & (Join-Path $PSScriptRoot 'build_listener.ps1')
            }
        }
        $perf2Started = Invoke-Perf2Capture -Mode Start -Root $Root -ProfilePath $ProfilePath -GameReportPath $GameReportPath -WprPath $WprPath
        $perf2Directory = $perf2Started.session_directory
        $perf2Ready = Join-Path $perf2Directory ('listener_ready_' + [Guid]::NewGuid().ToString('N') + '.json')
        $perf2TriggerPath = Join-Path $perf2Directory 'trigger.json'
        $perf2Cancel = Join-Path $perf2Directory 'listener.cancel'
        $perf2ThresholdString = $HitchThresholdMs.ToString([Globalization.CultureInfo]::InvariantCulture)
        $perf2WarmupString = $WarmupSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
        $perf2Args = '--output "{0}" --ready "{1}" --cancel "{2}" --threshold-ms {3} --warmup-seconds {4} --timeout-seconds {5}' -f $perf2TriggerPath,$perf2Ready,$perf2Cancel,$perf2ThresholdString,$perf2WarmupString,$AutoTimeoutSeconds
        $perf2ListenerProcess = Start-Process -FilePath $ListenerPath -WindowStyle Hidden -ArgumentList $perf2Args -PassThru -RedirectStandardOutput (Join-Path $perf2Directory 'listener.log') -RedirectStandardError (Join-Path $perf2Directory 'listener_error.log')
        # Windows PowerShell 5.1 must retain the handle to expose ExitCode reliably.
        $null = $perf2ListenerProcess.Handle
        $perf2ReadyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $perf2Ready)) {
            if ($perf2ListenerProcess.HasExited) { throw "El capturador no pudo armarse. WPR sigue grabando; puedes usar Stop-Perf2.cmd. Lee listener_error.log en $perf2Directory" }
            if ([DateTime]::UtcNow -ge $perf2ReadyDeadline) { throw "No se confirmo el capturador automatico. Usa Stop-Perf2.cmd. Carpeta: $perf2Directory" }
            Start-Sleep -Milliseconds 100
        }
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
