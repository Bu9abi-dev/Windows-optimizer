# Maintenance-Engine.ps1 - disk, RAM, cache and housekeeping maintenance for StudentOpti. Function definitions only.

# ---------------------------------------------------------------- internal helpers
function Write-OptiMaintResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name,
        [string]$Action = 'Apply',
        [Parameter(Mandatory)][ValidateSet('Applied', 'Undone', 'Skipped', 'Failed', 'DryRun')][string]$Status,
        [string]$Message = ''
    )
    if (-not $Name) { $Name = $Id }
    if ($Status -eq 'Applied' -or $Status -eq 'Undone') { $global:OptiChangesMade = $true }
    if (Get-Command Add-OptiResult -ErrorAction SilentlyContinue) {
        Add-OptiResult -Id $Id -Name $Name -Action $Action -Status $Status -Message $Message
    }
    else {
        $lvl = 'Info'
        if ($Status -eq 'Failed') { $lvl = 'Error' } elseif ($Status -eq 'Skipped') { $lvl = 'Warn' } elseif ($Status -eq 'Applied' -or $Status -eq 'Undone') { $lvl = 'Success' }
        Write-OptiLog -Message ('{0} [{1}] {2} {3}' -f $Name, $Status, $Action, $Message) -Level $lvl
    }
}

function Test-OptiMaintGate {
    # Safety gate: a restore point must exist before changing the system. Returns $false (and records Failed) when blocked.
    [CmdletBinding()]
    param([string]$Id = 'safety_net', [string]$Name = 'Safety net')
    if (-not (Get-Command Assert-OptiSafetyNet -ErrorAction SilentlyContinue)) { return $true }
    try { Assert-OptiSafetyNet; return $true }
    catch { Write-OptiMaintResult -Id $Id -Name $Name -Status Failed -Message $_.Exception.Message; return $false }
}

function Test-OptiMaintWindows {
    [CmdletBinding()] param()
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Invoke-OptiMaintNative {
    # Runs a native command, returns @{ Exit; Output }. Never throws.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File, [string[]]$ArgList = @())
    $out = @(); $code = -1
    try {
        $out = @(& $File @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $out = @($_.Exception.Message); $code = -1
    }
    return [pscustomobject]@{ Exit = $code; Output = $out }
}

function Get-OptiMaintFiles {
    [CmdletBinding()]
    param([string]$Path, [string]$Filter = '*', [int]$OlderThanDays = 0, [switch]$Recurse, [string[]]$ExcludeName = @())
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $items = @()
    try {
        if ($Recurse) { $items = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -File -Recurse -ErrorAction SilentlyContinue) }
        else { $items = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -File -ErrorAction SilentlyContinue) }
    } catch { return @() }
    if ($OlderThanDays -gt 0) {
        $cut = (Get-Date).AddDays(-$OlderThanDays)
        $items = @($items | Where-Object { $_.LastWriteTime -lt $cut })
    }
    if ($ExcludeName.Count -gt 0) {
        $items = @($items | Where-Object { $ExcludeName -notcontains $_.Name })
    }
    return $items
}

function Remove-OptiMaintFiles {
    # Deletes files (locked ones skipped silently). Returns bytes freed (or would-free when DryRun).
    [CmdletBinding()]
    param($Files, [bool]$DryRun, [string]$DirRoot)
    $total = [int64]0
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $len = [int64]0
        try { $len = [int64]$f.Length } catch { }
        if ($DryRun) { $total += $len; continue }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $total += $len
        } catch { }
    }
    if ($DirRoot -and -not $DryRun -and (Test-Path -LiteralPath $DirRoot)) {
        try {
            Get-ChildItem -LiteralPath $DirRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    try {
                        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
        } catch { }
    }
    return $total
}

function Clear-OptiMaintSpec {
    # Cleans a list of specs @{Path;Filter;Days;Recurse;Exclude;Dirs}. Returns bytes.
    [CmdletBinding()]
    param([object[]]$Specs, [bool]$DryRun)
    $sum = [int64]0
    foreach ($s in $Specs) {
        $filter = '*'; if ($s.Filter) { $filter = [string]$s.Filter }
        $days = 0; if ($s.Days) { $days = [int]$s.Days }
        $ex = @(); if ($s.Exclude) { $ex = @($s.Exclude) }
        $files = $null
        if ($s.Recurse) { $files = Get-OptiMaintFiles -Path $s.Path -Filter $filter -OlderThanDays $days -Recurse -ExcludeName $ex }
        else { $files = Get-OptiMaintFiles -Path $s.Path -Filter $filter -OlderThanDays $days -ExcludeName $ex }
        $dirRoot = $null; if ($s.Dirs) { $dirRoot = [string]$s.Path }
        $sum += (Remove-OptiMaintFiles -Files $files -DryRun $DryRun -DirRoot $dirRoot)
    }
    return $sum
}

function Complete-OptiMaintArea {
    [CmdletBinding()]
    param([string]$Id, [string]$Name, [int64]$Bytes, [bool]$DryRun)
    $mb = [math]::Round($Bytes / 1MB, 1)
    if ($DryRun) { Write-OptiMaintResult -Id $Id -Name $Name -Status DryRun -Message "would free about $mb MB"; return $mb }
    if ($Bytes -le 0) { Write-OptiMaintResult -Id $Id -Name $Name -Status Skipped -Message 'nothing to clean'; return 0 }
    Write-OptiMaintResult -Id $Id -Name $Name -Status Applied -Message "freed $mb MB"
    return $mb
}

function Get-OptiMaintDiskType {
    # Returns 'SSD', 'HDD' or 'Unspecified' for a drive letter.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    $media = ''; $bus = ''
    try {
        $disk = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Select-Object -First 1
        $pd = $null
        try { $pd = $disk | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1 } catch { $pd = $null }
        if ($pd) { $media = [string]$pd.MediaType; $bus = [string]$pd.BusType }
        else {
            $m = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
                Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
            if ($m) { $media = [string]$m.MediaType; $bus = [string]$m.BusType }
        }
    } catch { return 'Unspecified' }
    if ($media -eq '4' -or $media -eq 'SSD' -or $media -eq 'SCM') { return 'SSD' }
    if ($media -eq '3' -or $media -eq 'HDD') { return 'HDD' }
    if ($bus -eq '17' -or $bus -eq 'NVMe') { return 'SSD' }
    return 'Unspecified'
}

