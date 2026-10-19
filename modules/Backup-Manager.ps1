# Backup-Manager.ps1 - restore point, state snapshot, hive export, restore. Functions only (no top-level side effects).

function New-OptiRestorePoint {
<#
.SYNOPSIS
Creates a Windows System Restore point named "Pre-StudentOpti Snapshot" (failure is logged as a warning).
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $valName = 'SystemRestorePointCreationFrequency'
    $hadValue = $false
    $oldValue = $null
    $changed = $false
    try {
        if (-not $PSCmdlet.ShouldProcess('System drive', 'Create restore point')) { return $false }
        $drive = $env:SystemDrive
        if (-not $drive) { $drive = 'C:' }
        try { Enable-ComputerRestore -Drive ($drive + '\') -ErrorAction Stop }
        catch { Write-OptiLog -Message "Enable-ComputerRestore failed: $($_.Exception.Message)" -Level Warn }

        $existing = Get-ItemProperty -Path $key -Name $valName -ErrorAction SilentlyContinue
        if ($null -ne $existing) { $hadValue = $true; $oldValue = $existing.$valName }
        Set-ItemProperty -Path $key -Name $valName -Value 0 -Type DWord -ErrorAction Stop
        $changed = $true

        Checkpoint-Computer -Description 'Pre-StudentOpti Snapshot' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-OptiLog -Message 'System restore point created.' -Level Success
        return $true
    }
    catch {
        Write-OptiLog -Message "Could not create restore point: $($_.Exception.Message)" -Level Warn
        return $false
    }
    finally {
        if ($changed) {
            try {
                if ($hadValue) { Set-ItemProperty -Path $key -Name $valName -Value $oldValue -Type DWord -ErrorAction Stop }
                else { Remove-ItemProperty -Path $key -Name $valName -ErrorAction SilentlyContinue }
            } catch { Write-OptiLog -Message "Could not restore restore-point frequency setting: $($_.Exception.Message)" -Level Warn }
        }
    }
}

function Get-OptiActivePowerGuid {
<#
.SYNOPSIS
Returns the GUID of the active power scheme parsed from powercfg, or $null.
#>
    [CmdletBinding()]
    param()
    try {
        $out = (& powercfg /getactivescheme 2>$null) | Out-String
        $m = [regex]::Match($out, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
        if ($m.Success) { return $m.Value.ToLower() }
    } catch { }
    return $null
}

function Get-OptiRegistryEntryState {
<#
.SYNOPSIS
Reads one registry value into a snapshot record (path, name, exists, type, value).
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $rec = [ordered]@{ path = $Path; name = $Name; exists = $false; type = $null; value = $null }
    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $names = $item.GetValueNames()
            $lookup = $Name
            if ($Name -eq '(default)') { $lookup = '' }
            if ($names -contains $lookup) {
                $rec.exists = $true
                $kind = $item.GetValueKind($lookup)
                $rec.type = [string]$kind
                $val = $item.GetValue($lookup, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($kind -eq 'Binary') { $rec.value = @($val | ForEach-Object { [int]$_ }) }
                elseif ($kind -eq 'MultiString') { $rec.value = @($val) }
                else { $rec.value = $val }
            }
        }
    } catch {
        Write-OptiLog -Message "Snapshot: cannot read $Path\$Name : $($_.Exception.Message)" -Level Warn
    }
    return [pscustomobject]$rec
}

function New-OptiStateSnapshot {
<#
.SYNOPSIS
Saves registry values, service startup, Appx packages and power scheme to backups\state_<timestamp>.json and returns the path.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Label = '')
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Get-OptiBackupDir
    $file = Join-Path $dir ("state_{0}.json" -f $ts)
    if (-not $PSCmdlet.ShouldProcess($file, 'Write state snapshot')) { return $null }

    $seen = @{}
    $regList = New-Object System.Collections.ArrayList
    $svcList = New-Object System.Collections.ArrayList
    try {
        foreach ($cfgName in 'tweaks', 'services') {
            $cfg = Get-OptiConfig -Name $cfgName
            $items = @()
            if ($cfgName -eq 'tweaks') { $items = @($cfg.tweaks) } else { $items = @($cfg.services) }
            foreach ($it in $items) {
                foreach ($r in @($it.registry)) {
                    if ($null -eq $r -or -not $r.path) { continue }
                    $k = ($r.path + '|' + $r.name).ToLower()
                    if ($seen.ContainsKey($k)) { continue }
                    $seen[$k] = $true
                    [void]$regList.Add((Get-OptiRegistryEntryState -Path $r.path -Name $r.name))
                }
                if ($cfgName -eq 'services' -and $it.service) {
                    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $it.service
                    $installed = Test-Path -LiteralPath $svcKey
                    $start = $null; $delayed = $null; $status = 'NotInstalled'
                    if ($installed) {
                        $start = Get-OptiRegistry -Path $svcKey -Name 'Start'
                        $delayed = Get-OptiRegistry -Path $svcKey -Name 'DelayedAutostart'
                        $status = 'Unknown'
                        try { $status = [string](Get-Service -Name $it.service -ErrorAction Stop).Status } catch { }
                    }
                    [void]$svcList.Add([pscustomobject]@{
                        id = $it.id; service = $it.service; installed = $installed
                        Start = $start; DelayedAutostart = $delayed; status = $status
                    })
                }
            }
        }
    } catch {
        Write-OptiLog -Message "Snapshot: config read problem: $($_.Exception.Message)" -Level Warn
    }

    $appx = @()
    try {
        $appx = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; PackageFullName = $_.PackageFullName; InstallLocation = $_.InstallLocation }
        })
    } catch { Write-OptiLog -Message "Snapshot: Get-AppxPackage failed: $($_.Exception.Message)" -Level Warn }

    $guid = Get-OptiActivePowerGuid
    $powFile = $null
    if ($guid) {
        $powFile = Join-Path $dir ("power_{0}.pow" -f $ts)
        try {
            & powercfg /export $powFile $guid 2>$null | Out-Null
            if (-not (Test-Path -LiteralPath $powFile)) { $powFile = $null }
        } catch { $powFile = $null }
        if (-not $powFile) { Write-OptiLog -Message 'Snapshot: could not export power scheme.' -Level Warn }
    }

    $snap = [ordered]@{
        version  = 1
        created  = (Get-Date).ToString('o')
        label    = $Label
        computer = $env:COMPUTERNAME
        registry = @($regList)
        services = @($svcList)
        appx     = $appx
        power    = [ordered]@{ activeGuid = $guid; exportFile = $powFile }
    }
    $json = $snap | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-OptiLog -Message "State snapshot saved: $file" -Level Success
    return $file
}

