@echo off
echo PERF-2: iniciar captura de Windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows_capture.ps1" -Mode Start
if errorlevel 1 echo ERROR: la captura no se ha confirmado. Lee el mensaje y el registro indicados arriba.
echo.
pause