function Enable-OptiTrim {
    # Ensures TRIM (DisableDeleteNotify = 0). Records one result line.
    [CmdletBinding()]
    param([bool]$DryRun)
    $q = Invoke-OptiMaintNative -File 'fsutil' -ArgList @('behavior', 'query', 'DisableDeleteNotify')
    $joined = ($q.Output -join ' ')
    $ms = [regex]::Matches($joined, 'DisableDeleteNotify\s*=\s*(\d)')
    if ($q.Exit -ne 0 -or $ms.Count -eq 0) { Write-OptiMaintResult -Id 'trim' -Name 'TRIM support' -Status Failed -Message 'could not query TRIM state'; return }
    $off = $false
    foreach ($m in $ms) { if ($m.Groups[1].Value -eq '1') { $off = $true } }
    if (-not $off) { Write-OptiMaintResult -Id 'trim' -Name 'TRIM support' -Status Skipped -Message 'TRIM already enabled'; return }
    if ($DryRun) { Write-OptiMaintResult -Id 'trim' -Name 'TRIM support' -Status DryRun -Message 'would enable TRIM (DisableDeleteNotify = 0)'; return }
    $r = Invoke-OptiMaintNative -File 'fsutil' -ArgList @('behavior', 'set', 'DisableDeleteNotify', '0')
    if ($r.Exit -eq 0) { Write-OptiMaintResult -Id 'trim' -Name 'TRIM support' -Status Applied -Message 'TRIM enabled' }
    else { Write-OptiMaintResult -Id 'trim' -Name 'TRIM support' -Status Failed -Message (($r.Output -join ' ').Trim()) }
}

