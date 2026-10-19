# Common.ps1 - shared helpers for StudentOpti. Function definitions only (no top-level side effects).

function Get-OptiRoot {
    [CmdletBinding()] param()
    if ($script:OptiRoot) { return [string]$script:OptiRoot }
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-OptiDataDir {
    [CmdletBinding()] param()
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'StudentOpti'
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Get-OptiBackupDir {
    [CmdletBinding()] param()
    $dir = Join-Path (Get-OptiDataDir) 'backups'
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Write-OptiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Success')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    $color = switch ($Level) { 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Success' { 'Green' } default { 'Gray' } }
    try { Write-Host $line -ForegroundColor $color } catch { }
    try {
        $logDir = Join-Path (Get-OptiDataDir) 'logs'
        [void][IO.Directory]::CreateDirectory($logDir)
        $file = Join-Path $logDir ('studentopti-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        [IO.File]::AppendAllText($file, $line + [Environment]::NewLine)
    } catch { }
    try {
        if ($global:OptiSync -and $global:OptiSync.Log) { $global:OptiSync.Log.Enqueue($line) }
    } catch { }
}

function Test-OptiAdmin {
    [CmdletBinding()] param()
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-OptiConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('tweaks', 'services', 'appx_bloat', 'presets')][string]$Name)
    if (-not $script:OptiConfigCache) { $script:OptiConfigCache = @{} }
    if ($script:OptiConfigCache.ContainsKey($Name)) { return $script:OptiConfigCache[$Name] }
    $path = Join-Path (Join-Path (Get-OptiRoot) 'config') ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path)) { throw "Config file not found: $path" }
    $raw = [IO.File]::ReadAllText($path)
    $obj = $raw | ConvertFrom-Json
    $script:OptiConfigCache[$Name] = $obj
    return $obj
}

function Get-OptiRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Set-OptiRegistry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()]$Value,
        [ValidateSet('String', 'DWord', 'QWord', 'Binary', 'ExpandString')][string]$Type = 'String'
    )
    if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "Set $Type = $Value")) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    switch ($Type) {
        'DWord' {
            # Allow unsigned values above Int32.MaxValue
            $n = [int64]$Value
            if ($n -gt [int]::MaxValue) { $n = $n - 4294967296 }
            $Value = [int]$n
        }
        'QWord' { $Value = [int64]$Value }
        'Binary' { $Value = [byte[]]@($Value | ForEach-Object { [byte]$_ }) }
        'String' { if ($null -eq $Value) { $Value = '' } else { $Value = [string]$Value } }
        'ExpandString' { $Value = [string]$Value }
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    Write-OptiLog "Registry set: $Path\$Name ($Type)" 'Info'
}

function Remove-OptiRegistry {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [string]$Name)
    if ($PSBoundParameters.ContainsKey('Name') -and $Name -ne $null -and $Name -ne '') {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $exists = $null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)
        if (-not $exists) { return }
        if ($PSCmdlet.ShouldProcess("$Path\$Name", 'Remove registry value')) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
            Write-OptiLog "Registry value removed: $Path\$Name" 'Info'
        }
    } else {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        if ($PSCmdlet.ShouldProcess($Path, 'Remove registry key')) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            Write-OptiLog "Registry key removed: $Path" 'Info'
        }
    }
}

function Test-OptiRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()]$Value
    )
    $cur = Get-OptiRegistry -Path $Path -Name $Name
    if ($null -eq $Value) { return ($null -eq $cur) }
    if ($null -eq $cur) { return $false }
    if ($cur -is [byte[]]) {
        $exp = [byte[]]@($Value | ForEach-Object { [byte]$_ })
        if ($cur.Length -ne $exp.Length) { return $false }
        for ($i = 0; $i -lt $cur.Length; $i++) { if ($cur[$i] -ne $exp[$i]) { return $false } }
        return $true
    }
    if ($cur -is [string]) { return ($cur -eq [string]$Value) }
    try { return ([int64]$cur -eq [int64]$Value) } catch { return ([string]$cur -eq [string]$Value) }
}

