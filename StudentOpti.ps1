<#
.SYNOPSIS
  StudentOpti - Windows optimizer for students. Interactive console menu by default, flags for headless runs, -Gui for the WPF window.
.EXAMPLE
  .\StudentOpti.ps1
.EXAMPLE
  .\StudentOpti.ps1 -Preset StrongestOptimizer -Yes
.EXAMPLE
  .\StudentOpti.ps1 -Preset StudentLaptop -XboxMode Lite -Silent
#>
[CmdletBinding()]
param(
    [ValidateSet('LightestWindows','StrongestOptimizer','StudentLaptop','StudyBattery','GamingXbox','FactoryDefault')]
    [string]$Preset,
    [ValidateSet('Enable','Enabled','Lite','Disable','Disabled','Repair')]
    [string]$XboxMode,
    [string[]]$Tweaks,
    [string[]]$Undo,
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$NoRestorePoint,
    [switch]$RestoreSnapshot,
    [switch]$ListTweaks,
    [switch]$CleanTemp,
    [switch]$Gui,
    [switch]$NoRestartPrompt,
    [switch]$Yes,
    [string[]]$Maintenance
)

$ErrorActionPreference = 'Stop'

# Keep a full record of every run next to the script, and never let an error vanish with the window.
$script:OptiLastRunLog = Join-Path $PSScriptRoot 'StudentOpti-last-run.log'
try { Start-Transcript -Path $script:OptiLastRunLog -Force | Out-Null } catch { }
trap {
    Write-Host ''
    Write-Host ('StudentOpti hit an unexpected error: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray }
    Write-Host ('Full log: ' + $script:OptiLastRunLog)
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
$script:OptiRoot = $PSScriptRoot
$script:ModuleFiles = @('Common.ps1','Backup-Manager.ps1','Debloat-Engine.ps1','Process-Optimizer.ps1','Responsiveness-Engine.ps1')
if (Test-Path -LiteralPath (Join-Path (Join-Path $script:OptiRoot 'modules') 'Maintenance-Engine.ps1')) { $script:ModuleFiles += 'Maintenance-Engine.ps1' }
$script:ModuleFiles += 'Xbox-Controller.ps1'
foreach ($m in $script:ModuleFiles) {
    . (Join-Path (Join-Path $script:OptiRoot 'modules') $m)
}
. (Join-Path (Join-Path $script:OptiRoot 'modules') 'Cli.ps1')

if ($DryRun) { $global:WhatIfPreference = $true }
$global:OptiYes = [bool]$Yes
if ($NoRestorePoint) { Write-Host 'Restore point is mandatory; -NoRestorePoint is ignored.' -ForegroundColor Yellow }
$global:OptiNoRestartPrompt = ([bool]$NoRestartPrompt -or [bool]$Silent)

try { $Host.UI.RawUI.WindowTitle = 'StudentOpti' } catch { }
try {
    $buf = $Host.UI.RawUI.BufferSize
    if ($buf.Width -lt 120) {
        $buf.Width = 120
        $Host.UI.RawUI.BufferSize = $buf
    }
} catch { }

$cliAction = ($Preset -or $XboxMode -or $Tweaks -or $Undo -or $RestoreSnapshot -or $ListTweaks -or $CleanTemp -or $Maintenance)

# ---------------------------------------------------------------- headless CLI
function Invoke-OptiCli {
    $fail = $false
    $mutating = ($Preset -or $XboxMode -or $Tweaks -or $Undo -or $RestoreSnapshot -or $CleanTemp -or $Maintenance)

    if ($ListTweaks) {
        $rows = @()
        foreach ($src in @('tweaks','services','tasks')) {
            foreach ($t in @((Get-OptiConfig -Name $src).$src)) {
                $tier = ''
                if ($t.PSObject.Properties['tier']) { $tier = [string]$t.tier }
                $rows += [pscustomobject]@{ Id = $t.id; Category = $t.category; Risk = $t.risk_level; Tier = $tier; Name = $t.name }
            }
        }
        $rows | Sort-Object Category, Id | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        if (-not $mutating) { return 0 }
    }

    if ($mutating -and -not $DryRun -and -not (Test-OptiAdmin)) {
        Write-Host 'StudentOpti: administrator rights are required. Run Run-Optimizer.bat or an elevated PowerShell (or add -DryRun).' -ForegroundColor Red
        return 1
    }

    Reset-OptiResults
    if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Yellow }

    $gated = ($Preset -or $Tweaks -or $Undo -or $CleanTemp -or $Maintenance -or ($XboxMode -and $XboxMode -ne 'Repair'))
    if ($gated) {
        Write-OptiSection 'Safety net'
        if (-not (Confirm-OptiSafetyNet)) { return 2 }
        if (-not $DryRun) { Write-Host '  Safety net ready' -ForegroundColor Green }
    }

    if ($Preset) {
        try { Invoke-OptiPreset -Id $Preset } catch { Add-OptiResult -Id $Preset -Name "Preset $Preset" -Status Failed -Message $_.Exception.Message }
    }
    if ($XboxMode) {
        Write-OptiSection 'Xbox'
        switch ($XboxMode) {
            'Repair'   { Invoke-OptiStep -Id 'xbox_repair' -Name 'Xbox deep repair' -Code { Restore-XboxFallback -Deep } }
            'Enable'   { Invoke-OptiStep -Id 'xbox_mode' -Name 'Xbox mode: Enabled' -Code { Set-XboxMode -Mode Enabled } }
            'Disable'  { Invoke-OptiStep -Id 'xbox_mode' -Name 'Xbox mode: Disabled' -Code { Set-XboxMode -Mode Disabled } }
            default    { $xm = $XboxMode; Invoke-OptiStep -Id 'xbox_mode' -Name ('Xbox mode: ' + $xm) -Code { Set-XboxMode -Mode $xm } }
        }
    }
    if (@($Tweaks | Where-Object { $_ }).Count -gt 0) {
        Write-OptiSection ('Tweaks ({0})' -f @($Tweaks | Where-Object { $_ }).Count)
        foreach ($id in @($Tweaks | Where-Object { $_ })) {
            if (-not $id) { continue }
            if ($global:OptiSafetyStop) { break }
            try { Invoke-OptiTweak -Id $id -Action Apply } catch { Add-OptiResult -Id $id -Action Apply -Status Failed -Message $_.Exception.Message }
        }
    }
    if (@($Undo | Where-Object { $_ }).Count -gt 0) {
        Write-OptiSection ('Undo ({0})' -f @($Undo | Where-Object { $_ }).Count)
        foreach ($id in @($Undo | Where-Object { $_ })) {
            if (-not $id) { continue }
            if ($global:OptiSafetyStop) { break }
            try { Invoke-OptiTweak -Id $id -Action Undo } catch { Add-OptiResult -Id $id -Action Undo -Status Failed -Message $_.Exception.Message }
        }
    }
    if ($RestoreSnapshot) {
        Write-OptiSection 'Snapshot'
        Invoke-OptiStep -Id 'restore_snapshot' -Name 'Restore last snapshot' -Code { Restore-OptiStateSnapshot }
    }
    if ($CleanTemp) {
        Write-OptiSection 'Cleanup'
        Invoke-OptiStep -Id 'cleanup' -Name 'Clean temp files' -Code { Clear-OptiTempFiles }
    }
    if (@($Maintenance | Where-Object { $_ }).Count -gt 0) {
        Write-OptiSection 'Disk, RAM & cleanup'
        if (Get-Command Invoke-OptiMaintenance -ErrorAction SilentlyContinue) {
            try { Invoke-OptiMaintenance -Actions @($Maintenance | Where-Object { $_ }) } catch { Add-OptiResult -Id 'maintenance' -Name 'Disk, RAM & cleanup' -Status Failed -Message $_.Exception.Message }
        } else { Add-OptiResult -Id 'maintenance' -Name 'Disk, RAM & cleanup' -Status Failed -Message 'Maintenance-Engine.ps1 not found' }
    }
    Show-OptiSummary
    if (@(Get-OptiResults | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $fail = $true }
    if (-not $Silent -and -not $NoRestartPrompt) { Request-OptiRestart }
    if ($global:OptiSafetyStop) { return 2 }
    if ($fail) { return 1 }
    return 0
}

if ($cliAction) {
    $code = 1
    try { $code = Invoke-OptiCli } catch { Write-Host "StudentOpti: $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
    exit $code
}

if ($Silent) {
    Write-Host 'StudentOpti: nothing to do. Specify -Preset, -XboxMode, -Tweaks, -Undo, -RestoreSnapshot, -CleanTemp or -ListTweaks.'
    exit 0
}

# ---------------------------------------------------------------- interactive menu (default)
if (-not $Gui) {
    if (-not $DryRun -and -not (Test-OptiAdmin)) {
        Write-Host ''
        Write-Host 'WARNING: StudentOpti is not running as administrator. Changes will fail.' -ForegroundColor Red
        $ans = Read-Host 'Relaunch elevated now? [Y/N]'
        if ($ans -match '^\s*[Yy]') {
            try {
                $exe = 'powershell.exe'
                try { $exe = (Get-Process -Id $PID).Path } catch { }
                $relArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
                if ($NoRestartPrompt) { $relArgs += '-NoRestartPrompt' }
                if ($Yes) { $relArgs += '-Yes' }
                Start-Process -FilePath $exe -ArgumentList $relArgs -Verb RunAs
                exit 0
            } catch {
                Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host 'Continuing without admin rights (use D in the menu for a dry run).' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    Show-OptiMainMenu
    exit 0
}

# ---------------------------------------------------------------- GUI (-Gui)
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $PSCommandPath),'-Gui')
    if ($DryRun) { $psArgs += '-DryRun' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Sync = [hashtable]::Synchronized(@{})
$script:Sync.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Sync.Busy = 0
$global:OptiSync = $script:Sync
$script:Tasks = New-Object System.Collections.ArrayList
$script:SafetyDone = $false

$xamlPath = Join-Path (Join-Path $script:OptiRoot 'ui') 'MainWindow.xaml'
$xamlText = [IO.File]::ReadAllText($xamlPath)
$xamlText = [regex]::Replace($xamlText, '\s+x:Class="[^"]*"', '')
[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$script:ui = @{}
$controlNames = @(
    'DryRunCheck','AdminDot','AdminText','LogBox','BusyBar','MainTabs',
    'RamText','ProcText','PlanText',
    'BtnPresetStudentLaptop','BtnPresetStudyBattery','BtnPresetGamingXbox','BtnPresetFactoryDefault','BtnRestorePoint','BtnRestoreSnapshot',
    'DebloatPanel','BtnDebloatApply','BtnDebloatUndo','BtnRemoveBloat','BtnRestoreApps','BtnCleanTemp',
    'ServiceGrid','BtnSvcOptimize','BtnSvcRevertAll','BtnSvcRefresh','ProcessTweaksPanel','BtnProcApply','BtnProcUndo',
    'SpeedPanel','BtnSpeedApply','BtnSpeedUndo','BtnRestartExplorer','BtnPowerStudy','BtnPowerPerf','BtnPowerBalanced',
    'BtnXboxEnabled','BtnXboxLite','BtnXboxDisabled','BtnXboxRefresh','BtnXboxEmergency','BtnXboxDeep','BtnXboxScript'
)
$script:XboxKeys = @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','GamingServices','GameBar')
foreach ($k in $script:XboxKeys) { $controlNames += ('XboxDot_' + $k); $controlNames += ('XboxText_' + $k) }
foreach ($n in $controlNames) {
    $c = $script:Window.FindName($n)
    if ($null -eq $c) { Write-Warning "Control not found in XAML: $n" }
    $script:ui[$n] = $c
}

if ($DryRun) { $script:ui.DryRunCheck.IsChecked = $true }

# ---- background tasks
$script:TaskWrapper = @'
param($Root, $Sync, $WhatIf, $SbText, [object[]]$TaskArgs, $Names)
$ErrorActionPreference = 'Stop'
$global:OptiSync = $Sync
$script:OptiRoot = $Root
if ($WhatIf) { $global:WhatIfPreference = $true }
try {
    foreach ($m in $Names) { . (Join-Path (Join-Path $Root 'modules') $m) }
    $sb = [scriptblock]::Create($SbText)
    $out = & $sb @TaskArgs 2>&1 | Out-String
    if ($out -and $out.Trim().Length -gt 0) { $Sync.Log.Enqueue($out.TrimEnd()) }
} catch {
    $Sync.Log.Enqueue('[ERROR] ' + $_.Exception.Message)
}
'@

function Start-OptiTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [scriptblock]$OnComplete,
        [switch]$SafetyNet
    )
    $dry = [bool]$script:ui.DryRunCheck.IsChecked
    $sbText = $ScriptBlock.ToString()
    if ($SafetyNet -and -not $dry -and -not $script:SafetyDone) {
        $sbText = "Invoke-OptiSafetyNet`r`n" + $sbText
        $script:SafetyDone = $true
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:TaskWrapper)
    [void]$ps.AddParameter('Root', $script:OptiRoot)
    [void]$ps.AddParameter('Sync', $script:Sync)
    [void]$ps.AddParameter('WhatIf', $dry)
    [void]$ps.AddParameter('SbText', $sbText)
    [void]$ps.AddParameter('TaskArgs', [object[]]$ArgumentList)
    [void]$ps.AddParameter('Names', $script:ModuleFiles)
    $script:Sync.Log.Enqueue(('--- {0}{1} ---' -f $Name, $(if ($dry) { ' (dry run)' } else { '' })))
    $script:Sync.Busy = [int]$script:Sync.Busy + 1
    $handle = $ps.BeginInvoke()
    [void]$script:Tasks.Add([pscustomobject]@{ Name = $Name; PS = $ps; RS = $rs; Handle = $handle; OnComplete = $OnComplete })
}

function Update-OptiBusy {
    $script:ui.BusyBar.IsIndeterminate = ([int]$script:Sync.Busy -gt 0)
}

function Complete-OptiTasks {
    $done = @($script:Tasks | Where-Object { $_.Handle.IsCompleted })
    foreach ($t in $done) {
        [void]$script:Tasks.Remove($t)
        try { [void]$t.PS.EndInvoke($t.Handle) } catch { $script:Sync.Log.Enqueue('[ERROR] ' + $_.Exception.Message) }
        foreach ($e in $t.PS.Streams.Error) { $script:Sync.Log.Enqueue('[ERROR] ' + $e.ToString()) }
        try { $t.PS.Dispose(); $t.RS.Close(); $t.RS.Dispose() } catch { }
        $script:Sync.Busy = [Math]::Max(0, [int]$script:Sync.Busy - 1)
        $script:Sync.Log.Enqueue(('--- {0} finished ---' -f $t.Name))
        if ($t.OnComplete) { try { & $t.OnComplete } catch { $script:Sync.Log.Enqueue('[ERROR] ' + $_.Exception.Message) } }
    }
}

function Write-GuiLog([string]$Text) { $script:Sync.Log.Enqueue($Text) }

# ---- timers
$script:LogTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LogTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:LogTimer.Add_Tick({
    Complete-OptiTasks
    $sb = New-Object System.Text.StringBuilder
    $line = $null
    $count = 0
    while ($count -lt 500 -and $script:Sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line); $count++ }
    if ($count -gt 0) {
        $box = $script:ui.LogBox
        $box.AppendText($sb.ToString())
        if ($box.Text.Length -gt 60000) { $box.Text = $box.Text.Substring($box.Text.Length - 40000) }
        $box.ScrollToEnd()
    }
    Update-OptiBusy
})

function Update-OptiDashboard {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $totalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedGB = [Math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        $pct = [Math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
        $script:ui.RamText.Text = "RAM: $usedGB GB / $totalGB GB used ($pct%)"
    } catch { $script:ui.RamText.Text = 'RAM: unavailable' }
    try { $script:ui.ProcText.Text = 'Processes: ' + @(Get-Process).Count } catch { }
    try { $script:ui.PlanText.Text = 'Power plan: ' + (Get-OptiActivePowerPlan) } catch { $script:ui.PlanText.Text = 'Power plan: unavailable' }
}

$script:DashTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DashTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:DashTimer.Add_Tick({ Update-OptiDashboard })

# ---- data-driven tweak checkboxes
function Get-OptiTweakItem([string]$Id) {
    foreach ($t in @((Get-OptiConfig -Name tweaks).tweaks)) { if ($t.id -eq $Id) { return $t } }
    return $null
}

function Fill-TweakPanel {
    param($Panel, [string[]]$Categories)
    $Panel.Children.Clear()
    $items = @()
    try { $items = @((Get-OptiConfig -Name tweaks).tweaks | Where-Object { $Categories -contains $_.category }) } catch { Write-GuiLog "[ERROR] Could not load tweaks.json: $($_.Exception.Message)" }
    foreach ($t in $items) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = [string]$t.name
        $cb.Tag = [string]$t.id
        $cb.ToolTip = ('{0}{1}Risk: {2}. Restart needed: {3}' -f $t.description, [Environment]::NewLine, $t.risk_level, $t.requires_restart)
        try { $cb.IsChecked = [bool](Invoke-OptiTweak -Id $t.id -Action Check) } catch { $cb.IsChecked = $false }
        [void]$Panel.Children.Add($cb)
    }
}

function Refresh-TweakPanels {
    Fill-TweakPanel -Panel $script:ui.DebloatPanel -Categories @('Privacy','AI')
    Fill-TweakPanel -Panel $script:ui.SpeedPanel -Categories @('Responsiveness','Input')
    Fill-TweakPanel -Panel $script:ui.ProcessTweaksPanel -Categories @('Processes')
}

function Get-CheckedIds($Panel) {
    $ids = @()
    foreach ($c in $Panel.Children) { if ($c -is [System.Windows.Controls.CheckBox] -and $c.IsChecked -eq $true) { $ids += [string]$c.Tag } }
    return $ids
}

function Invoke-SelectedTweaks {
    param($Panel, [ValidateSet('Apply','Undo')][string]$Action)
    $ids = @(Get-CheckedIds $Panel)
    if ($ids.Count -eq 0) { Write-GuiLog 'No tweaks selected.'; return }
    Start-OptiTask -Name "$Action selected tweaks" -SafetyNet -ArgumentList @($ids, $Action) -ScriptBlock {
        param($ids, $act)
        foreach ($id in $ids) { Invoke-OptiTweak -Id $id -Action $act }
    } -OnComplete { Refresh-TweakPanels }
}

# ---- service grid
function Refresh-ServiceGrid {
    try { $script:ui.ServiceGrid.ItemsSource = @(Get-OptiServiceReport) } catch { Write-GuiLog "[ERROR] Service report failed: $($_.Exception.Message)" }
}

# ---- Xbox status
function Get-XboxFlat($Raw) {
    $flat = @()
    foreach ($o in @($Raw)) {
        if ($null -eq $o) { continue }
        if ($o.PSObject.Properties['Name']) { $flat += $o; continue }
        foreach ($pn in @('Services','Packages','Components')) {
            if ($o.PSObject.Properties[$pn]) { foreach ($x in @($o.$pn)) { if ($x) { $flat += $x } } }
        }
    }
    return $flat
}

function Set-XboxDot($Key, $Color, $Text) {
    $dot = $script:ui['XboxDot_' + $Key]
    if ($dot) { $dot.Fill = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))) }
    $tb = $script:ui['XboxText_' + $Key]
    if ($tb) { $tb.Text = $Text }
}