# ---------------------------------------------------------------- disk
function Optimize-OptiDisk {
<#
.SYNOPSIS
Optimizes every fixed volume the right way: SSD gets ReTrim, HDD gets defrag, unknown media is only analysed. Never defrags an SSD. Also ensures TRIM is on.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-OptiMaintGate -Id 'disk_optimize' -Name 'Optimize drives')) { return }
    try {
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'disk_optimize' -Name 'Optimize drives' -Status Skipped -Message 'Windows only'; return }
        $vols = @()
        try { $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }) }
        catch { Write-OptiMaintResult -Id 'disk_optimize' -Name 'Optimize drives' -Status Failed -Message $_.Exception.Message; return }
        $anySsd = $false
        foreach ($v in $vols) {
            $letter = [string]$v.DriveLetter
            $id = "disk_optimize_$letter"
            $type = Get-OptiMaintDiskType -DriveLetter $letter
            $name = "Optimize drive ${letter}: ($type)"
            try {
                if ($type -eq 'SSD') {
                    $anySsd = $true
                    if (-not $PSCmdlet.ShouldProcess("${letter}:", 'ReTrim')) { Write-OptiMaintResult -Id $id -Name $name -Status DryRun -Message 'would run ReTrim (no defrag on SSD)'; continue }
                    Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop
                    Write-OptiMaintResult -Id $id -Name $name -Status Applied -Message 'ReTrim completed'
                }
                elseif ($type -eq 'HDD') {
                    if (-not $PSCmdlet.ShouldProcess("${letter}:", 'Defragment')) { Write-OptiMaintResult -Id $id -Name $name -Status DryRun -Message 'would defragment (this can take a while)'; continue }
                    Write-OptiLog -Message "Defragmenting ${letter}: - this can take a long time..." -Level Info
                    Optimize-Volume -DriveLetter $letter -Defrag -Verbose -ErrorAction Stop
                    Write-OptiMaintResult -Id $id -Name $name -Status Applied -Message 'defragmentation completed'
                }
                else {
                    if (-not $PSCmdlet.ShouldProcess("${letter}:", 'Analyze')) { Write-OptiMaintResult -Id $id -Name $name -Status DryRun -Message 'would analyse only (unknown media type)'; continue }
                    Optimize-Volume -DriveLetter $letter -Analyze -ErrorAction SilentlyContinue
                    Write-OptiMaintResult -Id $id -Name $name -Status Skipped -Message 'unknown media type; not defragmenting'
                }
            } catch {
                Write-OptiMaintResult -Id $id -Name $name -Status Failed -Message $_.Exception.Message
            }
        }
        if ($vols.Count -eq 0) { Write-OptiMaintResult -Id 'disk_optimize' -Name 'Optimize drives' -Status Skipped -Message 'no fixed volumes found' }
        $dry = -not $PSCmdlet.ShouldProcess('TRIM setting', 'Ensure enabled')
        Enable-OptiTrim -DryRun $dry
    } catch {
        Write-OptiMaintResult -Id 'disk_optimize' -Name 'Optimize drives' -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- deep clean
function Clear-OptiDeepClean {
<#
.SYNOPSIS
Deep clean: temp files plus thumbnail/shader/WER/crash/log/Delivery Optimization caches and the recycle bin. One result line per area with MB freed.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    try {
        $dry = -not $PSCmdlet.ShouldProcess('temporary and cache files', 'Delete')
        $local = $env:LOCALAPPDATA; $pd = $env:ProgramData; $win = $env:WINDIR

        if (Get-Command Clear-OptiTempFiles -ErrorAction SilentlyContinue) {
            try {
                $r = @(Clear-OptiTempFiles)
                $mb = 0; if ($r.Count -gt 0) { $mb = $r[$r.Count - 1] }
                if ($dry) { Write-OptiMaintResult -Id 'clean_temp' -Name 'Temp files and update cache' -Status DryRun -Message "would free about $mb MB" }
                elseif ($mb -gt 0) { Write-OptiMaintResult -Id 'clean_temp' -Name 'Temp files and update cache' -Status Applied -Message "freed $mb MB" }
                else { Write-OptiMaintResult -Id 'clean_temp' -Name 'Temp files and update cache' -Status Skipped -Message 'nothing to clean' }
            } catch { Write-OptiMaintResult -Id 'clean_temp' -Name 'Temp files and update cache' -Status Failed -Message $_.Exception.Message }
        }

        $areas = @()
        if ($local) {
            $areas += ,@('clean_thumbs', 'Thumbnail and icon cache', @(
                @{ Path = (Join-Path $local 'Microsoft\Windows\Explorer'); Filter = 'thumbcache_*.db' },
                @{ Path = (Join-Path $local 'Microsoft\Windows\Explorer'); Filter = 'iconcache_*.db' }))
            $areas += ,@('clean_shader', 'GPU shader caches', @(
                @{ Path = (Join-Path $local 'D3DSCache'); Recurse = $true; Dirs = $true },
                @{ Path = (Join-Path $local 'NVIDIA\DXCache'); Recurse = $true; Dirs = $true },
                @{ Path = (Join-Path $local 'NVIDIA\GLCache'); Recurse = $true; Dirs = $true },
                @{ Path = (Join-Path $local 'AMD\DxCache'); Recurse = $true; Dirs = $true }))
        }
        if ($pd) {
            $areas += ,@('clean_wer', 'Windows Error Reporting queues', @(
                @{ Path = (Join-Path $pd 'Microsoft\Windows\WER\ReportArchive'); Recurse = $true; Dirs = $true },
                @{ Path = (Join-Path $pd 'Microsoft\Windows\WER\ReportQueue'); Recurse = $true; Dirs = $true },
                @{ Path = (Join-Path $pd 'Microsoft\Windows\WER\Temp'); Recurse = $true; Dirs = $true }))
        }
        $dumpSpecs = @()
        if ($local) { $dumpSpecs += @{ Path = (Join-Path $local 'CrashDumps'); Recurse = $true; Dirs = $true } }
        if ($win) {
            $dumpSpecs += @{ Path = (Join-Path $win 'Minidump'); Recurse = $true; Dirs = $true }
            $dumpSpecs += @{ Path = $win; Filter = 'MEMORY.DMP' }
        }
        if ($dumpSpecs.Count -gt 0) { $areas += ,@('clean_dumps', 'Crash dumps', $dumpSpecs) }
        if ($win) {
            $areas += ,@('clean_winlogs', 'Old Windows logs (7+ days)', @(
                @{ Path = (Join-Path $win 'Logs\CBS'); Filter = '*.log'; Days = 7; Exclude = @('CBS.log') },
                @{ Path = (Join-Path $win 'Logs\DISM'); Days = 7; Recurse = $true },
                @{ Path = (Join-Path $win 'Panther'); Filter = '*.log'; Days = 7; Recurse = $true }))
            $areas += ,@('clean_wulogs', 'Windows Update data store logs', @(
                @{ Path = (Join-Path $win 'SoftwareDistribution\DataStore\Logs'); Recurse = $true; Dirs = $true }))
        }
        foreach ($a in $areas) {
            try {
                $bytes = Clear-OptiMaintSpec -Specs $a[2] -DryRun $dry
                [void](Complete-OptiMaintArea -Id $a[0] -Name $a[1] -Bytes $bytes -DryRun $dry)
            } catch { Write-OptiMaintResult -Id $a[0] -Name $a[1] -Status Failed -Message $_.Exception.Message }
        }

        # Delivery Optimization cache
        try {
            $doDir = $null; if ($pd) { $doDir = Join-Path $pd 'Microsoft\Windows\DeliveryOptimization\Cache' }
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                $before = 0; if ($doDir) { $before = Get-OptiFolderSizeBytesSafe -Path $doDir }
                if (-not $dry) { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue }
                $after = 0; if ($doDir -and -not $dry) { $after = Get-OptiFolderSizeBytesSafe -Path $doDir }
                [void](Complete-OptiMaintArea -Id 'clean_do' -Name 'Delivery Optimization cache' -Bytes ([math]::Max(0, $before - $after)) -DryRun $dry)
            }
            else { Write-OptiMaintResult -Id 'clean_do' -Name 'Delivery Optimization cache' -Status Skipped -Message 'cmdlet not available' }
        } catch { Write-OptiMaintResult -Id 'clean_do' -Name 'Delivery Optimization cache' -Status Failed -Message $_.Exception.Message }

        # Recycle bin
        try {
            if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'clean_recycle' -Name 'Recycle Bin' -Status Skipped -Message 'Windows only' }
            else {
                $bytes = [int64]0
                foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                    $rb = Join-Path $d.Root '$Recycle.Bin'
                    $bytes += Get-OptiFolderSizeBytesSafe -Path $rb
                }
                if (-not $dry) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
                [void](Complete-OptiMaintArea -Id 'clean_recycle' -Name 'Recycle Bin' -Bytes $bytes -DryRun $dry)
            }
        } catch { Write-OptiMaintResult -Id 'clean_recycle' -Name 'Recycle Bin' -Status Failed -Message $_.Exception.Message }
    } catch {
        Write-OptiMaintResult -Id 'deep_clean' -Name 'Deep clean' -Status Failed -Message $_.Exception.Message
    }
}

function Get-OptiFolderSizeBytesSafe {
    [CmdletBinding()] param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64]0 }
        return [int64]$sum
    } catch { return [int64]0 }
}

