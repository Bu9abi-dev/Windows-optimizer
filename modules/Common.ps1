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
        [Parameter(Position = 1)][ValidateSet('Info', 'Warn', 'Error', 'Success')][string]$Level = 'Info',
        [switch]$NoHost
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    if (-not $NoHost) {
        $color = switch ($Level) { 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Success' { 'Green' } default { 'DarkGray' } }
        $screen = '  ' + $Message
        if ($Level -eq 'Warn') { $screen = '  [WARN] ' + $Message }
        elseif ($Level -eq 'Error') { $screen = '  [ERROR] ' + $Message }
        try { Write-Host $screen -ForegroundColor $color } catch { }
    }
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
    param([Parameter(Mandatory)][ValidateSet('tweaks', 'services', 'tasks', 'appx_bloat', 'presets')][string]$Name)
    if (-not $script:OptiConfigCache) { $script:OptiConfigCache = @{} }
    if ($script:OptiConfigCache.ContainsKey($Name)) { return $script:OptiConfigCache[$Name] }
    $path = Join-Path (Join-Path (Get-OptiRoot) 'config') ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Name -eq 'tasks') {
            $empty = [pscustomobject]@{ version = 1; tasks = @() }
            $script:OptiConfigCache[$Name] = $empty
            return $empty
        }
        throw "Config file not found: $path"
    }
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
    if (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue) { Assert-OptiSafetyNet }
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
    $global:OptiChangesMade = $true
    Write-OptiLog "Registry set: $Path\$Name ($Type)" 'Info'
}

function Remove-OptiRegistry {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [string]$Name)
    if (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue) { Assert-OptiSafetyNet }
    if ($PSBoundParameters.ContainsKey('Name') -and $Name -ne $null -and $Name -ne '') {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $exists = $null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)
        if (-not $exists) { return }
        if ($PSCmdlet.ShouldProcess("$Path\$Name", 'Remove registry value')) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
            $global:OptiChangesMade = $true
            Write-OptiLog "Registry value removed: $Path\$Name" 'Info'
        }
    } else {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        if ($PSCmdlet.ShouldProcess($Path, 'Remove registry key')) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            $global:OptiChangesMade = $true
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
    if (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue) { Assert-OptiSafetyNet }
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
        $global:OptiChangesMade = $true
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
    foreach ($src in @('tweaks', 'services', 'tasks')) {
        $cfg = Get-OptiConfig -Name $src
        $list = @($cfg.$src)
        foreach ($it in $list) { if ($it.id -eq $Id) { return $it } }
    }
    return $null
}

# ---------------------------------------------------------------- result tracking
function Reset-OptiResults {
    [CmdletBinding()] param()
    $global:OptiResults = New-Object System.Collections.ArrayList
    $global:OptiChangesMade = $false
    $global:OptiSafetyStop = $false
    $global:OptiStartTime = Get-Date
}

function Add-OptiResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name,
        [string]$Action = 'Apply',
        [Parameter(Mandatory)][ValidateSet('Applied', 'Undone', 'Skipped', 'Failed', 'DryRun')][string]$Status,
        [string]$Message = ''
    )
    if ($null -eq $global:OptiResults) { $global:OptiResults = New-Object System.Collections.ArrayList }
    if (-not $Name) { $Name = $Id }
    $r = [pscustomobject]@{ Id = $Id; Name = $Name; Action = $Action; Status = $Status; Message = $Message; Time = (Get-Date) }
    [void]$global:OptiResults.Add($r)
    Write-OptiResultLine -Result $r
    return
}

function Get-OptiResults {
    [CmdletBinding()] param()
    if ($null -eq $global:OptiResults) { return @() }
    return @($global:OptiResults)
}

