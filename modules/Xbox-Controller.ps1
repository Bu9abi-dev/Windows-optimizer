# Xbox-Controller.ps1
# Xbox / Gaming Services state machine with a three-tier fallback:
#   Tier 1  Save-XboxFallbackSnapshot  -> backups\xbox_fallback.json (+ xbox_fallback_original.json, written once)
#   Tier 2  Restore-XboxFallback       -> services back to Manual, start them, re-register Xbox Appx, GameDVR keys
#   Tier 3  Restore-XboxFallback -Deep -> Store services check, winget reinstall / Reset-AppxPackage
# Restore-Xbox-Emergency.bat in the repo root does Tier 2 without needing this module at all.

$script:XboxCoreServices = @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc')

# Used when services.json cannot be read. Mirrors the xbox_modes in services.json.
$script:XboxModeTableDefault = @{
    XblAuthManager      = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Disabled' }
    XblGameSave         = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Disabled' }
    XboxNetApiSvc       = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Disabled' }
    XboxGipSvc          = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Disabled' }
    GamingServices      = @{ Enabled = 'Automatic'; Lite = 'Automatic'; Disabled = 'Manual' }
    GamingServicesNet   = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Manual' }
    BcastDVRUserService = @{ Enabled = 'Manual';    Lite = 'Manual';    Disabled = 'Manual' }
}

$script:XboxRegistry = @{
    GameDVREnabled = @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' }
    FSEBehavior    = @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode' }
    AppCapture     = @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' }
    AllowGameDVR   = @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR' }
}

# Per-user stub that swallows "you'll need a new app to open this ms-gamingoverlay link" popups
# when Game Bar is not installed. Removed again whenever Game Bar is present and Xbox is enabled.
$script:XboxOverlayStubKey = 'HKCU:\Software\Classes\ms-gamingoverlay'

function Get-XboxModeTable {
    <#
    .SYNOPSIS
    Returns service -> @{Enabled;Lite;Disabled} from services.json, falling back to the built-in table.
    #>
    $table = @{}
    try {
        $cfg = Get-OptiConfig -Name services
        foreach ($s in @($cfg.services | Where-Object { $_.category -eq 'Xbox' -and $_.xbox_modes })) {
            $table[$s.service] = @{
                Enabled  = $s.xbox_modes.Enabled
                Lite     = $s.xbox_modes.Lite
                Disabled = $s.xbox_modes.Disabled
            }
        }
    } catch { }
    if ($table.Count -eq 0) { return $script:XboxModeTableDefault }
    return $table
}

function Get-XboxPackageList {
    <#
    .SYNOPSIS
    Returns the Xbox package definitions (name, pattern, store_id) from appx_bloat.json.
    #>
    try {
        $cfg = Get-OptiConfig -Name appx_bloat
        if ($cfg.xbox) { return @($cfg.xbox) }
    } catch { }
    return @(
        [pscustomobject]@{ name = 'Xbox app';              pattern = 'Microsoft.GamingApp';            store_id = '9MV0B5HZVK9Z' }
        [pscustomobject]@{ name = 'Xbox Game Bar';         pattern = 'Microsoft.XboxGamingOverlay';    store_id = '9NZKPSTSNW4P' }
        [pscustomobject]@{ name = 'Xbox Identity Provider'; pattern = 'Microsoft.XboxIdentityProvider'; store_id = '9WZDNCRD1HKW' }
        [pscustomobject]@{ name = 'Gaming Services';       pattern = 'Microsoft.GamingServices';       store_id = '9MWPM2CQNLHN' }
    )
}