function Update-XboxStatus {
    $green = '#3CCB6A'; $yellow = '#F2C037'; $red = '#E5484D'
    $flat = @()
    try { $flat = @(Get-XboxFlat (Get-XboxStatus)) } catch { Write-GuiLog "[ERROR] Get-XboxStatus failed: $($_.Exception.Message)" }
    foreach ($key in $script:XboxKeys) {
        $match = $null
        $pat = switch ($key) { 'GameBar' { @('GameBar','*GamingOverlay*','*GameBar*') } 'GamingServices' { @('GamingServices','*GamingServices*') } default { @($key) } }
        foreach ($f in $flat) { foreach ($p in $pat) { if (-not $match -and ([string]$f.Name -like $p)) { $match = $f } } }
        if ($null -eq $match) { Set-XboxDot $key $red 'Not found'; continue }
        $installed = $true
        if ($match.PSObject.Properties['Installed']) { $installed = [bool]$match.Installed }
        $startup = ''; if ($match.PSObject.Properties['StartupType']) { $startup = [string]$match.StartupType }
        $status = ''; if ($match.PSObject.Properties['Status']) { $status = [string]$match.Status }
        if (-not $installed) { Set-XboxDot $key $red 'Not installed' }
        elseif ($startup -eq 'Disabled') { Set-XboxDot $key $red ('Disabled ' + $status).Trim() }
        elseif ($status -eq 'Running') { Set-XboxDot $key $green ('Running ' + $startup).Trim() }
        elseif ($startup -or $status) { Set-XboxDot $key $yellow (($startup + ' ' + $status).Trim()) }
        else { Set-XboxDot $key $green 'Installed' }
    }
}

