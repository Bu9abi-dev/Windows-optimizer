@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  )
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0StudentOpti.ps1" -Gui %*
if %errorlevel% neq 0 pause
exit /b %errorlevel%
