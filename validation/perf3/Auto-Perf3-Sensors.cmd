@echo off
echo PERF-3 + HWiNFO: captura de sensores, etapas y planificador
echo Este modo no solicita contadores PMU. Conserva las capturas IFFT del juego.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\perf2\windows_capture.ps1" -Mode Auto -SensorCompanion -HitchThresholdMs 50 -WarmupSeconds 5
if errorlevel 1 echo ERROR: Lee el motivo y la ruta del registro indicados arriba.
echo.
pause