function Start-XboxTask {
    param([string]$Name, [scriptblock]$Script, [switch]$SafetyNet)
    if ($SafetyNet) { Start-OptiTask -Name $Name -ScriptBlock $Script -SafetyNet -OnComplete { Update-XboxStatus } }
    else { Start-OptiTask -Name $Name -ScriptBlock $Script -OnComplete { Update-XboxStatus } }
}

function Confirm-Gui([string]$Text) {
    $r = [System.Windows.MessageBox]::Show($script:Window, $Text, 'StudentOpti', 'YesNo', 'Question')
    return ($r -eq 'Yes')
}

# ---- button wiring
$script:ui.BtnPresetStudentLaptop.Add_Click({ if (Confirm-Gui 'Apply the Student Laptop Boost preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: StudentLaptop' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id StudentLaptop } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetStudyBattery.Add_Click({ if (Confirm-Gui 'Apply the Study Battery Saver preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: StudyBattery' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id StudyBattery } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetGamingXbox.Add_Click({ if (Confirm-Gui 'Apply the Gaming / Xbox Ready preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: GamingXbox' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id GamingXbox } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetFactoryDefault.Add_Click({ if (Confirm-Gui 'Restore Windows defaults for everything StudentOpti can change? A restore point is created first.') { Start-OptiTask -Name 'Preset: FactoryDefault' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id FactoryDefault } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnRestorePoint.Add_Click({ Start-OptiTask -Name 'Create restore point' -ScriptBlock { New-OptiRestorePoint } })
$script:ui.BtnRestoreSnapshot.Add_Click({ if (Confirm-Gui 'Restore the most recent StudentOpti snapshot?') { Start-OptiTask -Name 'Restore last snapshot' -ScriptBlock { Restore-OptiStateSnapshot } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })

$script:ui.BtnDebloatApply.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.DebloatPanel -Action Apply })
$script:ui.BtnDebloatUndo.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.DebloatPanel -Action Undo })
$script:ui.BtnProcApply.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.ProcessTweaksPanel -Action Apply })
$script:ui.BtnProcUndo.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.ProcessTweaksPanel -Action Undo })
$script:ui.BtnSpeedApply.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.SpeedPanel -Action Apply })
$script:ui.BtnSpeedUndo.Add_Click({ Invoke-SelectedTweaks -Panel $script:ui.SpeedPanel -Action Undo })

