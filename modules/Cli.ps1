# Cli.ps1 - interactive console menu for StudentOpti. Function definitions only (no top-level side effects).

function Get-OptiPresetById {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    try {
        foreach ($p in @((Get-OptiConfig -Name presets).presets)) { if ($p.id -eq $Id) { return $p } }
    } catch { }
    return $null
}

function Test-OptiDryRun {
    [CmdletBinding()] param()
    return [bool]$global:WhatIfPreference
}

function Get-OptiBannerInfo {
    [CmdletBinding()] param()
    if ($script:OptiBannerInfo) { return $script:OptiBannerInfo }
    $os = 'Windows'; $ram = '?'; $disk = 'unknown'
    try {
        $o = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $os = ('{0} (build {1})' -f $o.Caption, $o.BuildNumber)
        $ram = [string][Math]::Round($o.TotalVisibleMemorySize / 1MB, 1)
    } catch {
        try { $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription } catch { }
    }
    if (Get-Command Get-OptiDriveInfo -ErrorAction SilentlyContinue) {
        try {
            $d = Get-OptiDriveInfo
            if ($d.IsNVMe) { $disk = 'NVMe SSD' } elseif ($d.IsSSD) { $disk = 'SSD' } elseif ($d.MediaType -eq 'HDD') { $disk = 'HDD' } else { $disk = [string]$d.MediaType }
            if ($d.RAMGB) { $ram = [string]$d.RAMGB }
        } catch { }
    }
    $script:OptiBannerInfo = [pscustomobject]@{ OS = $os; RAM = $ram; Disk = $disk }
    return $script:OptiBannerInfo
}