function Get-XboxStatus {
    <#
    .SYNOPSIS
    Live status of the Xbox services, Xbox packages and GameDVR keys, plus the mode they currently match.
    #>
    [CmdletBinding()]
    param()

    $items = New-Object System.Collections.Generic.List[object]
    $table = Get-XboxModeTable
    foreach ($name in $table.Keys | Sort-Object) {
        $startup = Get-OptiServiceStartup -Name $name
        $status = 'NotInstalled'
        if ($startup -ne 'NotInstalled') {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $svc) {
                # Per-user services only exist as <Name>_<luid> instances while a user is signed in.
                $svc = Get-Service -Name "$($name)_*" -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($svc) { $status = [string]$svc.Status } else { $status = 'Stopped' }
        }
        $items.Add([pscustomobject]@{
            Kind        = 'Service'
            Name        = $name
            StartupType = $startup
            Status      = $status
            Installed   = ($startup -ne 'NotInstalled')
        })
    }

    $appxAvailable = [bool](Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)
    foreach ($pkg in Get-XboxPackageList) {
        $found = $null
        if ($appxAvailable) {
            $found = Get-AppxPackage -Name $pkg.pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        $items.Add([pscustomobject]@{
            Kind        = 'Package'
            Name        = $pkg.pattern
            DisplayName = $pkg.name
            StartupType = $null
            Status      = $(if ($found) { 'Installed' } else { 'Missing' })
            Installed   = [bool]$found
            Version     = $(if ($found) { [string]$found.Version } else { $null })
        })
    }

    foreach ($key in $script:XboxRegistry.Keys | Sort-Object) {
        $r = $script:XboxRegistry[$key]
        $items.Add([pscustomobject]@{
            Kind        = 'Registry'
            Name        = $key
            StartupType = $null
            Status      = Get-OptiRegistry -Path $r.Path -Name $r.Name
            Installed   = $true
        })
    }
    return $items
}

function Get-XboxCurrentMode {
    <#
    .SYNOPSIS
    Returns 'Enabled', 'Lite', 'Disabled' or 'Custom' based on the core services and the capture keys.
    #>
    $starts = @($script:XboxCoreServices | ForEach-Object { Get-OptiServiceStartup -Name $_ } | Where-Object { $_ -ne 'NotInstalled' })
    if ($starts.Count -eq 0) { return 'Custom' }
    if (@($starts | Where-Object { $_ -eq 'Disabled' }).Count -eq $starts.Count) { return 'Disabled' }
    if (@($starts | Where-Object { $_ -eq 'Disabled' }).Count -gt 0) { return 'Custom' }
    $capture = Get-OptiRegistry -Path $script:XboxRegistry.AppCapture.Path -Name $script:XboxRegistry.AppCapture.Name
    if ($capture -eq 0) { return 'Lite' }
    return 'Enabled'
}

function Save-XboxFallbackSnapshot {
    <#
    .SYNOPSIS
    Tier 1: writes the exact Start/DelayedAutostart DWORDs and GameDVR keys to backups\xbox_fallback.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Reason = 'manual')

    $services = @()
    foreach ($name in (Get-XboxModeTable).Keys | Sort-Object) {
        $keys = @("HKLM:\SYSTEM\CurrentControlSet\Services\$name")
        if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services') {
            $keys += @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like "$($name)_*" } |
                ForEach-Object { "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.PSChildName)" })
        }
        foreach ($k in $keys) {
            $services += [pscustomobject]@{
                Service          = Split-Path $k -Leaf
                Key              = $k
                Start            = Get-OptiRegistry -Path $k -Name 'Start'
                DelayedAutostart = Get-OptiRegistry -Path $k -Name 'DelayedAutostart'
            }
        }
    }
    $registry = @()
    foreach ($key in $script:XboxRegistry.Keys | Sort-Object) {
        $r = $script:XboxRegistry[$key]
        $registry += [pscustomobject]@{ Path = $r.Path; Name = $r.Name; Value = (Get-OptiRegistry -Path $r.Path -Name $r.Name) }
    }
    $snapshot = [pscustomobject]@{
        CreatedAt = (Get-Date).ToString('o')
        Reason    = $Reason
        Mode      = Get-XboxCurrentMode
        Services  = $services
        Registry  = $registry
    }

    $dir = Get-OptiBackupDir
    $json = $snapshot | ConvertTo-Json -Depth 5
    $latest = Join-Path $dir 'xbox_fallback.json'
    $original = Join-Path $dir 'xbox_fallback_original.json'
    # Written with .NET so the snapshot exists even during a dry run: it is a read of current state.
    [IO.File]::WriteAllText($latest, $json)
    if (-not (Test-Path $original)) { [IO.File]::WriteAllText($original, $json) }
    Write-OptiLog -Message "Xbox fallback snapshot saved to $latest" -Level Info
    return $latest
}

