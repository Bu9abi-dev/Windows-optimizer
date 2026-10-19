# Responsiveness-Engine.ps1 - power profiles, Explorer restart, UI latency tweaks. Functions only.

function Get-OptiActivePowerPlan {
<#
.SYNOPSIS
Returns the active power plan name and GUID parsed from powercfg /getactivescheme.
#>
    [CmdletBinding()]
    param()
    try {
        $out = (& powercfg /getactivescheme 2>$null) | Out-String
        $m = [regex]::Match($out, '(?<g>[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s*\((?<n>[^)]*)\)')
        if ($m.Success) { return [pscustomobject]@{ Name = $m.Groups['n'].Value.Trim(); Guid = $m.Groups['g'].Value.ToLower() } }
    } catch { }
    return $null
}

function Invoke-OptiPowerCfg {
<#
.SYNOPSIS
Runs powercfg with the given arguments, returns output text, logs a warning on non-zero exit.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    try {
        $out = (& powercfg @Arguments 2>&1) | Out-String
        if ($LASTEXITCODE -ne 0) { Write-OptiLog -Message ("powercfg {0} failed: {1}" -f ($Arguments -join ' '), $out.Trim()) -Level Warn }
        return $out
    } catch {
        Write-OptiLog -Message ("powercfg {0} error: {1}" -f ($Arguments -join ' '), $_.Exception.Message) -Level Warn
        return ''
    }
}

function Set-OptiPowerProfile {
<#
.SYNOPSIS
Switches the power plan to a Study (battery), Performance (plugged-in) or Balanced (Windows defaults) profile.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Study', 'Performance', 'Balanced')][string]$Profile)
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if (-not $PSCmdlet.ShouldProcess("Power plan", "Switch to $Profile profile")) { return $false }
    try {
        switch ($Profile) {
            'Study' {
                [void](Invoke-OptiPowerCfg '/setactive' $balanced)
                [void](Invoke-OptiPowerCfg '/setdcvalueindex' $balanced 'SUB_PROCESSOR' 'PERFBOOSTMODE' '0')
                [void](Invoke-OptiPowerCfg '/setdcvalueindex' $balanced 'SUB_PCIEXPRESS' 'ASPM' '2')
                [void](Invoke-OptiPowerCfg '/setdcvalueindex' $balanced 'SUB_PROCESSOR' 'SYSCOOLPOL' '0')
                [void](Invoke-OptiPowerCfg '/setdcvalueindex' $balanced 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' '90')
                [void](Invoke-OptiPowerCfg '/setactive' $balanced)
                Write-OptiLog -Message 'Study profile active: Balanced plan, turbo off and 90% max CPU on battery, max PCIe power saving on battery.' -Level Success
            }
            'Performance' {
                $guid = $null
                $list = Invoke-OptiPowerCfg '/list'
                foreach ($line in ($list -split "`n")) {
                    if ($line -match '(?<g>[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})' -and ($line -match $ultimate -or $line -match 'Ultimate Performance')) {
                        $guid = $Matches['g'].ToLower(); break
                    }
                }
                if (-not $guid) {
                    $dup = Invoke-OptiPowerCfg '-duplicatescheme' $ultimate
                    $m = [regex]::Match($dup, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
                    if ($m.Success) { $guid = $m.Value.ToLower() }
                }
                if (-not $guid) {
                    Write-OptiLog -Message 'Ultimate Performance unavailable; falling back to High Performance.' -Level Warn
                    $guid = $high
                }
                [void](Invoke-OptiPowerCfg '/setacvalueindex' $guid 'SUB_PCIEXPRESS' 'ASPM' '0')
                [void](Invoke-OptiPowerCfg '/setactive' $guid)
                Write-OptiLog -Message 'Performance profile active. Meant for plugged-in use; it will drain the battery faster.' -Level Success
            }
            'Balanced' {
                [void](Invoke-OptiPowerCfg '/setactive' $balanced)
                foreach ($s in @(
                    @('SUB_PROCESSOR', 'PERFBOOSTMODE', '2', '2'),
                    @('SUB_PCIEXPRESS', 'ASPM', '1', '2'),
                    @('SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100', '100'),
                    @('SUB_PROCESSOR', 'SYSCOOLPOL', '1', '0')
                )) {
                    [void](Invoke-OptiPowerCfg '/setacvalueindex' $balanced $s[0] $s[1] $s[2])
                    [void](Invoke-OptiPowerCfg '/setdcvalueindex' $balanced $s[0] $s[1] $s[3])
                }
                [void](Invoke-OptiPowerCfg '/setactive' $balanced)
                Write-OptiLog -Message 'Balanced profile active (Windows Balanced defaults restored for boost mode, ASPM, max CPU state, cooling policy).' -Level Success
            }
        }
        return $true
    }
    catch {
        Write-OptiLog -Message "Power profile change failed: $($_.Exception.Message)" -Level Warn
        return $false
    }
}

function Restart-OptiExplorer {
<#
.SYNOPSIS
Restarts Windows Explorer so shell tweaks take effect.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('explorer.exe', 'Restart')) { return }
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-OptiLog -Message 'Explorer restarted.' -Level Info
    } catch { Write-OptiLog -Message "Explorer restart failed: $($_.Exception.Message)" -Level Warn }
}

function Set-OptiResponsiveness {
<#
.SYNOPSIS
Applies or undoes the UI responsiveness tweaks (menu delay, shutdown timeouts, End Task, classic menu, transparency, visual effects).
#>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Enable')]
    param(
        [Parameter(ParameterSetName = 'Enable')][switch]$Enable,
        [Parameter(ParameterSetName = 'Disable', Mandatory)][switch]$Disable
    )
    $action = 'Apply'
    if ($Disable) { $action = 'Undo' }
    foreach ($id in 'menu_show_delay', 'shutdown_timeouts', 'taskbar_end_task', 'classic_context_menu', 'transparency', 'visual_effects') {
        if (-not $PSCmdlet.ShouldProcess($id, "Responsiveness: $action")) { continue }
        try { Invoke-OptiTweak -Id $id -Action $action | Out-Null }
        catch { Write-OptiLog -Message "Tweak '$id' ($action) failed: $($_.Exception.Message)" -Level Warn }
    }
}
