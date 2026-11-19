@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0DGGS_Control_Center.ps1"
if errorlevel 1 (
  echo.
  echo The Control Center could not start. Review the error above.
  pause
)