function Write-OptiResultLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    $tag = '[ OK ]'; $color = 'Green'
    switch ([string]$Result.Status) {
        'Undone'  { $tag = '[UNDO]'; $color = 'Cyan' }
        'Skipped' { $tag = '[SKIP]'; $color = 'DarkGray' }
        'Failed'  { $tag = '[FAIL]'; $color = 'Red' }
        'DryRun'  { $tag = '[DRY ]'; $color = 'Yellow' }
    }
    try {
        Write-Host $tag -ForegroundColor $color -NoNewline
        Write-Host (' ' + $Result.Name) -NoNewline
        if ($Result.Message) { Write-Host ('  ' + $Result.Message) -ForegroundColor DarkGray } else { Write-Host '' }
    } catch { }
    $lvl = 'Info'
    if ($Result.Status -eq 'Failed') { $lvl = 'Error' }
    Write-OptiLog -Message ('{0} {1} {2}: {3} {4}' -f $tag, $Result.Id, $Result.Action, $Result.Name, $Result.Message) -Level $lvl -NoHost
}

function Invoke-OptiTweak {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Check', 'Apply', 'Undo')][string]$Action
    )
    $item = Find-OptiItem -Id $Id
    if (-not $item) { throw "Unknown tweak id: $Id" }

    $doCheck = {
        try {
            $r = @(Invoke-OptiScript -Code $item.check_script)
            if ($r.Count -eq 0) { return $false }
            return [bool]$r[$r.Count - 1]
        } catch {
            Write-OptiLog -Message "Check failed for ${Id}: $($_.Exception.Message)" -Level Warn -NoHost
            return $false
        }
    }

    if ($Action -eq 'Check') { return (& $doCheck) }

    if ($global:OptiSafetyStop) { return }
    if (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue) {
        try { Assert-OptiSafetyNet }
        catch {
            $global:OptiSafetyStop = $true
            Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status Failed -Message $_.Exception.Message
            return
        }
    }

    $isApply = ($Action -eq 'Apply')
    $code = $item.undo_script
    $okStatus = 'Undone'
    if ($isApply) { $code = $item.apply_script; $okStatus = 'Applied' }
    $needsRestart = $false
    if ($item.PSObject.Properties['requires_restart'] -and $item.requires_restart -and [string]$item.requires_restart -ne 'none') { $needsRestart = $true }

    $before = [bool](& $doCheck)
    if ($isApply -and $before) { Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status Skipped -Message 'already applied'; return }
    if ((-not $isApply) -and (-not $before)) { Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status Skipped -Message 'already at default'; return }

    try {
        Write-OptiLog -Message "$Action : $($item.name) [$Id]" -Level Info -NoHost
        Invoke-OptiScript -Code $code | Out-Null
    } catch {
        Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status Failed -Message $_.Exception.Message
        return
    }
    if ($WhatIfPreference) {
        $msg = 'would apply'
        if (-not $isApply) { $msg = 'would revert' }
        Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status DryRun -Message $msg
        return
    }
    $global:OptiChangesMade = $true
    $after = [bool](& $doCheck)
    if ($isApply) { $verified = $after } else { $verified = (-not $after) }
    if ($verified) {
        $m = ''
        if ($needsRestart) { $m = 'takes effect after restart' }
        Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status $okStatus -Message $m
    } elseif ($needsRestart) {
        Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status $okStatus -Message 'takes effect after restart'
    } else {
        $m = 'check still false after apply'
        if (-not $isApply) { $m = 'check still true after undo' }
        Add-OptiResult -Id $Id -Name $item.name -Action $Action -Status Failed -Message $m
    }
}

