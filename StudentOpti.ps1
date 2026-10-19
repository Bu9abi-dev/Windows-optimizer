<#
.SYNOPSIS
  StudentOpti - Windows optimizer for students. GUI by default, CLI with parameters.
.EXAMPLE
  .\StudentOpti.ps1 -Preset StudentLaptop -XboxMode Lite -Silent
#>
[CmdletBinding()]
param(
    [ValidateSet('StudentLaptop','StudyBattery','GamingXbox','FactoryDefault')]
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
    [switch]$CleanTemp
)

$ErrorActionPreference = 'Stop'
$script:OptiRoot = $PSScriptRoot
$script:ModuleFiles = @('Common.ps1','Backup-Manager.ps1','Debloat-Engine.ps1','Process-Optimizer.ps1','Responsiveness-Engine.ps1','Xbox-Controller.ps1')
foreach ($m in $script:ModuleFiles) {
    . (Join-Path (Join-Path $script:OptiRoot 'modules') $m)
}

if ($DryRun) { $global:WhatIfPreference = $true }

$cliAction = ($Preset -or $XboxMode -or $Tweaks -or $Undo -or $RestoreSnapshot -or $ListTweaks -or $CleanTemp)

# ---------------------------------------------------------------- CLI
function Invoke-OptiCli {
    $fail = $false
    $mutating = ($Preset -or $XboxMode -or $Tweaks -or $Undo -or $RestoreSnapshot -or $CleanTemp)

    if ($ListTweaks) {
        $rows = @()
        foreach ($t in @((Get-OptiConfig -Name tweaks).tweaks)) { $rows += [pscustomobject]@{ Id = $t.id; Category = $t.category; Risk = $t.risk_level; Name = $t.name } }
        foreach ($t in @((Get-OptiConfig -Name services).services)) { $rows += [pscustomobject]@{ Id = $t.id; Category = $t.category; Risk = $t.risk_level; Name = $t.name } }
        $rows | Sort-Object Category, Id | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        if (-not $mutating) { return 0 }
    }

    if ($mutating -and -not $DryRun -and -not (Test-OptiAdmin)) {
        Write-Host 'StudentOpti: administrator rights are required. Run Run-Optimizer.bat or an elevated PowerShell (or add -DryRun).' -ForegroundColor Red
        return 1
    }

    if ($mutating -and -not $NoRestorePoint -and -not $DryRun) {
        try { Invoke-OptiSafetyNet } catch { Write-OptiLog -Message "Safety net failed: $($_.Exception.Message)" -Level Warn }
    }

    if ($Preset) {
        try { Invoke-OptiPreset -Id $Preset -SkipSafetyNet } catch { Write-OptiLog -Message "Preset $Preset failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
    if ($XboxMode) {
        try {
            switch ($XboxMode) {
                'Repair'   { Restore-XboxFallback -Deep }
                'Enable'   { Set-XboxMode -Mode Enabled }
                'Disable'  { Set-XboxMode -Mode Disabled }
                default    { Set-XboxMode -Mode $XboxMode }
            }
        } catch { Write-OptiLog -Message "Xbox mode $XboxMode failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
    foreach ($id in @($Tweaks)) {
        if (-not $id) { continue }
        try { Invoke-OptiTweak -Id $id -Action Apply } catch { Write-OptiLog -Message "Tweak $id failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
    foreach ($id in @($Undo)) {
        if (-not $id) { continue }
        try { Invoke-OptiTweak -Id $id -Action Undo } catch { Write-OptiLog -Message "Undo $id failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
    if ($RestoreSnapshot) {
        try { Restore-OptiStateSnapshot } catch { Write-OptiLog -Message "Snapshot restore failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
    if ($CleanTemp) {
        try { Clear-OptiTempFiles } catch { Write-OptiLog -Message "Temp cleanup failed: $($_.Exception.Message)" -Level Error; $fail = $true }
    }
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

# ---------------------------------------------------------------- GUI
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $PSCommandPath))
    if ($DryRun) { $psArgs += '-DryRun' }
    if ($NoRestorePoint) { $psArgs += '-NoRestorePoint' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Sync = [hashtable]::Synchronized(@{})
$script:Sync.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Sync.Busy = 0
$global:OptiSync = $script:Sync
$script:Tasks = New-Object System.Collections.ArrayList
$script:SafetyDone = [bool]$NoRestorePoint

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
$script:ui.BtnPresetStudentLaptop.Add_Click({ if (Confirm-Gui 'Apply the Student Laptop Boost preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: StudentLaptop' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id StudentLaptop -SkipSafetyNet } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetStudyBattery.Add_Click({ if (Confirm-Gui 'Apply the Study Battery Saver preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: StudyBattery' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id StudyBattery -SkipSafetyNet } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetGamingXbox.Add_Click({ if (Confirm-Gui 'Apply the Gaming / Xbox Ready preset? A restore point is created first.') { Start-OptiTask -Name 'Preset: GamingXbox' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id GamingXbox -SkipSafetyNet } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
$script:ui.BtnPresetFactoryDefault.Add_Click({ if (Confirm-Gui 'Restore Windows defaults for everything StudentOpti can change? A restore point is created first.') { Start-OptiTask -Name 'Preset: FactoryDefault' -SafetyNet -ScriptBlock { Invoke-OptiPreset -Id FactoryDefault -SkipSafetyNet } -OnComplete { Refresh-TweakPanels; Refresh-ServiceGrid; Update-XboxStatus } } })
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
