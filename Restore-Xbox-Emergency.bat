@echo off
setlocal EnableExtensions
title StudentOpti - Emergency Xbox Restore
:: Standalone Xbox recovery. Works without the StudentOpti app (only Windows built-ins).
:: Puts Xbox services back to Manual (Windows default), starts them, re-registers the Xbox
:: apps, turns Game Bar capture back on, and suppresses ms-gamingoverlay popups if Game Bar is gone.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [1/5] Resetting Xbox services to Manual (start= demand)...
for %%S in (XblAuthManager XblGameSave XboxNetApiSvc XboxGipSvc GamingServicesNet) do (
    sc.exe config %%S start= demand >nul 2>&1 && echo     %%S = Manual || echo     %%S not installed
)
reg add "HKLM\SYSTEM\CurrentControlSet\Services\BcastDVRUserService" /v Start /t REG_DWORD /d 3 /f >nul 2>&1
for /f "delims=" %%K in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services" /k /f "BcastDVRUserService_" 2^>nul ^| findstr /i /c:"BcastDVRUserService_"') do (
    reg add "%%K" /v Start /t REG_DWORD /d 3 /f >nul 2>&1
)
sc.exe config GamingServices start= auto >nul 2>&1

echo [2/5] Starting Xbox Live Auth, Game Save and Gaming Services...
for %%S in (XblAuthManager XblGameSave GamingServices) do (
    net start %%S >nul 2>&1 && echo     %%S started || echo     %%S already running or not installed
)

echo [3/5] Re-registering Xbox app packages...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*Xbox*' -or $_.Name -like 'Microsoft.Gaming*' } | ForEach-Object { $m = Join-Path $_.InstallLocation 'AppXManifest.xml'; if (Test-Path $m) { try { Add-AppxPackage -DisableDevelopmentMode -Register $m -ErrorAction Stop; Write-Host ('    re-registered ' + $_.Name) } catch { Write-Host ('    skipped ' + $_.Name) } } }"

echo [4/5] Restoring Game Bar / GameDVR settings...
powershell -NoProfile -Command "if (Get-AppxPackage -Name Microsoft.XboxGamingOverlay) { exit 0 } else { exit 1 }"
if %errorlevel% equ 0 (
    reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 1 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 1 /f >nul
    reg delete "HKCU\Software\Classes\ms-gamingoverlay" /f >nul 2>&1
    echo     Game Bar found, capture re-enabled.
) else (
    reg add "HKCU\Software\Classes\ms-gamingoverlay" /ve /d "URL:ms-gamingoverlay" /f >nul
    reg add "HKCU\Software\Classes\ms-gamingoverlay" /v "URL Protocol" /d "" /f >nul
    reg add "HKCU\Software\Classes\ms-gamingoverlay\shell\open\command" /ve /d "\"%SystemRoot%\System32\systray.exe\"" /f >nul
    echo     Game Bar is not installed: ms-gamingoverlay popups suppressed.
    echo     Reinstall it from the Microsoft Store ^(Xbox Game Bar^) or StudentOpti Deep Repair.
)
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /f >nul 2>&1

echo [5/5] Checking result...
for %%S in (XblAuthManager XblGameSave XboxNetApiSvc XboxGipSvc) do (
    sc.exe qc %%S 2>nul | findstr /i "START_TYPE"
)
echo.
echo Done. If Xbox apps are still missing, run StudentOpti and use "Deep Repair & Reinstall Xbox Stack",
echo or install "Xbox" and "Gaming Services" from the Microsoft Store.
pause
endlocal
