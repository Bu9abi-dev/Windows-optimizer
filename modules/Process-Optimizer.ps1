# Process-Optimizer.ps1 - service trimming, drive/RAM detection, startup items. Functions only.

function Get-OptiServiceReport {
<#
.SYNOPSIS
Reports non-Xbox services from services.json with current status and startup type.
#>
    [CmdletBinding()]
    param()
    $cfg = Get-OptiConfig -Name services
    foreach ($s in @($cfg.services)) {
        if ($s.category -eq 'Xbox') { continue }
        $status = 'NotInstalled'
        $display = $s.service
        try {
            $svc = Get-Service -Name $s.service -ErrorAction Stop
            $status = [string]$svc.Status
            $display = $svc.DisplayName
        } catch { }
        [pscustomobject]@{
            Id = $s.id; Service = $s.service; DisplayName = $display; Status = $status
            CurrentStartup = (Get-OptiServiceStartup -Name $s.service)
            DefaultStartup = $s.default_startup; OptimizedStartup = $s.optimized_startup
            RiskLevel = $s.risk_level; Optional = [bool]$s.optional
        }
    }
}

function Invoke-OptiServiceOptimization {
<#
.SYNOPSIS
Applies (or with -Revert undoes) service optimizations; refuses protected services.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Ids, [switch]$Revert)
    $cfg = Get-OptiConfig -Name services
    $protected = @(Get-OptiProtectedServices)
    $items = @($cfg.services | Where-Object { $_.category -ne 'Xbox' })
    if ($Ids -and $Ids.Count -gt 0) { $items = @($items | Where-Object { $Ids -contains $_.id }) }
    else { $items = @($items | Where-Object { -not $_.optional }) }
    $action = 'Apply'
    if ($Revert) { $action = 'Undo' }
    $count = 0
    foreach ($it in $items) {
        if (-not $Revert -and ($protected -contains $it.service)) {
            Write-OptiLog -Message "Refusing to modify protected service $($it.service)" -Level Warn
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($it.service, "Service $action")) { continue }
        try { Invoke-OptiTweak -Id $it.id -Action $action | Out-Null; $count++ }
        catch { Write-OptiLog -Message "Service $($it.service) ($action) failed: $($_.Exception.Message)" -Level Warn }
    }
    return $count
}

