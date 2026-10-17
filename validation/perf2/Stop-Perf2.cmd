@echo off
echo PERF-2: guardar captura de Windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows_capture.ps1" -Mode Stop
if errorlevel 1 echo ERROR: revisa el mensaje y el registro indicados arriba antes de repetir la prueba.
echo.
pause