$script:ui.BtnRemoveBloat.Add_Click({
    $apps = @()
    try { $apps = @(Get-OptiBloatApps) } catch { Write-GuiLog "[ERROR] $($_.Exception.Message)"; return }
    if ($apps.Count -eq 0) { Write-GuiLog 'No removable bloat apps found.'; return }
    $names = @($apps | ForEach-Object { if ($_.PSObject.Properties['Name']) { [string]$_.Name } else { [string]$_ } } | Select-Object -First 30)
    $msg = "Remove {0} safe bloat app(s)?`r`n`r`n{1}`r`n`r`nSchool, Office, Store, Xbox and system apps are protected." -f $apps.Count, ($names -join "`r`n")
    if (Confirm-Gui $msg) { Start-OptiTask -Name 'Remove bloat apps' -SafetyNet -ScriptBlock { Remove-OptiBloatApps } }
})
$script:ui.BtnRestoreApps.Add_Click({ Start-OptiTask -Name 'Restore removed apps' -ScriptBlock { Restore-OptiRemovedApps } })
$script:ui.BtnCleanTemp.Add_Click({ Start-OptiTask -Name 'Clean temp files' -ScriptBlock { Clear-OptiTempFiles } })

$script:ui.BtnSvcOptimize.Add_Click({ Start-OptiTask -Name 'Optimize recommended services' -SafetyNet -ScriptBlock { Invoke-OptiServiceOptimization } -OnComplete { Refresh-ServiceGrid } })
$script:ui.BtnSvcRevertAll.Add_Click({ if (Confirm-Gui 'Revert all services to their Windows defaults?') { Start-OptiTask -Name 'Revert all services' -SafetyNet -ScriptBlock { Invoke-OptiServiceOptimization -Revert } -OnComplete { Refresh-ServiceGrid } } })
$script:ui.BtnSvcRefresh.Add_Click({ Refresh-ServiceGrid })
$script:ui.ServiceGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource
    if ($btn -is [System.Windows.Controls.Button] -and $null -ne $btn.Tag) {
        $id = [string]$btn.Tag
        Start-OptiTask -Name "Revert service $id" -SafetyNet -ArgumentList @(,@($id)) -ScriptBlock { param($ids) Invoke-OptiServiceOptimization -Ids $ids -Revert } -OnComplete { Refresh-ServiceGrid }
    }
})

