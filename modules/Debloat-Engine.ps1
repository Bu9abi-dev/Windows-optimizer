# Debloat-Engine.ps1 - Appx removal/restore, temp cleanup, AI feature toggles. Functions only.

function Test-OptiAppxProtected {
<#
.SYNOPSIS
Returns $true when a package name matches the protected whitelist or an Xbox package pattern.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-OptiConfig -Name appx_bloat
    foreach ($p in @($cfg.protected_whitelist)) { if ($p -and $Name -like $p) { return $true } }
    foreach ($x in @($cfg.xbox)) {
        if ($x.pattern -and $Name -like $x.pattern) { return $true }
        if ($x.name -and $Name -eq $x.name) { return $true }
    }
    return $false
}

function Get-OptiBloatApps {
<#
.SYNOPSIS
Lists installed Appx packages that match safe_to_remove, with a Protected flag.
#>
    [CmdletBinding()]
    param()
    $cfg = Get-OptiConfig -Name appx_bloat
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) }
    catch { Write-OptiLog -Message "Get-AppxPackage failed: $($_.Exception.Message)" -Level Warn; return @() }
    $result = New-Object System.Collections.ArrayList
    $done = @{}
    foreach ($e in @($cfg.safe_to_remove)) {
        foreach ($p in $pkgs) {
            if ($p.Name -like $e.pattern -and -not $done.ContainsKey($p.PackageFullName)) {
                $done[$p.PackageFullName] = $true
                [void]$result.Add([pscustomobject]@{
                    Name = $p.Name; Label = $e.name; Category = $e.category; Description = $e.description
                    PackageFullName = $p.PackageFullName; InstallLocation = $p.InstallLocation
                    Protected = (Test-OptiAppxProtected -Name $p.Name)
                })
            }
        }
    }
    return @($result)
}