function Get-OptiPresetPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preset)
    $tweakCfg = Get-OptiConfig -Name tweaks
    $svcCfg = Get-OptiConfig -Name services
    $taskCfg = Get-OptiConfig -Name tasks
    $tweakIds = New-Object System.Collections.ArrayList
    $svcIds = New-Object System.Collections.ArrayList
    $taskIds = New-Object System.Collections.ArrayList

    if ($Preset.undo_all) {
        foreach ($t in @($tweakCfg.tweaks)) { [void]$tweakIds.Add([string]$t.id) }
        foreach ($t in @($svcCfg.services)) { if ($t.category -ne 'Xbox') { [void]$svcIds.Add([string]$t.id) } }
        foreach ($t in @($taskCfg.tasks)) { [void]$taskIds.Add([string]$t.id) }
    } else {
        $explicit = @{}
        $addExplicit = {
            param($List, $Ids)
            foreach ($i in @($Ids)) {
                if ($i -and -not $List.Contains([string]$i)) { [void]$List.Add([string]$i) }
                if ($i) { $explicit[[string]$i] = $true }
            }
        }
        & $addExplicit $tweakIds $Preset.tweaks
        & $addExplicit $svcIds $Preset.services
        $presetTasks = @()
        if ($Preset.PSObject.Properties['tasks']) { $presetTasks = @($Preset.tasks) }
        & $addExplicit $taskIds $presetTasks
        $tiers = @()
        if ($Preset.PSObject.Properties['tiers']) { $tiers = @($Preset.tiers | Where-Object { $_ }) }
        if ($tiers.Count -gt 0) {
            $pick = {
                param($List, $Items, [bool]$SkipXbox)
                foreach ($it in @($Items)) {
                    if (-not $it.PSObject.Properties['tier']) { continue }
                    if ($tiers -notcontains [string]$it.tier) { continue }
                    if ($SkipXbox -and $it.category -eq 'Xbox') { continue }
                    $isOpt = $false
                    if ($it.PSObject.Properties['optional']) { $isOpt = [bool]$it.optional }
                    if ($isOpt -and -not $explicit.ContainsKey([string]$it.id)) { continue }
                    if (-not $List.Contains([string]$it.id)) { [void]$List.Add([string]$it.id) }
                }
            }
            & $pick $tweakIds $tweakCfg.tweaks $false
            & $pick $svcIds $svcCfg.services $true
            & $pick $taskIds $taskCfg.tasks $false
        }
    }
    [pscustomobject]@{
        TweakIds = @($tweakIds); ServiceIds = @($svcIds); TaskIds = @($taskIds)
    }
}

function Confirm-OptiSafetyNet {
    # Mandatory gate: restore point + snapshot must exist before any change. Returns $true when safe to proceed.
    [CmdletBinding()] param()
    $reason = ''
    if (Get-Command Invoke-OptiSafetyNet -ErrorAction SilentlyContinue) {
        $ok = $false
        try { $ok = [bool](@(Invoke-OptiSafetyNet)[-1]) } catch { $ok = $false; $script:OptiSafetyNetError = $_.Exception.Message }
        if ($ok) { return $true }
        $reason = [string]$script:OptiSafetyNetError
    } else {
        $reason = 'the backup module is not loaded.'
    }
    $global:OptiSafetyStop = $true
    $bar = '+' + ('-' * 70) + '+'
    Write-Host ''
    Write-Host $bar -ForegroundColor Red
    Write-Host '|  SAFETY STOP - nothing was changed' -ForegroundColor Red
    Write-Host ('|  Reason: ' + $reason) -ForegroundColor Red
    Write-Host '|  A restore point is required before any change.' -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
    Write-Host ''
    return $false
}

function Write-OptiSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    try { Write-Host ''; Write-Host ('== ' + $Title + ' ==') -ForegroundColor Cyan } catch { }
}

function Invoke-OptiStep {
    # Runs a one-off phase (apps, xbox, power, cleanup) and records one result for it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Code)
    try {
        & $Code | Out-Null
        if ($WhatIfPreference) { Add-OptiResult -Id $Id -Name $Name -Status DryRun -Message 'would run' }
        else { $global:OptiChangesMade = $true; Add-OptiResult -Id $Id -Name $Name -Status Applied }
    } catch {
        Add-OptiResult -Id $Id -Name $Name -Status Failed -Message $_.Exception.Message
    }
}