function Show-OptiBanner {
    [CmdletBinding()] param()
    $info = Get-OptiBannerInfo
    $ver = '1.0'
    Write-Host ''
    Write-Host '   ____  _             _            _    ___        _   _ ' -ForegroundColor Cyan
    Write-Host '  / ___|| |_ _   _  __| | ___ _ __ | |_ / _ \ _ __ | |_(_)' -ForegroundColor Cyan
    Write-Host '  \___ \| __| | | |/ _` |/ _ \ ''_ \| __| | | | ''_ \| __| |' -ForegroundColor Cyan
    Write-Host '   ___) | |_| |_| | (_| |  __/ | | | |_| |_| | |_) | |_| |' -ForegroundColor Cyan
    Write-Host '  |____/ \__|\__,_|\__,_|\___|_| |_|\__|\___/| .__/ \__|_|' -ForegroundColor Cyan
    Write-Host '                                             |_|           ' -ForegroundColor Cyan
    Write-Host ('  StudentOpti v{0}  -  Windows optimizer for students' -f $ver) -ForegroundColor White
    Write-Host ('  OS   : {0}' -f $info.OS) -ForegroundColor Gray
    Write-Host ('  RAM  : {0} GB    System drive: {1}' -f $info.RAM, $info.Disk) -ForegroundColor Gray
    $adm = 'no'; $admColor = 'Red'
    if (Test-OptiAdmin) { $adm = 'yes'; $admColor = 'Green' }
    if ($script:OptiSafetyNetDone) { Write-Host '  Safety: Safety net ready' -ForegroundColor Green }
    else { Write-Host '  Safety: restore point required before changes' -ForegroundColor Yellow }
    Write-Host '  Admin: ' -ForegroundColor Gray -NoNewline
    Write-Host $adm -ForegroundColor $admColor
    if (Test-OptiDryRun) {
        Write-Host ''
        Write-Host '  *** DRY RUN: nothing will be changed, actions are only previewed ***' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Read-OptiConfirm {
    [CmdletBinding()]
    param([string]$Prompt = 'Type Y to continue')
    if ($global:OptiYes) { return $true }
    $a = Read-Host $Prompt
    return ($a -match '^\s*[Yy]\s*$')
}

function Read-OptiPause {
    [CmdletBinding()] param()
    [void](Read-Host 'Press Enter to return to the menu')
}

function Show-OptiSummary {
    [CmdletBinding()] param()
    $res = @(Get-OptiResults)
    Write-Host ''
    Write-Host '== Summary ==' -ForegroundColor Cyan
    $defs = @(
        @('Applied', 'Green'), @('Undone', 'Cyan'), @('Skipped', 'DarkGray'), @('Failed', 'Red'), @('DryRun', 'Yellow')
    )
    foreach ($d in $defs) {
        $n = @($res | Where-Object { $_.Status -eq $d[0] }).Count
        $c = $d[1]
        if ($n -eq 0) { $c = 'DarkGray' }
        Write-Host ('  {0,-8} {1}' -f $d[0], $n) -ForegroundColor $c
    }
    $failed = @($res | Where-Object { $_.Status -eq 'Failed' })
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host '  Failures:' -ForegroundColor Red
        foreach ($f in $failed) { Write-Host ('   - {0}: {1}' -f $f.Name, $f.Message) -ForegroundColor Red }
    }
    $elapsed = [TimeSpan]::Zero
    if ($global:OptiStartTime) { $elapsed = (Get-Date) - $global:OptiStartTime }
    Write-Host ''
    Write-Host ('  Elapsed: {0:N1} s' -f $elapsed.TotalSeconds) -ForegroundColor Gray
    try { Write-Host ('  Backups: {0}' -f (Get-OptiBackupDir)) -ForegroundColor Gray } catch { }
    Write-Host ''
}

function Request-OptiRestart {
    [CmdletBinding()] param()
    if (-not $global:OptiChangesMade) { return }
    if (Test-OptiDryRun) { return }
    if ($global:OptiNoRestartPrompt) { return }
    Write-Host ''
    $a = Read-Host 'Restart now to apply all changes? [Y/N]'
    if ($a -notmatch '^\s*[Yy]') {
        Write-Host 'Remember to restart later.' -ForegroundColor Yellow
        return
    }
    $cancelled = $false
    for ($i = 10; $i -ge 1; $i--) {
        Write-Host ('Restarting in {0}... press any key to cancel' -f $i) -ForegroundColor Yellow
        $end = (Get-Date).AddSeconds(1)
        while ((Get-Date) -lt $end) {
            $avail = $false
            try { $avail = [Console]::KeyAvailable } catch { $avail = $false }
            if ($avail) { try { [void][Console]::ReadKey($true) } catch { }; $cancelled = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if ($cancelled) { break }
    }
    if ($cancelled) {
        Write-Host 'Restart cancelled. Remember to restart later.' -ForegroundColor Yellow
        return
    }
    Restart-Computer -Force
}

function Invoke-OptiRun {
    # Runs a block with fresh result tracking, then prints the summary and offers a restart.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Code, [switch]$SafetyNet, [switch]$NoPause)
    Reset-OptiResults
    Write-Host ''
    Write-Host ('>>> ' + $Title) -ForegroundColor White
    if (Test-OptiDryRun) { Write-Host '    (dry run - nothing will be changed)' -ForegroundColor Yellow }
    try {
        $proceed = $true
        if ($SafetyNet) {
            Write-OptiSection 'Safety net'
            $proceed = Confirm-OptiSafetyNet
            if ($proceed -and -not (Test-OptiDryRun)) { Write-Host '  Safety net ready' -ForegroundColor Green }
        }
        if (-not $proceed) { throw 'Safety stop: restore point is mandatory.' }
        & $Code
    } catch {
        Add-OptiResult -Id 'run' -Name $Title -Status Failed -Message $_.Exception.Message
    }
    Show-OptiSummary
    Request-OptiRestart
    if (-not $NoPause) { Read-OptiPause }
}

function Get-OptiAllItems {
    [CmdletBinding()] param()
    $all = New-Object System.Collections.ArrayList
    foreach ($src in @('tweaks', 'services', 'tasks')) {
        try { foreach ($it in @((Get-OptiConfig -Name $src).$src)) { [void]$all.Add($it) } } catch { }
    }
    return @($all)
}

function Get-OptiItemTier {
    param($Item)
    if ($Item.PSObject.Properties['tier'] -and $Item.tier) { return [string]$Item.tier }
    return ''
}

function Get-OptiRiskColor {
    param([string]$Risk)
    switch ($Risk) { 'Safe' { return 'Green' } 'Moderate' { return 'Yellow' } 'Caution' { return 'Red' } default { return 'Gray' } }
}

function ConvertTo-OptiIndexList {
    # Parses "1,4,7-9" or "a" into 1-based indices limited to Max.
    [CmdletBinding()]
    param([string]$Text, [int]$Max)
    $out = New-Object System.Collections.ArrayList
    if ($Text -match '^\s*[Aa]\s*$') { for ($i = 1; $i -le $Max; $i++) { [void]$out.Add($i) }; return @($out) }
    foreach ($part in ($Text -split '[,\s]+')) {
        if (-not $part) { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $Max -and -not $out.Contains($i)) { [void]$out.Add($i) } }
        } elseif ($part -match '^\d+$') {
            $i = [int]$part
            if ($i -ge 1 -and $i -le $Max -and -not $out.Contains($i)) { [void]$out.Add($i) }
        }
    }
    return @($out)
}

function Show-OptiPresetConfirm {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preset)
    Write-Host ''
    Write-Host ($Preset.name) -ForegroundColor White
    Write-Host ('  ' + $Preset.description) -ForegroundColor Gray
    $plan = Get-OptiPresetPlan -Preset $Preset
    $ids = @($plan.TweakIds) + @($plan.ServiceIds) + @($plan.TaskIds)
    $items = @()
    foreach ($id in $ids) { $it = Find-OptiItem -Id $id; if ($it) { $items += $it } }
    $safe = @($items | Where-Object { $_.risk_level -eq 'Safe' }).Count
    $mod = @($items | Where-Object { $_.risk_level -eq 'Moderate' }).Count
    $cau = @($items | Where-Object { $_.risk_level -eq 'Caution' })
    Write-Host ''
    Write-Host ('  Items: {0} total  ({1} tweaks, {2} services, {3} tasks)' -f $items.Count, $plan.TweakIds.Count, $plan.ServiceIds.Count, $plan.TaskIds.Count) -ForegroundColor Gray
    Write-Host '  By risk: ' -NoNewline -ForegroundColor Gray
    Write-Host ('Safe {0}' -f $safe) -ForegroundColor Green -NoNewline
    Write-Host ', ' -NoNewline
    Write-Host ('Moderate {0}' -f $mod) -ForegroundColor Yellow -NoNewline
    Write-Host ', ' -NoNewline
    Write-Host ('Caution {0}' -f $cau.Count) -ForegroundColor Red
    if ($cau.Count -gt 0) {
        Write-Host '  Caution items included:' -ForegroundColor Red
        foreach ($c in $cau) { Write-Host ('   - {0}' -f $c.name) -ForegroundColor Red }
    }
    $extras = @()
    if ($Preset.remove_appx) { $extras += 'remove bloat apps' }
    if ($Preset.xbox_mode) { $extras += ('Xbox mode ' + $Preset.xbox_mode) }
    if ($Preset.power_profile) { $extras += ('power profile ' + $Preset.power_profile) }
    if ($Preset.cleanup) { $extras += 'temp cleanup' }
    if ($extras.Count -gt 0) { Write-Host ('  Also: ' + ($extras -join ', ')) -ForegroundColor Gray }
    Write-Host '  A restore point and settings snapshot are created first (mandatory).' -ForegroundColor Gray
    Write-Host ''
}