function Set-XboxGameDVR {
    <#
    .SYNOPSIS
    Sets the GameDVR / Game Bar capture keys for a mode.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Enabled', 'Lite', 'Disabled')][string]$Mode)

    $r = $script:XboxRegistry
    switch ($Mode) {
        'Disabled' {
            Set-OptiRegistry -Path $r.GameDVREnabled.Path -Name $r.GameDVREnabled.Name -Value 0 -Type DWord
            Set-OptiRegistry -Path $r.AppCapture.Path -Name $r.AppCapture.Name -Value 0 -Type DWord
            Set-OptiRegistry -Path $r.AllowGameDVR.Path -Name $r.AllowGameDVR.Name -Value 0 -Type DWord
        }
        'Lite' {
            # No background recording, but Game Bar itself and the Xbox app keep working.
            Set-OptiRegistry -Path $r.GameDVREnabled.Path -Name $r.GameDVREnabled.Name -Value 0 -Type DWord
            Set-OptiRegistry -Path $r.AppCapture.Path -Name $r.AppCapture.Name -Value 0 -Type DWord
            Set-OptiRegistry -Path $r.FSEBehavior.Path -Name $r.FSEBehavior.Name -Value 2 -Type DWord
            Remove-OptiRegistry -Path $r.AllowGameDVR.Path -Name $r.AllowGameDVR.Name
        }
        'Enabled' {
            Set-OptiRegistry -Path $r.GameDVREnabled.Path -Name $r.GameDVREnabled.Name -Value 1 -Type DWord
            Set-OptiRegistry -Path $r.AppCapture.Path -Name $r.AppCapture.Name -Value 1 -Type DWord
            Remove-OptiRegistry -Path $r.AllowGameDVR.Path -Name $r.AllowGameDVR.Name
            $orig = Get-XboxOriginalRegistryValue -Name $r.FSEBehavior.Name
            if ($null -ne $orig) { Set-OptiRegistry -Path $r.FSEBehavior.Path -Name $r.FSEBehavior.Name -Value $orig -Type DWord }
        }
    }
}