function Get-OptiProtectedServices {
    [CmdletBinding()] param()
    $list = @('BFE', 'CryptSvc', 'DcomLaunch', 'Dhcp', 'Dnscache', 'EventSystem', 'gpsvc', 'RpcSs', 'RpcEptMapper',
        'SecurityHealthService', 'SystemEventsBroker', 'WpnUserService', 'WinDefend', 'mpssvc', 'wuauserv', 'AppXSvc',
        'ClipSVC', 'LSM', 'Power', 'ProfSvc', 'Schedule', 'Winmgmt')
    try {
        $cfg = Get-OptiConfig -Name services
        if ($cfg -and $cfg.protected) { $list += @($cfg.protected) }
    } catch { }
    return [string[]]@($list | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-OptiServiceStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return 'NotInstalled' }
    $start = Get-OptiRegistry -Path $key -Name 'Start'
    if ($null -eq $start) { return 'NotInstalled' }
    switch ([int]$start) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 {
            $d = Get-OptiRegistry -Path $key -Name 'DelayedAutostart'
            if ($null -ne $d -and [int]$d -eq 1) { return 'AutomaticDelayed' }
            return 'Automatic'
        }
        3 { return 'Manual' }
        4 { return 'Disabled' }
        default { return 'Manual' }
    }
}

function Set-OptiServiceStartup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')][string]$StartupType,
        [switch]$StopIfDisabled,
        [switch]$IncludeUserInstances
    )
    if ((Get-OptiProtectedServices) -contains $Name -and ($StartupType -eq 'Manual' -or $StartupType -eq 'Disabled')) {
        throw "Service '$Name' is protected and cannot be set to $StartupType."
    }
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $targets = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath "$base\$Name") { [void]$targets.Add($Name) }
    if ($IncludeUserInstances) {
        $kids = Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like ($Name + '_*') }
        foreach ($k in $kids) { [void]$targets.Add($k.PSChildName) }
    }
    if ($targets.Count -eq 0) {
        Write-OptiLog "Service '$Name' not installed; skipped." 'Warn'
        return
    }
    $start = 3; $delayed = 0
    switch ($StartupType) {
        'Automatic' { $start = 2; $delayed = 0 }
        'AutomaticDelayed' { $start = 2; $delayed = 1 }
        'Manual' { $start = 3; $delayed = 0 }
        'Disabled' { $start = 4; $delayed = 0 }
    }
    foreach ($t in $targets) {
        if (-not $PSCmdlet.ShouldProcess($t, "Set startup type to $StartupType")) { continue }
        $key = "$base\$t"
        Set-OptiRegistry -Path $key -Name 'Start' -Value $start -Type DWord
        if ($delayed -eq 1) {
            Set-OptiRegistry -Path $key -Name 'DelayedAutostart' -Value 1 -Type DWord
        } else {
            if ($null -ne (Get-OptiRegistry -Path $key -Name 'DelayedAutostart')) {
                Set-OptiRegistry -Path $key -Name 'DelayedAutostart' -Value 0 -Type DWord
            }
        }
        Write-OptiLog "Service $t startup -> $StartupType" 'Info'
        if ($StartupType -eq 'Disabled' -and $StopIfDisabled) {
            try {
                $svc = Get-Service -Name $t -ErrorAction Stop
                if ($svc.Status -ne 'Stopped') { Stop-Service -Name $t -Force -ErrorAction Stop }
            } catch { Write-OptiLog "Could not stop service ${t}: $($_.Exception.Message)" 'Warn' }
        }
    }
}

function Invoke-OptiScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code)
    & ([scriptblock]::Create($Code))
}

function Find-OptiItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    foreach ($src in @('tweaks', 'services')) {
        $cfg = Get-OptiConfig -Name $src
        $list = if ($src -eq 'tweaks') { $cfg.tweaks } else { $cfg.services }
        foreach ($it in @($list)) { if ($it.id -eq $Id) { return $it } }
    }
    return $null
}

function Invoke-OptiTweak {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Check', 'Apply', 'Undo')][string]$Action
    )
    $item = Find-OptiItem -Id $Id
    if (-not $item) { throw "Unknown tweak id: $Id" }
    switch ($Action) {
        'Check' {
            try {
                $r = @(Invoke-OptiScript -Code $item.check_script)
                if ($r.Count -eq 0) { return $false }
                return [bool]$r[$r.Count - 1]
            } catch {
                Write-OptiLog "Check failed for ${Id}: $($_.Exception.Message)" 'Warn'
                return $false
            }
        }
        'Apply' {
            if (-not $PSCmdlet.ShouldProcess($item.name, 'Apply')) { return }
            Write-OptiLog "Applying: $($item.name) [$Id]" 'Info'
            try { Invoke-OptiScript -Code $item.apply_script | Out-Null; Write-OptiLog "Applied: $($item.name)" 'Success' }
            catch { Write-OptiLog "Apply failed for ${Id}: $($_.Exception.Message)" 'Error'; throw }
        }
        'Undo' {
            if (-not $PSCmdlet.ShouldProcess($item.name, 'Undo')) { return }
            Write-OptiLog "Reverting: $($item.name) [$Id]" 'Info'
            try { Invoke-OptiScript -Code $item.undo_script | Out-Null; Write-OptiLog "Reverted: $($item.name)" 'Success' }
            catch { Write-OptiLog "Undo failed for ${Id}: $($_.Exception.Message)" 'Error'; throw }
        }
    }
}