$script:ui.BtnPowerStudy.Add_Click({ Start-OptiTask -Name 'Power profile: Study' -ScriptBlock { Set-OptiPowerProfile -Profile Study } })
$script:ui.BtnPowerPerf.Add_Click({ Start-OptiTask -Name 'Power profile: Performance' -ScriptBlock { Set-OptiPowerProfile -Profile Performance } })
$script:ui.BtnPowerBalanced.Add_Click({ Start-OptiTask -Name 'Power profile: Balanced' -ScriptBlock { Set-OptiPowerProfile -Profile Balanced } })
$script:ui.BtnRestartExplorer.Add_Click({ Start-OptiTask -Name 'Restart Explorer' -ScriptBlock { Restart-OptiExplorer } })

$script:ui.BtnXboxEnabled.Add_Click({ Start-XboxTask -Name 'Xbox mode: Enabled' -SafetyNet -Script { Set-XboxMode -Mode Enabled } })
$script:ui.BtnXboxLite.Add_Click({ Start-XboxTask -Name 'Xbox mode: Lite' -SafetyNet -Script { Set-XboxMode -Mode Lite } })
$script:ui.BtnXboxDisabled.Add_Click({ Start-XboxTask -Name 'Xbox mode: Disabled' -SafetyNet -Script { Set-XboxMode -Mode Disabled } })
$script:ui.BtnXboxRefresh.Add_Click({ Update-XboxStatus })
$script:ui.BtnXboxEmergency.Add_Click({ Start-XboxTask -Name 'Emergency Xbox re-enable and repair' -Script { Restore-XboxFallback } })
$script:ui.BtnXboxDeep.Add_Click({ if (Confirm-Gui 'Deep repair re-registers and reinstalls the Xbox stack. This can take several minutes. Continue?') { Start-XboxTask -Name 'Deep Xbox repair' -Script { Restore-XboxFallback -Deep } } })
$script:ui.BtnXboxScript.Add_Click({ Start-XboxTask -Name 'Install emergency script on Desktop' -Script { Install-XboxEmergencyScript } })

# ---- startup / shutdown
$script:Window.Add_Loaded({
    $admin = $false
    try { $admin = [bool](Test-OptiAdmin) } catch { }
    if ($admin) {
        $script:ui.AdminText.Text = 'Administrator'
        $script:ui.AdminDot.Fill = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#3CCB6A')))
    } else {
        $script:ui.AdminText.Text = 'Not elevated - changes will fail'
        $script:ui.AdminDot.Fill = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E5484D')))
    }
    Update-OptiDashboard
    Refresh-TweakPanels
    Refresh-ServiceGrid
    Update-XboxStatus
    $script:LogTimer.Start()
    $script:DashTimer.Start()
    Write-GuiLog 'StudentOpti ready.'
})
$script:Window.Add_Closing({
    $script:LogTimer.Stop(); $script:DashTimer.Stop()
    foreach ($t in @($script:Tasks)) { try { $t.PS.Stop(); $t.PS.Dispose(); $t.RS.Dispose() } catch { } }
})

[void]$script:Window.ShowDialog()
exit 0
