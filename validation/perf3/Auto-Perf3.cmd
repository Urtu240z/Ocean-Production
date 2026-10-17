@echo off
echo PERF-3: IFFT, frecuencia efectiva y memoria/cache
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\perf2\windows_capture.ps1" -Mode Auto -HardwareCounters -HitchThresholdMs 50 -WarmupSeconds 5
if errorlevel 1 echo ERROR: Lee el motivo y la ruta del registro indicados arriba.
echo.
pause