function Get-XboxOriginalRegistryValue {
    <#
    .SYNOPSIS
    Reads one GameDVR value from xbox_fallback_original.json (the state before StudentOpti first touched Xbox).
    #>
    param([string]$Name)
    $file = Join-Path (Get-OptiBackupDir) 'xbox_fallback_original.json'
    if (-not (Test-Path $file)) { return $null }
    try {
        $snap = Get-Content $file -Raw | ConvertFrom-Json
        $hit = @($snap.Registry | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
        if ($hit) { return $hit.Value }
    } catch { }
    return $null
}

function Set-XboxOverlayProtocol {
    <#
    .SYNOPSIS
    Adds the ms-gamingoverlay popup stub when Game Bar is missing, removes it when Game Bar is installed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $gameBar = $null
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $gameBar = Get-AppxPackage -Name 'Microsoft.XboxGamingOverlay' -ErrorAction SilentlyContinue
    }
    if ($gameBar) {
        Remove-OptiRegistry -Path $script:XboxOverlayStubKey
        Write-OptiLog -Message 'Game Bar is installed; ms-gamingoverlay protocol handled by Windows again.' -Level Info
    } else {
        $sys = Join-Path $env:SystemRoot 'System32\systray.exe'
        Set-OptiRegistry -Path $script:XboxOverlayStubKey -Name '(default)' -Value 'URL:ms-gamingoverlay' -Type String
        Set-OptiRegistry -Path $script:XboxOverlayStubKey -Name 'URL Protocol' -Value '' -Type String
        Set-OptiRegistry -Path "$($script:XboxOverlayStubKey)\shell\open\command" -Name '(default)' -Value "`"$sys`"" -Type String
        Write-OptiLog -Message 'Game Bar is missing; suppressed ms-gamingoverlay popups.' -Level Warn
    }
}

function Set-XboxMode {
    <#
    .SYNOPSIS
    Moves all Xbox services and GameDVR keys to Enabled, Lite or Disabled, after saving a fallback snapshot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Enabled', 'Lite', 'Disabled')][string]$Mode)

    Write-OptiLog -Message "Switching Xbox stack to '$Mode' mode..." -Level Info
    Save-XboxFallbackSnapshot -Reason "before Set-XboxMode $Mode" | Out-Null

    $table = Get-XboxModeTable
    if ($Mode -eq 'Disabled') {
        foreach ($p in 'GameBar', 'GameBarFTServer', 'XboxPcApp', 'XboxPcAppFT', 'GamingServicesUI') {
            $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
            if ($procs -and $PSCmdlet.ShouldProcess($p, 'Stop process')) {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $failed = @()
    foreach ($name in $table.Keys | Sort-Object) {
        $target = $table[$name][$Mode]
        if (-not $target) { continue }
        try {
            $perUser = ($name -eq 'BcastDVRUserService')
            if ($perUser) {
                Set-OptiServiceStartup -Name $name -StartupType $target -StopIfDisabled -IncludeUserInstances
            } else {
                Set-OptiServiceStartup -Name $name -StartupType $target -StopIfDisabled
            }
        } catch {
            # GamingServices ships with a locked-down ACL on some builds; report it and keep going.
            $failed += $name
            Write-OptiLog -Message "Could not set $name to $target : $($_.Exception.Message)" -Level Warn
        }
    }
    if ($Mode -eq 'Disabled') {
        foreach ($svcName in 'GamingServices', 'GamingServicesNet') {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running' -and $PSCmdlet.ShouldProcess($svcName, 'Stop service')) {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Set-XboxGameDVR -Mode $Mode

    if ($Mode -eq 'Enabled') {
        Set-XboxOverlayProtocol
        foreach ($svcName in 'XblAuthManager', 'GamingServices') {
            if ((Get-OptiServiceStartup -Name $svcName) -ne 'NotInstalled' -and $PSCmdlet.ShouldProcess($svcName, 'Start service')) {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-OptiLog -Message "Xbox mode '$Mode' applied with warnings ($($failed -join ', ')). Run Restore-XboxFallback if anything misbehaves." -Level Warn
    } else {
        Write-OptiLog -Message "Xbox mode '$Mode' applied. Emergency fallback: Restore-Xbox-Emergency.bat" -Level Success
    }
}

function Register-XboxAppxPackages {
    <#
    .SYNOPSIS
    Re-registers every installed Xbox / Gaming Appx manifest for the current user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return }
    $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*Xbox*' -or $_.Name -like 'Microsoft.Gaming*' })
    foreach ($p in $pkgs) {
        $manifest = Join-Path $p.InstallLocation 'AppXManifest.xml'
        if (-not (Test-Path $manifest)) { continue }
        if ($PSCmdlet.ShouldProcess($p.Name, 'Re-register Appx manifest')) {
            try {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                Write-OptiLog -Message "Re-registered $($p.Name)" -Level Info
            } catch {
                Write-OptiLog -Message "Re-register failed for $($p.Name): $($_.Exception.Message)" -Level Warn
            }
        }
    }
}

function Invoke-XboxFallbackCore {
    <#
    .SYNOPSIS
    Emergency re-enable: Xbox services to Manual, start them, re-register Appx, restore GameDVR; -Deep also reinstalls from the Store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Deep)

    Write-OptiLog -Message 'Xbox fallback: restoring services (Tier 2)...' -Level Info
    Save-XboxFallbackSnapshot -Reason 'before Restore-XboxFallback' | Out-Null

    # Tier 2a: the four core services always go back to the Windows default Manual (Start = 3).
    foreach ($name in $script:XboxCoreServices) {
        try { Set-OptiServiceStartup -Name $name -StartupType Manual }
        catch { Write-OptiLog -Message "Could not reset $name : $($_.Exception.Message)" -Level Warn }
    }
    try { Set-OptiServiceStartup -Name 'BcastDVRUserService' -StartupType Manual -IncludeUserInstances } catch { }
    try { Set-OptiServiceStartup -Name 'GamingServicesNet' -StartupType Manual } catch { }
    # GamingServices: back to what it was before StudentOpti, else the Windows default (Automatic).
    $gsTarget = 'Automatic'
    $origFile = Join-Path (Get-OptiBackupDir) 'xbox_fallback_original.json'
    if (Test-Path $origFile) {
        try {
            $orig = Get-Content $origFile -Raw | ConvertFrom-Json
            $gs = @($orig.Services | Where-Object { $_.Service -eq 'GamingServices' }) | Select-Object -First 1
            if ($gs -and $gs.Start -eq 3) { $gsTarget = 'Manual' }
        } catch { }
    }
    try { Set-OptiServiceStartup -Name 'GamingServices' -StartupType $gsTarget } catch { }

    # Tier 2b: start what Xbox sign-in and Game Pass need.
    foreach ($svcName in 'XblAuthManager', 'XblGameSave', 'GamingServices') {
        if ((Get-OptiServiceStartup -Name $svcName) -ne 'NotInstalled' -and $PSCmdlet.ShouldProcess($svcName, 'Start service')) {
            try { Start-Service -Name $svcName -ErrorAction Stop }
            catch { Write-OptiLog -Message "Could not start $svcName : $($_.Exception.Message)" -Level Warn }
        }
    }

    # Tier 2c: Appx manifests, GameDVR, popup suppression.
    Register-XboxAppxPackages
    Set-XboxGameDVR -Mode Enabled
    Set-XboxOverlayProtocol

    $missing = @()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($pkg in Get-XboxPackageList) {
            if ($pkg.store_id -and -not (Get-AppxPackage -Name $pkg.pattern -ErrorAction SilentlyContinue)) { $missing += $pkg }
        }
    }
    if ($missing.Count -gt 0 -and -not $Deep) {
        Write-OptiLog -Message "Missing Xbox packages: $(($missing | ForEach-Object { $_.pattern }) -join ', '). Run the Deep Repair to reinstall them." -Level Warn
    }

    if ($Deep) { Invoke-XboxDeepRepair -Missing $missing }

    $bad = @($script:XboxCoreServices | Where-Object { $s = Get-OptiServiceStartup -Name $_; $s -ne 'Manual' -and $s -ne 'NotInstalled' })
    if ($bad.Count -eq 0) {
        Write-OptiLog -Message 'Xbox fallback complete: core Xbox services are back to Manual.' -Level Success
    } else {
        Write-OptiLog -Message "Xbox fallback incomplete for: $($bad -join ', '). Run Restore-Xbox-Emergency.bat as administrator." -Level Error
    }
}

function Invoke-XboxDeepRepair {
    <#
    .SYNOPSIS
    Tier 3: makes sure the Store services run, then reinstalls missing Xbox packages with winget and resets Gaming Services.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Missing = @())

    Write-OptiLog -Message 'Xbox deep repair (Tier 3)...' -Level Info
    foreach ($svcName in 'ClipSVC', 'AppXSvc', 'InstallService') {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ((Get-OptiServiceStartup -Name $svcName) -eq 'Disabled') {
            # These are trigger-start Manual services by default; Disabled breaks the Store.
            try { Set-OptiServiceStartup -Name $svcName -StartupType Manual } catch { }
        }
        if ($svc.Status -ne 'Running' -and $PSCmdlet.ShouldProcess($svcName, 'Start service')) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
    }

    if (Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($name in 'Microsoft.GamingServices', 'Microsoft.XboxIdentityProvider') {
            $p = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue
            if ($p -and $PSCmdlet.ShouldProcess($name, 'Reset-AppxPackage')) {
                try { $p | Reset-AppxPackage -ErrorAction Stop; Write-OptiLog -Message "Reset $name" -Level Info }
                catch { Write-OptiLog -Message "Reset failed for $name : $($_.Exception.Message)" -Level Warn }
            }
        }
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-OptiLog -Message 'winget (App Installer) not found. Install missing Xbox apps from the Microsoft Store.' -Level Warn
        return
    }
    # Gaming Services must exist before the Xbox app can install games, so it goes first.
    $order = @($Missing | Sort-Object { if ($_.pattern -eq 'Microsoft.GamingServices') { 0 } else { 1 } })
    foreach ($pkg in $order) {
        if (-not $pkg.store_id) { continue }
        if ($PSCmdlet.ShouldProcess("$($pkg.name) ($($pkg.store_id))", 'winget install from msstore')) {
            Write-OptiLog -Message "Installing $($pkg.name) from the Microsoft Store..." -Level Info
            & $winget.Source install --id $pkg.store_id --source msstore --accept-package-agreements --accept-source-agreements --silent | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-OptiLog -Message "Installed $($pkg.name)" -Level Success }
            else { Write-OptiLog -Message "winget returned $LASTEXITCODE for $($pkg.name)" -Level Warn }
        }
    }
    Set-XboxOverlayProtocol
}

function Install-XboxEmergencyScript {
    <#
    .SYNOPSIS
    Copies Restore-Xbox-Emergency.bat to the Desktop and the data folder so recovery works without this app.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $src = Join-Path (Get-OptiRoot) 'Restore-Xbox-Emergency.bat'
    if (-not (Test-Path $src)) {
        Write-OptiLog -Message "Emergency script not found at $src" -Level Error
        return
    }
    $targets = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Restore-Xbox-Emergency.bat'),
                 (Join-Path (Get-OptiDataDir) 'Restore-Xbox-Emergency.bat'))
    foreach ($t in $targets) {
        if ($PSCmdlet.ShouldProcess($t, 'Copy emergency Xbox script')) {
            Copy-Item -Path $src -Destination $t -Force
            Write-OptiLog -Message "Emergency Xbox script copied to $t" -Level Success
        }
    }
}

function Restore-XboxFallback {
    <#
    .SYNOPSIS
    Recovery path: runs Invoke-XboxFallbackCore with the mandatory-restore-point gate bypassed, so recovery works even when System Restore is broken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Deep)
    $prev = $global:OptiSafetyBypass
    $global:OptiSafetyBypass = $true
    try { Invoke-XboxFallbackCore -Deep:$Deep } finally { $global:OptiSafetyBypass = $prev }
}