function Invoke-OptiPresetMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PresetId)
    $p = Get-OptiPresetById -Id $PresetId
    if (-not $p) { Write-Host ('Preset {0} is not available.' -f $PresetId) -ForegroundColor Red; Read-OptiPause; return }
    Show-OptiPresetConfirm -Preset $p
    if (-not (Read-OptiConfirm 'Type Y to run this preset (anything else cancels)')) { Write-Host 'Cancelled.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700; return }
    Invoke-OptiRun -Title ('Preset: ' + $p.name) -Code { Invoke-OptiPreset -Id $PresetId }
}

function Show-OptiCategoryMenu {
    [CmdletBinding()] param()
    while ($true) {
        $all = Get-OptiAllItems
        $cats = @($all | ForEach-Object { [string]$_.category } | Sort-Object -Unique)
        Write-Host ''
        Write-Host 'Categories' -ForegroundColor Cyan
        for ($i = 0; $i -lt $cats.Count; $i++) {
            $n = @($all | Where-Object { $_.category -eq $cats[$i] }).Count
            Write-Host ('  {0,2}. {1} ({2})' -f ($i + 1), $cats[$i], $n)
        }
        Write-Host '   B. Back'
        $sel = Read-Host 'Category number'
        if ($sel -match '^\s*[Bb]?\s*$') { return }
        if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $cats.Count) { continue }
        $cat = $cats[[int]$sel - 1]
        $items = @($all | Where-Object { $_.category -eq $cat })
        while ($true) {
            Write-Host ''
            Write-Host ('{0}  (checking current state...)' -f $cat) -ForegroundColor Cyan
            for ($i = 0; $i -lt $items.Count; $i++) {
                $it = $items[$i]
                $on = $false
                try { $on = [bool](Invoke-OptiTweak -Id $it.id -Action Check) } catch { }
                $mark = '[ ]'; $mc = 'Gray'
                if ($on) { $mark = '[x]'; $mc = 'Green' }
                Write-Host ('  {0,2}. ' -f ($i + 1)) -NoNewline
                Write-Host $mark -ForegroundColor $mc -NoNewline
                Write-Host (' {0}  ' -f $it.name) -NoNewline
                $tier = Get-OptiItemTier $it
                $tag = $it.risk_level
                if ($tier) { $tag = $tag + ', ' + $tier }
                Write-Host ('({0})' -f $tag) -ForegroundColor (Get-OptiRiskColor $it.risk_level)
            }
            Write-Host ''
            Write-Host '  [x] = tweak currently applied.  Type numbers like 1,4,7-9 or a for all.' -ForegroundColor DarkGray
            $pick = Read-Host 'Select items (B = back)'
            if ($pick -match '^\s*[Bb]\s*$' -or $pick -match '^\s*$') { break }
            $idx = @(ConvertTo-OptiIndexList -Text $pick -Max $items.Count)
            if ($idx.Count -eq 0) { Write-Host 'Nothing selected.' -ForegroundColor Yellow; continue }
            $chosen = @($idx | ForEach-Object { $items[$_ - 1] })
            $act = Read-Host ('{0} item(s) selected. [A]pply / [U]ndo / [B]ack' -f $chosen.Count)
            $action = ''
            if ($act -match '^\s*[Aa]') { $action = 'Apply' } elseif ($act -match '^\s*[Uu]') { $action = 'Undo' } else { continue }
            Invoke-OptiRun -Title ('{0} {1} item(s) in {2}' -f $action, $chosen.Count, $cat) -SafetyNet -Code {
                foreach ($c in $chosen) {
                    if ($global:OptiSafetyStop) { break }
                    try { Invoke-OptiTweak -Id $c.id -Action $action }
                    catch { Add-OptiResult -Id $c.id -Name $c.name -Action $action -Status Failed -Message $_.Exception.Message }
                }
            }
        }
    }
}