function Invoke-OptiPreset {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id, [switch]$SkipSafetyNet)
    $preset = $null
    foreach ($p in @((Get-OptiConfig -Name presets).presets)) { if ($p.id -eq $Id) { $preset = $p } }
    if (-not $preset) { throw "Unknown preset: $Id" }
    # No ShouldProcess gate here: each step honours -WhatIf itself, so a dry run previews every change.
    Write-OptiLog "Running preset: $($preset.name)" 'Info'

    if (-not $SkipSafetyNet) {
        if (Get-Command Invoke-OptiSafetyNet -ErrorAction SilentlyContinue) {
            try { Invoke-OptiSafetyNet } catch { Write-OptiLog "Safety net failed: $($_.Exception.Message)" 'Warn' }
        } else { Write-OptiLog 'Invoke-OptiSafetyNet unavailable; continuing without backup.' 'Warn' }
    }

    $action = 'Apply'
    $tweakIds = @($preset.tweaks)
    $svcIds = @($preset.services)
    if ($preset.undo_all) {
        $action = 'Undo'
        $tweakIds = @((Get-OptiConfig -Name tweaks).tweaks | ForEach-Object { $_.id })
        $svcIds = @((Get-OptiConfig -Name services).services | ForEach-Object { $_.id })
    }

    foreach ($tid in $tweakIds) {
        if (-not $tid) { continue }
        try { Invoke-OptiTweak -Id $tid -Action $action } catch { Write-OptiLog "Tweak $tid failed: $($_.Exception.Message)" 'Warn' }
    }

    if ($svcIds.Count -gt 0) {
        if (Get-Command Invoke-OptiServiceOptimization -ErrorAction SilentlyContinue) {
            try {
                if ($preset.undo_all) { Invoke-OptiServiceOptimization -Ids $svcIds -Revert }
                else { Invoke-OptiServiceOptimization -Ids $svcIds }
            } catch { Write-OptiLog "Service optimization failed: $($_.Exception.Message)" 'Warn' }
        } else {
            foreach ($sid in $svcIds) {
                if (-not $sid) { continue }
                try { Invoke-OptiTweak -Id $sid -Action $action } catch { Write-OptiLog "Service $sid failed: $($_.Exception.Message)" 'Warn' }
            }
        }
    }

    if ($preset.remove_appx) {
        if (Get-Command Remove-OptiBloatApps -ErrorAction SilentlyContinue) {
            try { Remove-OptiBloatApps } catch { Write-OptiLog "Appx removal failed: $($_.Exception.Message)" 'Warn' }
        } else { Write-OptiLog 'Remove-OptiBloatApps unavailable; skipped.' 'Warn' }
    }

    if ($preset.xbox_mode) {
        if (Get-Command Set-XboxMode -ErrorAction SilentlyContinue) {
            try { Set-XboxMode -Mode ([string]$preset.xbox_mode) } catch { Write-OptiLog "Xbox mode failed: $($_.Exception.Message)" 'Warn' }
        } else { Write-OptiLog 'Set-XboxMode unavailable; skipped.' 'Warn' }
    }

    if ($preset.power_profile) {
        if (Get-Command Set-OptiPowerProfile -ErrorAction SilentlyContinue) {
            try { Set-OptiPowerProfile -Profile ([string]$preset.power_profile) } catch { Write-OptiLog "Power profile failed: $($_.Exception.Message)" 'Warn' }
        } else { Write-OptiLog 'Set-OptiPowerProfile unavailable; skipped.' 'Warn' }
    }

    if ($preset.cleanup) {
        if (Get-Command Clear-OptiTempFiles -ErrorAction SilentlyContinue) {
            try { Clear-OptiTempFiles } catch { Write-OptiLog "Cleanup failed: $($_.Exception.Message)" 'Warn' }
        } else { Write-OptiLog 'Clear-OptiTempFiles unavailable; skipped.' 'Warn' }
    }

    Write-OptiLog "Preset complete: $($preset.name)" 'Success'
}