function Invoke-OptiPreset {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id, [switch]$SkipSafetyNet)
    $preset = $null
    foreach ($p in @((Get-OptiConfig -Name presets).presets)) { if ($p.id -eq $Id) { $preset = $p } }
    if (-not $preset) { throw "Unknown preset: $Id" }
    # No ShouldProcess gate here: each step honours -WhatIf itself, so a dry run previews every change.
    Write-Host ''
    Write-Host ('Running preset: ' + $preset.name) -ForegroundColor White
    Write-OptiLog -Message "Running preset: $($preset.name)" -Level Info -NoHost

    # The restore point is mandatory; -SkipSafetyNet is accepted for compatibility but cannot bypass the gate.
    Write-OptiSection 'Safety net'
    if (-not (Confirm-OptiSafetyNet)) { return }
    if (-not $WhatIfPreference) { Write-Host '  Safety net ready' -ForegroundColor Green }

    $action = 'Apply'
    if ($preset.undo_all) { $action = 'Undo' }
    $plan = Get-OptiPresetPlan -Preset $preset

    $phases = @(
        @{ Title = 'Tweaks'; Ids = $plan.TweakIds },
        @{ Title = 'Services'; Ids = $plan.ServiceIds },
        @{ Title = 'Scheduled tasks'; Ids = $plan.TaskIds }
    )
    foreach ($ph in $phases) {
        $ids = @($ph.Ids)
        Write-OptiSection ('{0} ({1})' -f $ph.Title, $ids.Count)
        foreach ($tid in $ids) {
            if (-not $tid) { continue }
            if ($global:OptiSafetyStop) { break }
            try { Invoke-OptiTweak -Id $tid -Action $action }
            catch { Add-OptiResult -Id $tid -Action $action -Status Failed -Message $_.Exception.Message }
        }
    }

    if ($preset.remove_appx) {
        Write-OptiSection 'Apps'
        if (Get-Command Remove-OptiBloatApps -ErrorAction SilentlyContinue) {
            Invoke-OptiStep -Id 'remove_appx' -Name 'Remove bloat apps' -Code { Remove-OptiBloatApps }
        } else { Write-OptiLog 'Remove-OptiBloatApps unavailable; skipped.' 'Warn' }
    }

    if ($preset.xbox_mode) {
        Write-OptiSection 'Xbox'
        if (Get-Command Set-XboxMode -ErrorAction SilentlyContinue) {
            $xm = [string]$preset.xbox_mode
            Invoke-OptiStep -Id 'xbox_mode' -Name ('Xbox mode: ' + $xm) -Code { Set-XboxMode -Mode $xm }
        } else { Write-OptiLog 'Set-XboxMode unavailable; skipped.' 'Warn' }
    }

    if ($preset.power_profile) {
        Write-OptiSection 'Power'
        if (Get-Command Set-OptiPowerProfile -ErrorAction SilentlyContinue) {
            $pp = [string]$preset.power_profile
            Invoke-OptiStep -Id 'power_profile' -Name ('Power profile: ' + $pp) -Code { Set-OptiPowerProfile -Profile $pp }
        } else { Write-OptiLog 'Set-OptiPowerProfile unavailable; skipped.' 'Warn' }
    }

    $maint = @()
    if ($preset.PSObject.Properties['maintenance']) { $maint = @($preset.maintenance | Where-Object { $_ }) }
    if ($maint.Count -gt 0 -and (Get-Command Invoke-OptiMaintenance -ErrorAction SilentlyContinue)) {
        Write-OptiSection 'Disk, RAM & cleanup'
        try { Invoke-OptiMaintenance -Actions $maint }
        catch { Add-OptiResult -Id 'maintenance' -Name 'Disk, RAM & cleanup' -Status Failed -Message $_.Exception.Message }
    }

    if ($preset.cleanup) {
        Write-OptiSection 'Cleanup'
        if (Get-Command Clear-OptiTempFiles -ErrorAction SilentlyContinue) {
            Invoke-OptiStep -Id 'cleanup' -Name 'Clean temp files' -Code { Clear-OptiTempFiles }
        } else { Write-OptiLog 'Clear-OptiTempFiles unavailable; skipped.' 'Warn' }
    }

    Write-Host ''
    Write-OptiLog "Preset complete: $($preset.name)" 'Success'
}
