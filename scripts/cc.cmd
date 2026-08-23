@echo off
set "BEAMTRACE_NIF_CC_ARGS=%*"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0compile-nif-windows.ps1"
exit /b %ERRORLEVEL%