function Get-OptiXboxRows {
    [CmdletBinding()] param()
    $rows = @()
    try { $rows = @(Get-XboxStatus) } catch { Write-Host ('Get-XboxStatus failed: ' + $_.Exception.Message) -ForegroundColor Red }
    return $rows
}

function Show-OptiXboxMenu {
    [CmdletBinding()] param()
    while ($true) {
        Write-Host ''
        Write-Host 'Xbox control center' -ForegroundColor Cyan
        foreach ($r in @(Get-OptiXboxRows)) {
            if ($r.Kind -eq 'Registry') { continue }
            $state = ''; $color = 'Green'
            if (-not $r.Installed) { $state = 'not installed'; $color = 'Red' }
            elseif ($r.Kind -eq 'Service') {
                $state = ('{0} / {1}' -f $r.StartupType, $r.Status)
                if ($r.StartupType -eq 'Disabled') { $color = 'Red' } elseif ($r.Status -eq 'Running') { $color = 'Green' } else { $color = 'Yellow' }
            } else { $state = [string]$r.Status }
            Write-Host ('  {0,-12}' -f $r.Kind) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,-38}' -f $r.Name) -NoNewline
            Write-Host $state -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  1. Enabled (everything on)'
        Write-Host '  2. Lite (core services on demand)'
        Write-Host '  3. Disabled (Xbox off)'
        Write-Host '  4. Emergency repair (re-enable + fix)'
        Write-Host '  5. Deep repair (re-register / reinstall, slow)'
        Write-Host '  6. Put emergency script on desktop'
        Write-Host '  B. Back'
        $c = Read-Host 'Choice'
        switch -Regex ($c.Trim()) {
            '^1$' { Invoke-OptiRun -Title 'Xbox mode: Enabled' -SafetyNet -Code { Invoke-OptiStep -Id 'xbox_mode' -Name 'Xbox mode: Enabled' -Code { Set-XboxMode -Mode Enabled } } }
            '^2$' { Invoke-OptiRun -Title 'Xbox mode: Lite' -SafetyNet -Code { Invoke-OptiStep -Id 'xbox_mode' -Name 'Xbox mode: Lite' -Code { Set-XboxMode -Mode Lite } } }
            '^3$' { Invoke-OptiRun -Title 'Xbox mode: Disabled' -SafetyNet -Code { Invoke-OptiStep -Id 'xbox_mode' -Name 'Xbox mode: Disabled' -Code { Set-XboxMode -Mode Disabled } } }
            '^4$' { Invoke-OptiRun -Title 'Xbox emergency repair' -Code { Invoke-OptiStep -Id 'xbox_repair' -Name 'Xbox emergency repair' -Code { Restore-XboxFallback } } }
            '^5$' {
                if (Read-OptiConfirm 'Deep repair can take several minutes. Type Y to continue') {
                    Invoke-OptiRun -Title 'Xbox deep repair' -Code { Invoke-OptiStep -Id 'xbox_deep' -Name 'Xbox deep repair' -Code { Restore-XboxFallback -Deep } }
                }
            }
            '^6$' { Invoke-OptiRun -Title 'Install emergency script on desktop' -Code { Invoke-OptiStep -Id 'xbox_script' -Name 'Emergency script on desktop' -Code { Install-XboxEmergencyScript } } }
            '^[Bb]?$' { return }
        }
    }
}