function Remove-OptiBloatApps {
<#
.SYNOPSIS
Removes bloat Appx packages (current user by default, -AllUsers also removes provisioned copies); never touches protected or Xbox apps.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Names, [switch]$AllUsers)
    if (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue) { Assert-OptiSafetyNet }
    $apps = @(Get-OptiBloatApps)
    if ($Names -and $Names.Count -gt 0) {
        $apps = @($apps | Where-Object {
            $a = $_; $hit = $false
            foreach ($n in $Names) { if ($a.Name -like $n -or $a.Label -like $n) { $hit = $true } }
            $hit
        })
    }
    $recFile = Join-Path (Get-OptiBackupDir) 'removed_apps.json'
    $records = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $recFile) {
        try { foreach ($r in @((Get-Content -LiteralPath $recFile -Raw | ConvertFrom-Json))) { if ($r) { [void]$records.Add($r) } } } catch { }
    }
    $removed = 0
    foreach ($a in $apps) {
        if ($a.Protected -or (Test-OptiAppxProtected -Name $a.Name)) {
            Write-OptiLog -Message "Refusing to remove protected package: $($a.Name)" -Level Warn
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($a.PackageFullName, 'Remove Appx package')) { continue }
        try {
            [void]$records.Add([pscustomobject]@{
                Name = $a.Name; PackageFullName = $a.PackageFullName; InstallLocation = $a.InstallLocation
                Removed = (Get-Date).ToString('o'); AllUsers = [bool]$AllUsers
            })
            if ($AllUsers) {
                Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop
                try {
                    Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $a.Name } |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null }
                } catch { Write-OptiLog -Message "Provisioned removal failed for $($a.Name): $($_.Exception.Message)" -Level Warn }
            }
            else {
                Remove-AppxPackage -Package $a.PackageFullName -ErrorAction Stop
            }
            $removed++
            Write-OptiLog -Message "Removed $($a.Name)" -Level Info
        } catch {
            [void]$records.RemoveAt($records.Count - 1)
            Write-OptiLog -Message "Could not remove $($a.Name): $($_.Exception.Message)" -Level Warn
        }
    }
    if ($removed -gt 0) {
        $json = ConvertTo-Json -InputObject @($records) -Depth 4
        [IO.File]::WriteAllText($recFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-OptiLog -Message "Debloat finished: $removed package(s) removed." -Level Success
    return $removed
}

function Restore-OptiRemovedApps {
<#
.SYNOPSIS
Re-registers previously removed Appx packages from their payload, or points the user to the Microsoft Store.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $recFile = Join-Path (Get-OptiBackupDir) 'removed_apps.json'
    if (-not (Test-Path -LiteralPath $recFile)) { Write-OptiLog -Message 'No removed-apps record found.' -Level Info; return 0 }
    $records = @()
    try { $records = @((Get-Content -LiteralPath $recFile -Raw | ConvertFrom-Json)) } catch { Write-OptiLog -Message 'removed_apps.json unreadable.' -Level Warn; return 0 }
    $remaining = New-Object System.Collections.ArrayList
    $restored = 0
    $winApps = Join-Path $env:ProgramFiles 'WindowsApps'
    foreach ($r in $records) {
        if (-not $r) { continue }
        $manifest = $null
        if ($r.InstallLocation) {
            $m = Join-Path $r.InstallLocation 'AppxManifest.xml'
            if (Test-Path -LiteralPath $m) { $manifest = $m }
        }
        if (-not $manifest -and (Test-Path -LiteralPath $winApps)) {
            try {
                $dir = Get-ChildItem -LiteralPath $winApps -Directory -Filter ($r.Name + '_*') -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 1
                if ($dir) {
                    $m = Join-Path $dir.FullName 'AppxManifest.xml'
                    if (Test-Path -LiteralPath $m) { $manifest = $m }
                }
            } catch { }
        }
        if ($manifest) {
            if ($PSCmdlet.ShouldProcess($r.Name, 'Re-register Appx package')) {
                try {
                    Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                    $restored++
                    Write-OptiLog -Message "Restored $($r.Name)" -Level Success
                    continue
                } catch { Write-OptiLog -Message "Re-register failed for $($r.Name): $($_.Exception.Message)" -Level Warn }
            }
            [void]$remaining.Add($r)
        }
        else {
            Write-OptiLog -Message "No local payload for $($r.Name). Reinstall it from the Microsoft Store." -Level Warn
            if (-not $WhatIfPreference) {
                try { Start-Process ('ms-windows-store://search/?query=' + [uri]::EscapeDataString([string]$r.Name)) } catch { }
            }
            [void]$remaining.Add($r)
        }
    }
    if (-not $WhatIfPreference -and $restored -gt 0) {
        $json = ConvertTo-Json -InputObject @($remaining) -Depth 4
        [IO.File]::WriteAllText($recFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $restored
}

function Get-OptiFolderSizeBytes {
<#
.SYNOPSIS
Returns the total size in bytes of files under a folder (0 when missing).
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Clear-OptiTempFiles {
<#
.SYNOPSIS
Deletes temp files, the Windows Update download cache and optionally Prefetch, and reports MB freed.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$IncludePrefetch)
    $targets = New-Object System.Collections.ArrayList
    if ($env:TEMP) { [void]$targets.Add($env:TEMP) }
    if ($env:WINDIR) {
        [void]$targets.Add((Join-Path $env:WINDIR 'Temp'))
        [void]$targets.Add((Join-Path $env:WINDIR 'SoftwareDistribution\Download'))
        if ($IncludePrefetch) { [void]$targets.Add((Join-Path $env:WINDIR 'Prefetch')) }
    }
    $total = [int64]0
    $restart = @()
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        if (-not $PSCmdlet.ShouldProcess($t, 'Delete contents')) { $total += (Get-OptiFolderSizeBytes -Path $t); continue }
        $isWu = ($t -like '*SoftwareDistribution*')
        if ($isWu) {
            foreach ($sn in 'wuauserv', 'bits') {
                try {
                    $svc = Get-Service -Name $sn -ErrorAction Stop
                    if ($svc.Status -eq 'Running') { Stop-Service -Name $sn -Force -ErrorAction Stop; $restart += $sn }
                } catch { Write-OptiLog -Message "Could not stop $sn : $($_.Exception.Message)" -Level Warn }
            }
        }
        $before = Get-OptiFolderSizeBytes -Path $t
        Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        $after = Get-OptiFolderSizeBytes -Path $t
        $total += [math]::Max([int64]0, $before - $after)
        if ($isWu) {
            foreach ($sn in $restart) {
                try { Start-Service -Name $sn -ErrorAction Stop } catch { Write-OptiLog -Message "Could not restart $sn : $($_.Exception.Message)" -Level Warn }
            }
            $restart = @()
        }
    }
    $mb = [math]::Round($total / 1MB, 1)
    if ($WhatIfPreference) { Write-OptiLog -Message "Cleanup (dry run): about $mb MB could be freed." -Level Info }
    else { Write-OptiLog -Message "Cleanup freed $mb MB." -Level Success }
    return $mb
}

function Set-OptiAIFeatures {
<#
.SYNOPSIS
Disables or re-enables Copilot, Recall, Widgets and the WSAIFabric service via the shared tweak definitions.
#>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Disable')]
    param(
        [Parameter(ParameterSetName = 'Disable')][switch]$Disable,
        [Parameter(ParameterSetName = 'Enable', Mandatory)][switch]$Enable
    )
    $action = 'Apply'
    if ($Enable) { $action = 'Undo' }
    foreach ($id in 'copilot', 'recall', 'widgets', 'svc_wsaifabricsvc') {
        if (-not $PSCmdlet.ShouldProcess($id, "AI features: $action")) { continue }
        try { Invoke-OptiTweak -Id $id -Action $action | Out-Null }
        catch { Write-OptiLog -Message "AI tweak '$id' ($action) failed: $($_.Exception.Message)" -Level Warn }
    }
}
