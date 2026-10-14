@echo off
echo PERF-2: captura automatica por paron
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows_capture.ps1" -Mode Auto -HitchThresholdMs 50 -WarmupSeconds 5
if errorlevel 1 echo ERROR: Lee el motivo y la ruta del registro indicados arriba.
echo.
pause