function Show-OptiBloatMenu {
    [CmdletBinding()] param()
    $apps = @()
    try { $apps = @(Get-OptiBloatApps | Where-Object { -not $_.Protected }) } catch { Write-Host ('Could not list apps: ' + $_.Exception.Message) -ForegroundColor Red }
    Write-Host ''
    if ($apps.Count -eq 0) { Write-Host 'No removable bloat apps found.' -ForegroundColor Green; Read-OptiPause; return }
    Write-Host ('{0} removable app(s):' -f $apps.Count) -ForegroundColor Cyan
    foreach ($a in $apps) { Write-Host ('  - {0}  ({1})' -f $a.Label, $a.Name) }
    Write-Host 'Store, Office, Xbox and system apps are protected.' -ForegroundColor DarkGray
    if (-not (Read-OptiConfirm 'Type Y to remove these apps')) { return }
    Invoke-OptiRun -Title 'Remove bloat apps' -SafetyNet -Code { Invoke-OptiStep -Id 'remove_appx' -Name 'Remove bloat apps' -Code { Remove-OptiBloatApps } }
}

function Show-OptiBackupMenu {
    [CmdletBinding()] param()
    while ($true) {
        Write-Host ''
        Write-Host 'Backups' -ForegroundColor Cyan
        Write-Host '  1. Create restore point + snapshot now'
        Write-Host '  2. Restore last snapshot'
        Write-Host '  3. List snapshots'
        Write-Host '  B. Back'
        $c = Read-Host 'Choice'
        switch -Regex ($c.Trim()) {
            '^1$' { Invoke-OptiRun -Title 'Create restore point' -Code { Invoke-OptiStep -Id 'restore_point' -Name 'Restore point + snapshot' -Code { $global:OptiSafetyBypass = $true; try { New-OptiRestorePoint; [void](New-OptiStateSnapshot -Label 'manual') } finally { $global:OptiSafetyBypass = $false } } } }
            '^2$' {
                if (Read-OptiConfirm 'Type Y to restore the most recent snapshot') {
                    Invoke-OptiRun -Title 'Restore last snapshot' -Code { Invoke-OptiStep -Id 'restore_snapshot' -Name 'Restore last snapshot' -Code { Restore-OptiStateSnapshot } }
                }
            }
            '^3$' {
                $snaps = @(Get-OptiSnapshots)
                if ($snaps.Count -eq 0) { Write-Host 'No snapshots yet.' -ForegroundColor Yellow }
                foreach ($s in $snaps) { Write-Host ('  {0}  {1}  {2} KB' -f $s.Created, $s.Name, $s.SizeKB) }
                Write-Host ('  Folder: ' + (Get-OptiBackupDir)) -ForegroundColor DarkGray
                Read-OptiPause
            }
            '^[Bb]?$' { return }
        }
    }
}

