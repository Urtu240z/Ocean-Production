@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows_capture.ps1" -Mode Start
pause