function Get-OptiSvcHostThreshold {
<#
.SYNOPSIS
Returns the recommended SvcHostSplitThresholdInKB (installed RAM in KB).
#>
    [CmdletBinding()]
    param()
    $kb = $null
    try {
        $sum = (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum
        if ($sum) { $kb = [int64]($sum / 1KB) }
    } catch { }
    if (-not $kb) {
        try { $kb = [int64]((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1KB) }
        catch { Write-OptiLog -Message 'Could not detect RAM size.' -Level Warn; return $null }
    }
    return $kb
}

function Get-OptiDriveInfo {
<#
.SYNOPSIS
Detects system drive media type (SSD/HDD/NVMe) and RAM size, and whether SysMain could be turned off.
#>
    [CmdletBinding()]
    param()
    $media = 'Unknown'; $bus = 'Unknown'; $ramGB = $null
    try {
        $letter = ($env:SystemDrive).Substring(0, 1)
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Select-Object -First 1
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        if ($pd) { $media = [string]$pd.MediaType; $bus = [string]$pd.BusType }
    } catch { Write-OptiLog -Message "Drive detection failed: $($_.Exception.Message)" -Level Warn }
    $kb = Get-OptiSvcHostThreshold
    if ($kb) { $ramGB = [math]::Round($kb / 1MB, 1) }
    $isNvme = ($bus -eq 'NVMe')
    $isSsd = ($media -eq 'SSD') -or $isNvme
    $rec = $false
    if ($isSsd -and $null -ne $ramGB -and $ramGB -le 8) { $rec = $true }
    [pscustomobject]@{
        MediaType = $media; BusType = $bus; IsSSD = $isSsd; IsNVMe = $isNvme
        RAMGB = $ramGB; RecommendSysMainOff = $rec
    }
}

function Get-OptiStartupLocations {
<#
.SYNOPSIS
Returns the startup source definitions (Run keys and Startup folders) with matching StartupApproved keys.
#>
    [CmdletBinding()]
    param()
    $ap = '\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\'
    $run = '\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $folders = @()
    $userStartup = [Environment]::GetFolderPath('Startup')
    $commonStartup = [Environment]::GetFolderPath('CommonStartup')
    @(
        [pscustomobject]@{ Location = 'HKCU Run'; Kind = 'Key'; Source = 'HKCU:' + $run; Approved = 'HKCU:' + $ap + 'Run' },
        [pscustomobject]@{ Location = 'HKLM Run'; Kind = 'Key'; Source = 'HKLM:' + $run; Approved = 'HKLM:' + $ap + 'Run' },
        [pscustomobject]@{ Location = 'HKLM Run32'; Kind = 'Key'; Source = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:' + $ap + 'Run32' },
        [pscustomobject]@{ Location = 'User Startup'; Kind = 'Folder'; Source = $userStartup; Approved = 'HKCU:' + $ap + 'StartupFolder' },
        [pscustomobject]@{ Location = 'Common Startup'; Kind = 'Folder'; Source = $commonStartup; Approved = 'HKLM:' + $ap + 'StartupFolder' }
    )
}

function Get-OptiStartupItems {
<#
.SYNOPSIS
Lists startup entries from Run keys and Startup folders with their enabled state from StartupApproved.
#>
    [CmdletBinding()]
    param()
    foreach ($loc in (Get-OptiStartupLocations)) {
        $entries = @()
        try {
            if ($loc.Kind -eq 'Key') {
                if (Test-Path -LiteralPath $loc.Source) {
                    $p = Get-ItemProperty -LiteralPath $loc.Source -ErrorAction Stop
                    foreach ($prop in $p.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        $entries += [pscustomobject]@{ Name = $prop.Name; Command = [string]$prop.Value }
                    }
                }
            }
            elseif ($loc.Source -and (Test-Path -LiteralPath $loc.Source)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $loc.Source -File -Force -ErrorAction Stop)) {
                    if ($f.Name -ieq 'desktop.ini') { continue }
                    $entries += [pscustomobject]@{ Name = $f.Name; Command = $f.FullName }
                }
            }
        } catch { Write-OptiLog -Message "Cannot read startup source $($loc.Location): $($_.Exception.Message)" -Level Warn }
        foreach ($e in $entries) {
            $enabled = $true
            $bytes = Get-OptiRegistry -Path $loc.Approved -Name $e.Name
            if ($bytes -is [byte[]] -and $bytes.Length -gt 0) { $enabled = (($bytes[0] -band 1) -eq 0) -and ($bytes[0] -ne 3) }
            [pscustomobject]@{ Name = $e.Name; Location = $loc.Location; Command = $e.Command; Enabled = $enabled }
        }
    }
}

function Set-OptiStartupItem {
<#
.SYNOPSIS
Enables or disables a startup item by writing the StartupApproved flag exactly like Task Manager (the Run entry is never deleted).
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Location,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $targets = @(Get-OptiStartupItems | Where-Object { $_.Name -eq $Name })
    if ($Location) { $targets = @($targets | Where-Object { $_.Location -eq $Location }) }
    if ($targets.Count -eq 0) { Write-OptiLog -Message "Startup item not found: $Name" -Level Warn; return $false }
    $defs = @{}
    foreach ($l in (Get-OptiStartupLocations)) { $defs[$l.Location] = $l }
    $ok = $true
    foreach ($t in $targets) {
        $def = $defs[$t.Location]
        [byte[]]$data = New-Object byte[] 12
        if ($Enabled) { $data[0] = 2 }
        else {
            $data[0] = 3
            $ft = [BitConverter]::GetBytes([int64](Get-Date).ToFileTime())
            [Array]::Copy($ft, 0, $data, 4, 8)
        }
        $state = 'disable'
        if ($Enabled) { $state = 'enable' }
        if (-not $PSCmdlet.ShouldProcess("$Name ($($t.Location))", "Startup item: $state")) { continue }
        try {
            Set-OptiRegistry -Path $def.Approved -Name $Name -Value $data -Type Binary
            Write-OptiLog -Message "Startup item '$Name' ($($t.Location)): $state" -Level Info
        } catch {
            $ok = $false
            Write-OptiLog -Message "Could not change startup item '$Name': $($_.Exception.Message)" -Level Warn
        }
    }
    return $ok
}