function Show-OptiMainMenu {
    [CmdletBinding()] param()
    $presetMap = @(
        @('1', 'LightestWindows', 'Lightest Windows (strip it down, low risk to stability)'),
        @('2', 'StrongestOptimizer', 'Strongest Optimizer (deep, includes Caution items)'),
        @('3', 'StudentLaptop', 'Student Laptop Boost'),
        @('4', 'StudyBattery', 'Study Battery Saver'),
        @('5', 'GamingXbox', 'Gaming / Xbox Ready'),
        @('6', 'FactoryDefault', 'Restore Windows defaults')
    )
    while ($true) {
        try { Clear-Host } catch { }
        Show-OptiBanner
        Write-Host '  One-click presets' -ForegroundColor Cyan
        foreach ($m in $presetMap) {
            if (Get-OptiPresetById -Id $m[1]) { Write-Host ('   {0}. {1}' -f $m[0], $m[2]) }
            else { Write-Host ('   {0}. {1} (not available)' -f $m[0], $m[2]) -ForegroundColor DarkGray }
        }
        Write-Host ''
        Write-Host '  Tools' -ForegroundColor Cyan
        Write-Host '   7. Choose tweaks by category'
        Write-Host '   8. Xbox control center'
        Write-Host '   9. Remove bloat apps'
        Write-Host '  10. Clean temp files'
        Write-Host '  11. Backups (restore point / snapshots)'
        Write-Host '   M. Disk, RAM & cleanup'
        Write-Host ''
        $dr = 'OFF'; if (Test-OptiDryRun) { $dr = 'ON' }
        Write-Host ('   D. Toggle dry run (currently {0})' -f $dr)
        Write-Host '   Q. Quit'
        Write-Host ''
        $c = (Read-Host 'Choose').Trim()
        switch -Regex ($c) {
            '^[1-6]$' { Invoke-OptiPresetMenu -PresetId ($presetMap[[int]$c - 1][1]) }
            '^7$' { Show-OptiCategoryMenu }
            '^8$' { Show-OptiXboxMenu }
            '^9$' { Show-OptiBloatMenu }
            '^10$' { Invoke-OptiRun -Title 'Clean temp files' -SafetyNet -Code { Invoke-OptiStep -Id 'cleanup' -Name 'Clean temp files' -Code { Clear-OptiTempFiles } } }
            '^11$' { Show-OptiBackupMenu }
            '^[Mm]$' {
                if (Get-Command Show-OptiMaintenanceMenu -ErrorAction SilentlyContinue) {
                    Reset-OptiResults
                    try { if (Confirm-OptiSafetyNet) { Show-OptiMaintenanceMenu } } catch { Add-OptiResult -Id 'maintenance' -Name 'Disk, RAM & cleanup' -Status Failed -Message $_.Exception.Message }
                    Show-OptiSummary
                    Request-OptiRestart
                    Read-OptiPause
                } else { Write-Host 'Maintenance module not available.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
            }
            '^[Dd]$' { $global:WhatIfPreference = (-not [bool]$global:WhatIfPreference) }
            '^[Qq]$' { return }
        }
    }
}
