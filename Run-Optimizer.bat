@echo off
setlocal EnableExtensions
title StudentOpti launcher
rem Work from this file's own folder, even after the UAC relaunch (which starts in System32).
cd /d "%~dp0"
set "OPTI_SELF=%~f0"
set "OPTI_ARGS=%*"
set "OPTI_LOG=%~dp0StudentOpti-launcher.log"

if not exist "%~dp0StudentOpti.ps1" goto :notExtracted
if not exist "%~dp0modules\Common.ps1" goto :notExtracted

net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo Requesting administrator rights...
rem Paths are passed through environment variables so spaces, brackets and apostrophes are safe.
if defined OPTI_ARGS (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:OPTI_SELF -ArgumentList $env:OPTI_ARGS -Verb RunAs"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:OPTI_SELF -Verb RunAs"
)
if %errorlevel% neq 0 (
    echo.
    echo Administrator rights were not granted, so StudentOpti cannot run.
    pause
)
exit /b

:elevated
rem Files downloaded from the internet are "blocked"; unblock them so PowerShell will load the modules.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:CD -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
echo [%date% %time%] Starting StudentOpti %OPTI_ARGS% > "%OPTI_LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StudentOpti.ps1" %*
set "OPTI_EXIT=%errorlevel%"
echo [%date% %time%] StudentOpti exited with code %OPTI_EXIT% >> "%OPTI_LOG%"
echo.
if not "%OPTI_EXIT%"=="0" echo StudentOpti stopped with an error (code %OPTI_EXIT%). Details: "%~dp0StudentOpti-last-run.log"
echo Press any key to close this window.
pause >nul
exit /b %OPTI_EXIT%

:notExtracted
echo.
echo StudentOpti files were not found next to this launcher.
echo Extract the whole ZIP first (right-click the ZIP, Extract All), then run
echo Run-Optimizer.bat from the extracted folder. Running it from inside the ZIP does not work.
echo.
pause
exit /b 1