function Export-OptiRegistryHives {
<#
.SYNOPSIS
Exports key registry hives with reg.exe to backups\hives_<timestamp>\ and returns the folder.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $out = Join-Path (Get-OptiBackupDir) ("hives_{0}" -f $ts)
    if (-not $PSCmdlet.ShouldProcess($out, 'Export registry hives')) { return $null }
    [void][IO.Directory]::CreateDirectory($out)
    $cv = 'HKCU\Software\Microsoft\Windows\CurrentVersion'
    $keys = @(
        'HKLM\SYSTEM\CurrentControlSet\Services',
        'HKCU\Control Panel\Desktop',
        ($cv + '\Explorer'),
        ($cv + '\Themes'),
        ($cv + '\ContentDeliveryManager'),
        ($cv + '\Search'),
        ($cv + '\GameDVR'),
        'HKCU\System\GameConfigStore',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows'
    )
    foreach ($k in $keys) {
        $fname = ($k -replace '[\\ :]', '_') + '.reg'
        $target = Join-Path $out $fname
        try {
            & reg.exe export $k $target /y 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-OptiLog -Message "Hive export skipped (not found or denied): $k" -Level Warn }
        } catch { Write-OptiLog -Message "Hive export failed for ${k}: $($_.Exception.Message)" -Level Warn }
    }
    Write-OptiLog -Message "Registry hives exported to $out" -Level Success
    return $out
}

function Get-OptiSnapshots {
<#
.SYNOPSIS
Lists state snapshots in the backup folder, newest first.
#>
    [CmdletBinding()]
    param()
    $dir = Get-OptiBackupDir
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'state_*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($f in $files) {
        [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Created = $f.LastWriteTime; SizeKB = [math]::Round($f.Length / 1KB, 1) }
    }
}