# ---------------------------------------------------------------- browsers
function Clear-OptiBrowserCache {
<#
.SYNOPSIS
Clears only the disk caches of Edge, Chrome, Brave and Firefox. Cookies, history, passwords and Local Storage are never touched. Skips a browser that is running.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    try {
        $local = $env:LOCALAPPDATA
        if (-not $local) { Write-OptiMaintResult -Id 'browser_cache' -Name 'Browser caches' -Status Skipped -Message 'LOCALAPPDATA not set'; return }
        $browsers = @(
            @{ Id = 'edge'; Name = 'Microsoft Edge'; Proc = @('msedge'); Root = (Join-Path $local 'Microsoft\Edge\User Data'); Kind = 'Chromium' },
            @{ Id = 'chrome'; Name = 'Google Chrome'; Proc = @('chrome'); Root = (Join-Path $local 'Google\Chrome\User Data'); Kind = 'Chromium' },
            @{ Id = 'brave'; Name = 'Brave'; Proc = @('brave'); Root = (Join-Path $local 'BraveSoftware\Brave-Browser\User Data'); Kind = 'Chromium' },
            @{ Id = 'firefox'; Name = 'Firefox'; Proc = @('firefox'); Root = (Join-Path $local 'Mozilla\Firefox\Profiles'); Kind = 'Firefox' }
        )
        foreach ($b in $browsers) {
            $rid = 'browser_' + $b.Id
            try {
                if (-not (Test-Path -LiteralPath $b.Root)) { Write-OptiMaintResult -Id $rid -Name ($b.Name + ' cache') -Status Skipped -Message 'not installed'; continue }
                $running = @(Get-Process -Name $b.Proc -ErrorAction SilentlyContinue)
                if ($running.Count -gt 0) { Write-OptiMaintResult -Id $rid -Name ($b.Name + ' cache') -Status Skipped -Message ('close ' + $b.Name + ' first'); continue }
                $specs = @()
                if ($b.Kind -eq 'Chromium') {
                    foreach ($p in @(Get-ChildItem -LiteralPath $b.Root -Directory -Force -ErrorAction SilentlyContinue)) {
                        foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') {
                            $dir = Join-Path $p.FullName $c
                            if (Test-Path -LiteralPath $dir) { $specs += @{ Path = $dir; Recurse = $true; Dirs = $true } }
                        }
                    }
                }
                else {
                    foreach ($p in @(Get-ChildItem -LiteralPath $b.Root -Directory -Force -ErrorAction SilentlyContinue)) {
                        $dir = Join-Path $p.FullName 'cache2'
                        if (Test-Path -LiteralPath $dir) { $specs += @{ Path = $dir; Recurse = $true; Dirs = $true } }
                    }
                }
                $dry = -not $PSCmdlet.ShouldProcess($b.Name, 'Clear cache')
                $bytes = Clear-OptiMaintSpec -Specs $specs -DryRun $dry
                [void](Complete-OptiMaintArea -Id $rid -Name ($b.Name + ' cache') -Bytes $bytes -DryRun $dry)
            } catch { Write-OptiMaintResult -Id $rid -Name ($b.Name + ' cache') -Status Failed -Message $_.Exception.Message }
        }
    } catch {
        Write-OptiMaintResult -Id 'browser_cache' -Name 'Browser caches' -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- DISM
function Invoke-OptiComponentCleanup {
<#
.SYNOPSIS
Runs DISM StartComponentCleanup (WinSxS cleanup). With -ResetBase also removes superseded component versions; installed updates then can no longer be uninstalled.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$ResetBase)
    $name = 'Component store cleanup'
    if ($ResetBase) { $name = 'Component store cleanup (ResetBase)' }
    try {
        if (-not (Test-OptiMaintGate -Id 'component_cleanup' -Name $name)) { return }
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status Skipped -Message 'Windows only'; return }
        if (-not (Test-OptiAdmin)) { Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status Skipped -Message 'needs an elevated (Administrator) session'; return }
        $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($ResetBase) { $dismArgs += '/ResetBase' }
        if (-not $PSCmdlet.ShouldProcess('WinSxS component store', ('DISM ' + ($dismArgs -join ' ')))) {
            $m = 'would run DISM component cleanup'
            if ($ResetBase) { $m = 'would run DISM with /ResetBase (installed updates could no longer be uninstalled)' }
            Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status DryRun -Message $m
            return
        }
        if ($ResetBase) { Write-OptiLog -Message 'ResetBase makes all currently installed Windows updates permanently uninstallable.' -Level Warn }
        Write-OptiLog -Message 'Running DISM - this can take several minutes...' -Level Info
        & Dism.exe @dismArgs 2>&1 | ForEach-Object {
            $line = ([string]$_).Trim()
            if ($line) { try { Write-Host ('  ' + $line) -ForegroundColor DarkGray } catch { } }
        }
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq 3010) {
            $m = 'completed'; if ($code -eq 3010) { $m = 'completed; restart required' }
            Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status Applied -Message $m
        }
        else { Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status Failed -Message "DISM exit code $code" }
    } catch {
        Write-OptiMaintResult -Id 'component_cleanup' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- Windows.old
function Remove-OptiWindowsOld {
<#
.SYNOPSIS
Removes Windows.old and leftover upgrade files via Disk Cleanup (cleanmgr /sagerun:777). Caution: rollback to the previous Windows version becomes impossible.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $name = 'Remove Windows.old'
    try {
        if (-not (Test-OptiMaintGate -Id 'windows_old' -Name $name)) { return }
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Skipped -Message 'Windows only'; return }
        $sd = $env:SystemDrive; if (-not $sd) { $sd = 'C:' }
        $old = Join-Path ($sd + '\') 'Windows.old'
        if (-not (Test-Path -LiteralPath $old)) { Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Skipped -Message 'no Windows.old folder present'; return }
        if (-not (Test-OptiAdmin)) { Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Skipped -Message 'needs an elevated (Administrator) session'; return }
        $before = Get-OptiFolderSizeBytesSafe -Path $old
        $mb = [math]::Round($before / 1MB, 0)
        if (-not $PSCmdlet.ShouldProcess($old, 'Delete via Disk Cleanup')) {
            Write-OptiMaintResult -Id 'windows_old' -Name $name -Status DryRun -Message "would remove about $mb MB; rollback to the previous Windows version would no longer be possible"
            return
        }
        $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        $keys = @('Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files', 'Update Cleanup')
        $set = @()
        foreach ($k in $keys) {
            $p = $base + '\' + $k
            if (Test-Path -LiteralPath $p) {
                try { Set-OptiRegistry -Path $p -Name 'StateFlags0777' -Value 2 -Type DWord; $set += $p } catch { }
            }
        }
        Write-OptiLog -Message 'Running Disk Cleanup for Windows.old - this can take several minutes...' -Level Info
        try { Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:777' -Wait -ErrorAction Stop }
        finally {
            foreach ($p in $set) { try { Remove-OptiRegistry -Path $p -Name 'StateFlags0777' } catch { } }
        }
        if (Test-Path -LiteralPath $old) {
            $after = Get-OptiFolderSizeBytesSafe -Path $old
            $freed = [math]::Round([math]::Max(0, $before - $after) / 1MB, 0)
            Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Applied -Message "freed about $freed MB; Windows.old not fully removed (reboot and retry if needed)"
        }
        else {
            Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Applied -Message "freed about $mb MB; rollback to the previous Windows version is no longer possible"
        }
    } catch {
        Write-OptiMaintResult -Id 'windows_old' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- network
function Clear-OptiNetworkCache {
<#
.SYNOPSIS
Flushes DNS, ARP, destination and NetBIOS name caches. Safe.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $name = 'Flush network caches'
    try {
        if (-not $PSCmdlet.ShouldProcess('network caches', 'Flush')) { Write-OptiMaintResult -Id 'network_flush' -Name $name -Status DryRun -Message 'would flush DNS, ARP, destination and NetBIOS caches'; return }
        $cmds = @(
            @('ipconfig', @('/flushdns')),
            @('netsh', @('interface', 'ip', 'delete', 'arpcache')),
            @('netsh', @('interface', 'ip', 'delete', 'destinationcache')),
            @('nbtstat', @('-R'))
        )
        $ok = 0
        foreach ($c in $cmds) {
            $r = Invoke-OptiMaintNative -File $c[0] -ArgList $c[1]
            if ($r.Exit -eq 0) { $ok++ }
        }
        if ($ok -gt 0) { Write-OptiMaintResult -Id 'network_flush' -Name $name -Status Applied -Message "$ok of $($cmds.Count) caches flushed" }
        else { Write-OptiMaintResult -Id 'network_flush' -Name $name -Status Failed -Message 'no flush command succeeded (Windows only / needs admin)' }
    } catch {
        Write-OptiMaintResult -Id 'network_flush' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- RAM
function Clear-OptiMemory {
<#
.SYNOPSIS
One-off RAM boost: trims process working sets and purges the standby list. Windows refills its cache over time, so the gain is temporary.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $name = 'Trim RAM (working sets and standby list)'
    try {
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'ram_trim' -Name $name -Status Skipped -Message 'Windows only'; return }
        if (-not (Test-OptiAdmin)) { Write-OptiMaintResult -Id 'ram_trim' -Name $name -Status Skipped -Message 'needs an elevated (Administrator) session'; return }
        if (-not $PSCmdlet.ShouldProcess('running processes and standby list', 'Trim memory')) {
            Write-OptiMaintResult -Id 'ram_trim' -Name $name -Status DryRun -Message 'would trim working sets and purge the standby list (one-off boost; Windows refills its cache over time)'
            return
        }
        if (-not ('OptiMem' -as [type])) {
            $src = @'
using System;
using System.Runtime.InteropServices;
public static class OptiMem {
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int cls, IntPtr info, int len);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv { public int Count; public long Luid; public int Attr; }
    public static bool Trim(int pid) {
        IntPtr h = OpenProcess(0x0500, false, pid);
        if (h == IntPtr.Zero) return false;
        bool ok = EmptyWorkingSet(h);
        CloseHandle(h);
        return ok;
    }
    public static bool EnablePrivilege(string priv) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        TokPriv tp = new TokPriv(); tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, priv, out tp.Luid)) { CloseHandle(tok); return false; }
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        CloseHandle(tok);
        return ok && err == 0;
    }
    public static int PurgeStandby() {
        IntPtr p = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(p, 4); return NtSetSystemInformation(80, p, 4); }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@
            Add-Type -TypeDefinition $src -ErrorAction Stop
        }
        $freeBefore = 0
        try { $freeBefore = [int64](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory } catch { }
        $skip = @('System', 'Idle', 'csrss', 'smss', 'wininit', 'lsass', 'MsMpEng', 'Registry', 'Memory Compression', 'Secure System')
        $n = 0
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($skip -contains $p.ProcessName) { continue }
            try { if ([OptiMem]::Trim($p.Id)) { $n++ } } catch { }
        }
        $purged = $false
        try {
            if ([OptiMem]::EnablePrivilege('SeProfileSingleProcessPrivilege')) { $purged = ([OptiMem]::PurgeStandby() -eq 0) }
        } catch { }
        Start-Sleep -Milliseconds 500
        $freeAfter = 0
        try { $freeAfter = [int64](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory } catch { }
        $b = [math]::Round($freeBefore / 1KB, 0); $a = [math]::Round($freeAfter / 1KB, 0)
        $pm = 'standby list purged'; if (-not $purged) { $pm = 'standby list NOT purged' }
        Write-OptiMaintResult -Id 'ram_trim' -Name $name -Status Applied -Message "$n processes trimmed, $pm; available RAM $b MB -> $a MB (one-off boost, Windows refills cache over time)"
    } catch {
        Write-OptiMaintResult -Id 'ram_trim' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- startup
function Optimize-OptiStartupItems {
<#
.SYNOPSIS
Disables (never deletes) well-known non-essential startup entries. -Undo re-enables exactly the entries that were disabled.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Undo)
    $name = 'Trim startup items'
    try {
        if (-not (Test-OptiMaintGate -Id 'startup_trim' -Name $name)) { return }
        $file = Join-Path (Get-OptiBackupDir) 'startup_disabled.json'
        if ($Undo) {
            $name = 'Restore startup items'
            if (-not (Test-Path -LiteralPath $file)) { Write-OptiMaintResult -Id 'startup_trim' -Name $name -Action Undo -Status Skipped -Message 'nothing to restore (no saved list)'; return }
            $saved = @()
            try { $saved = @(Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { }
            $count = 0
            foreach ($e in $saved) {
                if (-not $e.Name) { continue }
                if (-not $PSCmdlet.ShouldProcess([string]$e.Name, 'Re-enable startup item')) { Write-OptiMaintResult -Id 'startup_trim' -Name ("Re-enable " + $e.Name) -Action Undo -Status DryRun -Message 'would re-enable'; continue }
                $ok = Set-OptiStartupItem -Name ([string]$e.Name) -Location ([string]$e.Location) -Enabled $true
                if ($ok) { $count++ }
            }
            if (-not $WhatIfPreference) {
                try { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } catch { }
                Write-OptiMaintResult -Id 'startup_trim' -Name $name -Action Undo -Status Undone -Message "$count startup item(s) re-enabled"
            }
            return
        }
        $disable = @('*Teams*', '*Spotify*', '*Discord*', '*Steam*', '*EpicGamesLauncher*', '*Skype*', '*CCleaner*', '*AdobeGCInvoker*', '*Adobe*Updater*', '*CCXProcess*', '*iTunesHelper*', '*EADM*', '*Origin*', '*Battle.net*', '*uTorrent*', '*qBittorrent*', '*Opera*Assistant*', '*MicrosoftEdgeAutoLaunch*', '*Cortana*')
        $keep = @('*OneDrive*', '*SecurityHealth*', '*Defender*', '*Realtek*', '*Rtk*', '*Synaptics*', '*ELAN*', '*Intel*', '*AMD*', '*NVIDIA*', '*igfx*', '*Dolby*', '*Waves*', '*MaxxAudio*', '*Bluetooth*', '*Logitech*', '*ctfmon*', '*Avast*', '*AVG*', '*Norton*', '*McAfee*', '*Kaspersky*', '*Bitdefender*', '*ESET*')
        $items = @(Get-OptiStartupItems | Where-Object { $_.Enabled })
        $hits = @()
        foreach ($it in $items) {
            $text = @([string]$it.Name, [string]$it.Command)
            $protected = $false
            foreach ($k in $keep) { foreach ($t in $text) { if ($t -like $k) { $protected = $true } } }
            if ($protected) { continue }
            $match = $false
            foreach ($d in $disable) { foreach ($t in $text) { if ($t -like $d) { $match = $true } } }
            if ($match) { $hits += $it }
        }
        if ($hits.Count -eq 0) { Write-OptiMaintResult -Id 'startup_trim' -Name $name -Status Skipped -Message 'no known non-essential startup items are enabled'; return }
        $done = @()
        foreach ($h in $hits) {
            if (-not $PSCmdlet.ShouldProcess([string]$h.Name, 'Disable startup item')) {
                Write-OptiMaintResult -Id 'startup_trim' -Name ("Disable startup: " + $h.Name) -Status DryRun -Message ('would disable (' + $h.Location + ')')
                continue
            }
            $ok = Set-OptiStartupItem -Name ([string]$h.Name) -Location ([string]$h.Location) -Enabled $false
            if ($ok) {
                $done += [pscustomobject]@{ Name = [string]$h.Name; Location = [string]$h.Location }
                Write-OptiMaintResult -Id 'startup_trim' -Name ("Disable startup: " + $h.Name) -Status Applied -Message ('(' + $h.Location + ')')
            }
            else { Write-OptiMaintResult -Id 'startup_trim' -Name ("Disable startup: " + $h.Name) -Status Failed -Message 'could not change entry' }
        }
        if ($done.Count -gt 0) {
            $all = @()
            if (Test-Path -LiteralPath $file) { try { $all = @(Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { $all = @() } }
            foreach ($d in $done) {
                $dup = @($all | Where-Object { $_.Name -eq $d.Name -and $_.Location -eq $d.Location })
                if ($dup.Count -eq 0) { $all += $d }
            }
            $json = ConvertTo-Json -InputObject @($all) -Depth 3
            [IO.File]::WriteAllText($file, $json)
            Write-OptiLog -Message "Saved the list of disabled items to $file (use -Undo to re-enable)." -Level Info
        }
    } catch {
        Write-OptiMaintResult -Id 'startup_trim' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- hardware tuning
function Invoke-OptiHardwareTuning {
<#
.SYNOPSIS
Picks tweaks that suit this machine: memory compression by RAM size, TRIM or SysMain by disk type, and protects low-RAM laptops from a disabled pagefile.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    try {
        if (-not (Test-OptiMaintGate -Id 'hardware_tuning' -Name 'Hardware-aware tuning')) { return }
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'hardware_tuning' -Name 'Hardware-aware tuning' -Status Skipped -Message 'Windows only'; return }
        $dry = -not $PSCmdlet.ShouldProcess('system', 'Hardware-aware tuning')
        $info = Get-OptiDriveInfo
        $ram = $info.RAMGB
        if ($null -eq $ram) { Write-OptiMaintResult -Id 'hardware_tuning' -Name 'Hardware-aware tuning' -Status Skipped -Message 'could not detect RAM size'; return }
        Write-OptiLog -Message ("Detected {0} GB RAM, system disk {1}." -f $ram, $info.MediaType) -Level Info
        if ($ram -ge 16) {
            try { Invoke-OptiTweak -Id memory_compression_off -Action Apply } catch { Write-OptiMaintResult -Id 'memory_compression_off' -Status Failed -Message $_.Exception.Message }
        }
        else {
            Write-OptiMaintResult -Id 'memory_compression_off' -Name 'Memory compression' -Status Skipped -Message 'keeping memory compression on (<16 GB RAM benefits from it)'
        }
        if ($info.IsSSD) { Enable-OptiTrim -DryRun $dry }
        elseif ($info.MediaType -eq 'HDD') {
            try { Invoke-OptiTweak -Id svc_sysmain -Action Undo } catch { Write-OptiMaintResult -Id 'svc_sysmain' -Status Failed -Message $_.Exception.Message }
            Write-OptiMaintResult -Id 'hardware_hdd' -Name 'HDD detected' -Status Skipped -Message 'SysMain (Superfetch) kept at default because it helps HDDs'
        }
        else { Write-OptiMaintResult -Id 'hardware_disk' -Name 'System disk type' -Status Skipped -Message 'unknown media type; no disk-specific tuning' }
        if ($ram -le 8) {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            $pf = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
            if ($cs -and -not $cs.AutomaticManagedPagefile -and $pf.Count -eq 0) {
                if ($dry) { Write-OptiMaintResult -Id 'pagefile_guard' -Name 'Pagefile' -Status DryRun -Message 'would re-enable the system-managed pagefile (low-RAM machines need it)' }
                else { Set-OptiPagefile -Mode SystemManaged }
            }
        }
    } catch {
        Write-OptiMaintResult -Id 'hardware_tuning' -Name 'Hardware-aware tuning' -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- restore point size
function Get-OptiShadowStorage {
    [CmdletBinding()] param([string]$Drive = 'C:')
    $r = Invoke-OptiMaintNative -File 'vssadmin' -ArgList @('list', 'shadowstorage', "/for=$Drive")
    if ($r.Exit -ne 0) { return $null }
    $txt = ($r.Output -join "`n")
    $m = [regex]::Match($txt, 'Maximum Shadow Copy Storage space:\s*([^\r\n]+)')
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value.Trim()
    $setting = $null
    $pct = [regex]::Match($raw, '\((\d+)%\)')
    $sz = [regex]::Match($raw, '^([\d\.,]+)\s*(KB|MB|GB|TB)')
    if ($raw -match 'UNBOUNDED') { $setting = 'UNBOUNDED' }
    elseif ($pct.Success) { $setting = $pct.Groups[1].Value + '%' }
    elseif ($sz.Success) { $setting = ($sz.Groups[1].Value -replace ',', '') + $sz.Groups[2].Value }
    return [pscustomobject]@{ Raw = $raw; Setting = $setting }
}

function Set-OptiRestorePointSize {
<#
.SYNOPSIS
Caps System Restore storage (default 5 percent of the drive) to stop restore points eating disk space. -Undo restores the previous limit (or 10 percent).
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([ValidateRange(1, 50)][int]$Percent = 5, [switch]$Undo)
    $name = "Limit restore-point storage to $Percent%"
    if ($Undo) { $name = 'Restore restore-point storage limit' }
    try {
        if (-not (Test-OptiMaintGate -Id 'restore_size' -Name $name)) { return }
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Skipped -Message 'Windows only'; return }
        if (-not (Test-OptiAdmin)) { Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Skipped -Message 'needs an elevated (Administrator) session'; return }
        $file = Join-Path (Get-OptiBackupDir) 'shadowstorage.json'
        $drive = $env:SystemDrive; if (-not $drive) { $drive = 'C:' }
        if ($Undo) {
            $target = '10%'
            if (Test-Path -LiteralPath $file) {
                try { $s = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json; if ($s.Setting) { $target = [string]$s.Setting } } catch { }
            }
            if (-not $PSCmdlet.ShouldProcess($drive, "Set restore-point storage to $target")) { Write-OptiMaintResult -Id 'restore_size' -Name $name -Action Undo -Status DryRun -Message "would set limit to $target"; return }
            $r = Invoke-OptiMaintNative -File 'vssadmin' -ArgList @('resize', 'shadowstorage', "/for=$drive", "/on=$drive", "/maxsize=$target")
            if ($r.Exit -eq 0) {
                Write-OptiMaintResult -Id 'restore_size' -Name $name -Action Undo -Status Undone -Message "limit set to $target"
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            }
            else { Write-OptiMaintResult -Id 'restore_size' -Name $name -Action Undo -Status Failed -Message (($r.Output -join ' ').Trim()) }
            return
        }
        $cur = Get-OptiShadowStorage -Drive $drive
        if (-not $cur) { Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Skipped -Message 'System Protection not enabled on this drive'; return }
        if (-not $PSCmdlet.ShouldProcess($drive, "Limit restore-point storage to $Percent%")) {
            Write-OptiMaintResult -Id 'restore_size' -Name $name -Status DryRun -Message "would change limit from '$($cur.Raw)' to $Percent%"
            return
        }
        if (-not (Test-Path -LiteralPath $file)) {
            [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject ([pscustomobject]@{ Drive = $drive; Raw = $cur.Raw; Setting = $cur.Setting }) -Depth 3))
        }
        $r = Invoke-OptiMaintNative -File 'vssadmin' -ArgList @('resize', 'shadowstorage', "/for=$drive", "/on=$drive", "/maxsize=$Percent%")
        if ($r.Exit -eq 0) { Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Applied -Message "was '$($cur.Raw)', now $Percent%" }
        else { Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Failed -Message (($r.Output -join ' ').Trim()) }
    } catch {
        Write-OptiMaintResult -Id 'restore_size' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- pagefile
function Set-OptiPagefile {
<#
.SYNOPSIS
Caution: sets the pagefile to system managed (Windows default) or a fixed size (default 1.5x RAM). Current settings are saved to backups\pagefile.json first. Takes effect after restart.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('SystemManaged', 'Fixed')][string]$Mode, [int]$SizeMB)
    $name = "Pagefile: $Mode"
    try {
        if (-not (Test-OptiMaintGate -Id 'pagefile' -Name $name)) { return }
        if (-not (Test-OptiMaintWindows)) { Write-OptiMaintResult -Id 'pagefile' -Name $name -Status Skipped -Message 'Windows only'; return }
        if (-not (Test-OptiAdmin)) { Write-OptiMaintResult -Id 'pagefile' -Name $name -Status Skipped -Message 'needs an elevated (Administrator) session'; return }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($Mode -eq 'Fixed' -and $SizeMB -le 0) { $SizeMB = [int][math]::Round(($cs.TotalPhysicalMemory / 1MB) * 1.5, 0) }
        $desc = 'system managed (Windows default)'; if ($Mode -eq 'Fixed') { $desc = "fixed $SizeMB MB" }
        if (-not $PSCmdlet.ShouldProcess('pagefile', "Set $desc")) { Write-OptiMaintResult -Id 'pagefile' -Name $name -Status DryRun -Message "would set pagefile to $desc"; return }
        $pf = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; InitialSize = $_.InitialSize; MaximumSize = $_.MaximumSize } })
        $backup = [pscustomobject]@{ Saved = (Get-Date).ToString('s'); AutomaticManagedPagefile = [bool]$cs.AutomaticManagedPagefile; Settings = $pf }
        [IO.File]::WriteAllText((Join-Path (Get-OptiBackupDir) 'pagefile.json'), (ConvertTo-Json -InputObject $backup -Depth 4))
        if ($Mode -eq 'SystemManaged') {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        }
        else {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
            Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
            $drive = $env:SystemDrive; if (-not $drive) { $drive = 'C:' }
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = ($drive + '\pagefile.sys'); InitialSize = [uint32]$SizeMB; MaximumSize = [uint32]$SizeMB } -ErrorAction Stop | Out-Null
        }
        Write-OptiMaintResult -Id 'pagefile' -Name $name -Status Applied -Message "pagefile set to $desc; takes effect after restart"
    } catch {
        Write-OptiMaintResult -Id 'pagefile' -Name $name -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------- dispatcher and menu
function Get-OptiMaintenanceCatalog {
    [CmdletBinding()] param()
    @(
        [pscustomobject]@{ Id = 'disk_optimize'; Title = 'Optimize drives (defrag HDD / ReTrim SSD, ensure TRIM)'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'deep_clean'; Title = 'Deep clean (temp, thumbnails, shader cache, logs, dumps, recycle bin)'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'browser_cache'; Title = 'Clear browser caches (Edge, Chrome, Brave, Firefox)'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'component_cleanup'; Title = 'Windows component store cleanup (DISM)'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'windows_old'; Title = 'Remove Windows.old'; Risk = 'Caution' },
        [pscustomobject]@{ Id = 'network_flush'; Title = 'Flush DNS / ARP / network caches'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'ram_trim'; Title = 'Trim RAM now (one-off boost)'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'startup_trim'; Title = 'Disable known non-essential startup items'; Risk = 'Moderate' },
        [pscustomobject]@{ Id = 'hardware_tuning'; Title = 'Hardware-aware tuning (RAM and disk type)'; Risk = 'Moderate' },
        [pscustomobject]@{ Id = 'restore_size'; Title = 'Limit restore-point storage to 5%'; Risk = 'Moderate' },
        [pscustomobject]@{ Id = 'startup_undo'; Title = 'Undo startup trimming'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'restore_size_undo'; Title = 'Restore restore-point storage limit'; Risk = 'Safe' },
        [pscustomobject]@{ Id = 'pagefile_managed'; Title = 'Pagefile: set system managed (Windows default)'; Risk = 'Caution' },
        [pscustomobject]@{ Id = 'pagefile_fixed'; Title = 'Pagefile: set fixed size (1.5x RAM)'; Risk = 'Caution' }
    )
}

function Invoke-OptiMaintenance {
<#
.SYNOPSIS
Runs maintenance actions by id: disk_optimize, deep_clean, browser_cache, component_cleanup, windows_old, network_flush, ram_trim, startup_trim, hardware_tuning, restore_size (plus startup_undo, restore_size_undo, pagefile_managed, pagefile_fixed, component_cleanup_resetbase).
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Actions)
    if (-not (Test-OptiMaintGate -Id 'safety_net' -Name 'Restore point required')) { return }
    foreach ($a in $Actions) {
        $id = ([string]$a).Trim().ToLower()
        if (-not $id) { continue }
        $cat = Get-OptiMaintenanceCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        $title = $id; if ($cat) { $title = $cat.Title }
        if ($id -eq 'component_cleanup_resetbase') { $title = 'Component store cleanup with ResetBase' }
        try { Write-Host ''; Write-Host ("-- $title --") -ForegroundColor Cyan } catch { }
        try {
            switch ($id) {
                'disk_optimize' { Optimize-OptiDisk }
                'deep_clean' { Clear-OptiDeepClean }
                'browser_cache' { Clear-OptiBrowserCache }
                'component_cleanup' { Invoke-OptiComponentCleanup }
                'component_cleanup_resetbase' { Invoke-OptiComponentCleanup -ResetBase }
                'windows_old' { Remove-OptiWindowsOld }
                'network_flush' { Clear-OptiNetworkCache }
                'ram_trim' { Clear-OptiMemory }
                'startup_trim' { Optimize-OptiStartupItems }
                'startup_undo' { Optimize-OptiStartupItems -Undo }
                'hardware_tuning' { Invoke-OptiHardwareTuning }
                'restore_size' { Set-OptiRestorePointSize }
                'restore_size_undo' { Set-OptiRestorePointSize -Undo }
                'pagefile_managed' { Set-OptiPagefile -Mode SystemManaged }
                'pagefile_fixed' { Set-OptiPagefile -Mode Fixed }
                default { Write-OptiMaintResult -Id $id -Name "Unknown maintenance action '$a'" -Status Failed -Message 'valid ids: disk_optimize, deep_clean, browser_cache, component_cleanup, windows_old, network_flush, ram_trim, startup_trim, hardware_tuning, restore_size' }
            }
        } catch {
            Write-OptiMaintResult -Id $id -Name $title -Status Failed -Message $_.Exception.Message
        }
    }
}

function Show-OptiMaintenanceMenu {
<#
.SYNOPSIS
Interactive numbered menu for the maintenance actions. Select several with 1,3,5 or a for all safe/moderate items.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $cat = @(Get-OptiMaintenanceCatalog)
    Write-Host ''
    Write-Host 'Maintenance menu' -ForegroundColor Cyan
    for ($i = 0; $i -lt $cat.Count; $i++) {
        $tag = ''
        if ($cat[$i].Risk -ne 'Safe') { $tag = '[' + $cat[$i].Risk + '] ' }
        $color = 'Gray'; if ($cat[$i].Risk -eq 'Caution') { $color = 'Yellow' }
        Write-Host ('  {0,2}. {1}{2}' -f ($i + 1), $tag, $cat[$i].Title) -ForegroundColor $color
    }
    Write-Host '   a. All standard items (1-10, skips Caution items)'
    Write-Host '   q. Back / quit'
    $sel = Read-Host 'Choose (e.g. 1,3,5 or a)'
    if (-not $sel) { return }
    $sel = $sel.Trim().ToLower()
    if ($sel -eq 'q') { return }
    $ids = @()
    if ($sel -eq 'a') {
        $ids = @($cat | Where-Object { $_.Risk -ne 'Caution' -and $_.Id -notlike '*_undo' } | ForEach-Object { $_.Id })
    }
    else {
        foreach ($tok in ($sel -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $cat.Count) { $ids += $cat[$n - 1].Id }
            elseif ($tok) { Write-Host "  Ignoring '$tok'" -ForegroundColor DarkGray }
        }
    }
    if ($ids.Count -eq 0) { Write-Host '  Nothing selected.'; return }
    $final = @()
    foreach ($id in $ids) {
        $c = $cat | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($c.Risk -eq 'Caution') {
            $extra = ''
            if ($id -eq 'windows_old') { $extra = ' (you will no longer be able to roll back to the previous Windows version)' }
            $ans = Read-Host ("[Caution] $($c.Title)$extra. Continue? (Y/N)")
            if ($ans -notmatch '^[Yy]') { Write-Host '  Skipped.' -ForegroundColor DarkGray; continue }
        }
        $final += $id
        if ($id -eq 'component_cleanup') {
            $rb = Read-Host 'Also use /ResetBase for maximum space? Installed updates can then no longer be uninstalled. (Y/N)'
            if ($rb -match '^[Yy]') { $final = @($final | Where-Object { $_ -ne 'component_cleanup' }) + 'component_cleanup_resetbase' }
        }
    }
    if ($final.Count -gt 0) { Invoke-OptiMaintenance -Actions $final }
}