function Restore-OptiStateSnapshot {
<#
.SYNOPSIS
Restores registry values, service startup and the power scheme from a state snapshot (latest if no path given).
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not $Path) {
        $latest = @(Get-OptiSnapshots) | Select-Object -First 1
        if (-not $latest) { Write-OptiLog -Message 'No snapshot found to restore.' -Level Warn; return $false }
        $Path = $latest.Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { Write-OptiLog -Message "Snapshot not found: $Path" -Level Error; return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restore state snapshot')) { return $false }

    $snap = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $ok = 0; $fail = 0
    foreach ($r in @($snap.registry)) {
        try {
            if (-not $r.exists) {
                Remove-OptiRegistry -Path $r.path -Name $r.name
            }
            else {
                $t = [string]$r.type
                $v = $r.value
                switch ($t) {
                    'Binary'      { $v = [byte[]]@($v | ForEach-Object { [byte]$_ }); Set-OptiRegistry -Path $r.path -Name $r.name -Value $v -Type Binary }
                    'DWord'       { Set-OptiRegistry -Path $r.path -Name $r.name -Value ([int]$v) -Type DWord }
                    'QWord'       { Set-OptiRegistry -Path $r.path -Name $r.name -Value ([int64]$v) -Type QWord }
                    'ExpandString' { Set-OptiRegistry -Path $r.path -Name $r.name -Value ([string]$v) -Type ExpandString }
                    'MultiString' {
                        if (-not (Test-Path -LiteralPath $r.path)) { New-Item -Path $r.path -Force | Out-Null }
                        Set-ItemProperty -LiteralPath $r.path -Name $r.name -Value ([string[]]@($v)) -Type MultiString -ErrorAction Stop
                    }
                    default       { Set-OptiRegistry -Path $r.path -Name $r.name -Value ([string]$v) -Type String }
                }
            }
            $ok++
        } catch {
            $fail++
            Write-OptiLog -Message "Restore failed for $($r.path)\$($r.name): $($_.Exception.Message)" -Level Warn
        }
    }

    foreach ($s in @($snap.services)) {
        if (-not $s.installed) { continue }
        $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.service
        try {
            if ($null -ne $s.Start) { Set-OptiRegistry -Path $svcKey -Name 'Start' -Value ([int]$s.Start) -Type DWord }
            if ($null -ne $s.DelayedAutostart) { Set-OptiRegistry -Path $svcKey -Name 'DelayedAutostart' -Value ([int]$s.DelayedAutostart) -Type DWord }
            else { Remove-OptiRegistry -Path $svcKey -Name 'DelayedAutostart' }
            $ok++
        } catch {
            $fail++
            Write-OptiLog -Message "Service restore failed for $($s.service): $($_.Exception.Message)" -Level Warn
        }
    }

    if ($snap.power -and $snap.power.activeGuid) {
        $guid = [string]$snap.power.activeGuid
        try {
            $list = (& powercfg /list 2>$null) | Out-String
            if ($list -notmatch [regex]::Escape($guid)) {
                if ($snap.power.exportFile -and (Test-Path -LiteralPath $snap.power.exportFile)) {
                    & powercfg /import $snap.power.exportFile $guid 2>&1 | Out-Null
                    Write-OptiLog -Message "Re-imported power scheme $guid" -Level Info
                } else {
                    Write-OptiLog -Message "Original power scheme $guid is gone and no export file exists." -Level Warn
                }
            }
            & powercfg /setactive $guid 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-OptiLog -Message "Could not activate power scheme $guid" -Level Warn }
        } catch { Write-OptiLog -Message "Power scheme restore failed: $($_.Exception.Message)" -Level Warn }
    }

    Write-OptiLog -Message "Snapshot restored ($ok ok, $fail failed). Some changes need a sign-out or reboot." -Level Success
    return ($fail -eq 0)
}

function Invoke-OptiSafetyNet {
<#
.SYNOPSIS
Creates a restore point, state snapshot and hive export once per session.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($script:OptiSafetyNetDone) { return }
    if (-not $PSCmdlet.ShouldProcess('System', 'Run safety net (restore point, snapshot, hive export)')) { return }
    Write-OptiLog -Message 'Creating safety net (restore point, snapshot, hive export)...' -Level Info
    [void](New-OptiRestorePoint)
    [void](New-OptiStateSnapshot -Label 'safety-net')
    [void](Export-OptiRegistryHives)
    $script:OptiSafetyNetDone = $true
}
