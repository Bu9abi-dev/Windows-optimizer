# Validate-Repo.ps1 - dependency-free repo validation (no Pester). Exit code 1 on any failure.
# Works on Windows PowerShell 5.1 and PowerShell 7 (Linux/macOS/Windows).
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:Pass = 0; $script:Fail = 0

function Assert-True($Cond, $Msg = 'condition was false') { if (-not $Cond) { throw $Msg } }
function Assert-Equal($Actual, $Expected, $Msg = '') {
    if ("$Actual" -ne "$Expected") { throw "expected '$Expected' but got '$Actual' $Msg" }
}
function Assert-Throws([scriptblock]$Code, $Msg = 'expected an exception') {
    $threw = $false
    try { & $Code } catch { $threw = $true }
    if (-not $threw) { throw $Msg }
}
function Check([string]$Name, [scriptblock]$Code) {
    try {
        & $Code
        $script:Pass++
        if (-not $Quiet) { Write-Host "PASS  $Name" -ForegroundColor Green }
    } catch {
        $script:Fail++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
function Get-ParseErrors([string]$Code) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errs)
    return @($errs)
}

# ---------------------------------------------------------------- repo-wide syntax
$ps1Files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File)
foreach ($f in $ps1Files) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
    Check "parse $rel" {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        Assert-Equal @($errs).Count 0 (($errs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
    }
}
$xaml = Join-Path $Root 'ui/MainWindow.xaml'
if (Test-Path -LiteralPath $xaml) {
    Check 'ui/MainWindow.xaml is well-formed XML' { $x = [xml](Get-Content -LiteralPath $xaml -Raw); Assert-True ($null -ne $x.DocumentElement) }
}

# ---------------------------------------------------------------- config
$cfgDir = Join-Path $Root 'config'
$cfg = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $cfgDir -Filter *.json -File)) {
    Check "config/$($f.Name) parses" { $null = Read-Json $f.FullName; $cfg[$f.BaseName] = Read-Json $f.FullName }
}
$tweaks = @($cfg['tweaks'].tweaks)
$services = @($cfg['services'].services)
$validRisk = 'Safe', 'Moderate', 'Caution'
$required = 'id', 'name', 'category', 'description', 'risk_level', 'check_script', 'apply_script', 'undo_script', 'registry', 'requires_restart'
$items = @()
foreach ($t in $tweaks) { $items += [pscustomobject]@{ File = 'tweaks'; Item = $t } }
foreach ($s in $services) { $items += [pscustomobject]@{ File = 'services'; Item = $s } }

Check 'tweaks.json and services.json contain items' { Assert-True ($tweaks.Count -gt 0 -and $services.Count -gt 0) }

foreach ($e in $items) {
    $it = $e.Item
    Check "$($e.File)/$($it.id) required fields" {
        foreach ($p in $required) {
            Assert-True ($it.PSObject.Properties.Name -contains $p) "missing field '$p'"
        }
        foreach ($p in 'id', 'name', 'category', 'description', 'check_script', 'apply_script', 'undo_script') {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$it.$p)) "field '$p' is empty"
        }
        Assert-True ($validRisk -contains $it.risk_level) "bad risk_level '$($it.risk_level)'"
        Assert-True ($it.registry -is [array]) 'registry must be an array'
        Assert-True ($it.PSObject.Properties.Name -contains 'requires_restart' -and $it.requires_restart) 'requires_restart empty'
    }
    foreach ($k in 'check_script', 'apply_script', 'undo_script') {
        Check "$($e.File)/$($it.id) $k parses" {
            $errs = Get-ParseErrors ([string]$it.$k)
            Assert-Equal $errs.Count 0 (($errs | ForEach-Object { $_.Message }) -join '; ')
        }
    }
}

Check 'ids unique across tweaks.json and services.json' {
    $dups = @($items | ForEach-Object { $_.Item.id } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-Equal $dups.Count 0 "duplicate ids: $($dups -join ', ')"
}

# ---------------------------------------------------------------- presets
$allIds = @($items | ForEach-Object { $_.Item.id })
foreach ($p in @($cfg['presets'].presets)) {
    Check "preset $($p.id) references valid ids/modes" {
        foreach ($id in @($p.tweaks) + @($p.services)) {
            if ($id) { Assert-True ($allIds -contains $id) "unknown id '$id'" }
        }
        foreach ($id in @($p.tweaks)) { if ($id) { Assert-True (@($tweaks | Where-Object { $_.id -eq $id }).Count -eq 1) "'$id' is not a tweak" } }
        foreach ($id in @($p.services)) { if ($id) { Assert-True (@($services | Where-Object { $_.id -eq $id }).Count -eq 1) "'$id' is not a service" } }
        if ($p.xbox_mode) { Assert-True ('Enabled', 'Lite', 'Disabled' -contains $p.xbox_mode) "bad xbox_mode '$($p.xbox_mode)'" }
        if ($p.power_profile) { Assert-True ('Study', 'Performance', 'Balanced' -contains $p.power_profile) "bad power_profile '$($p.power_profile)'" }
    }
}
Check 'presets.json defines the four contract presets' {
    $ids = @($cfg['presets'].presets | ForEach-Object { $_.id })
    foreach ($n in 'StudentLaptop', 'StudyBattery', 'GamingXbox', 'FactoryDefault') { Assert-True ($ids -contains $n) "missing preset $n" }
}

# ---------------------------------------------------------------- whitelist / protected services
. (Join-Path $Root 'modules/Common.ps1')
. (Join-Path $Root 'modules/Xbox-Controller.ps1')

$appx = $cfg['appx_bloat']
$whitelist = @($appx.protected_whitelist)
$xboxPatterns = @($appx.xbox | ForEach-Object { $_.pattern })
Check 'no safe_to_remove pattern matches a whitelist or xbox pattern' {
    $bad = @()
    foreach ($s in @($appx.safe_to_remove)) {
        foreach ($w in $whitelist + $xboxPatterns) {
            if ($s.pattern -like $w -or $w -like $s.pattern) { $bad += "$($s.pattern) <-> $w" }
        }
    }
    Assert-Equal $bad.Count 0 ($bad -join '; ')
}
foreach ($n in 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsCalculator', 'Microsoft.WindowsTerminal', 'Microsoft.ScreenSketch', 'Microsoft.XboxIdentityProvider') {
    Check "whitelist contains $n" { Assert-True ($whitelist -contains $n) "$n missing from protected_whitelist" }
}
$protected = @(Get-OptiProtectedServices)
Check 'no services.json item targets a protected service' {
    $bad = @($services | Where-Object { $protected -contains $_.service } | ForEach-Object { $_.service })
    Assert-Equal $bad.Count 0 ($bad -join ', ')
}
$critical = 'BFE', 'Dhcp', 'Dnscache', 'RpcSs', 'SecurityHealthService'
Check 'critical services never appear in services.json' {
    $bad = @($services | Where-Object { $critical -contains $_.service } | ForEach-Object { $_.service })
    Assert-Equal $bad.Count 0 ($bad -join ', ')
}
Check 'no apply_script disables/manuals a critical service' {
    $bad = @()
    foreach ($e in $items) {
        $txt = [string]$e.Item.apply_script
        foreach ($c in $critical) {
            if ($txt -match "\b$c\b" -and $txt -match 'Disabled|Manual') { $bad += "$($e.Item.id):$c" }
        }
    }
    Assert-Equal $bad.Count 0 ($bad -join ', ')
}
Check 'Set-OptiServiceStartup throws for BFE Disabled' {
    Assert-Throws { Set-OptiServiceStartup -Name 'BFE' -StartupType Disabled }
}

# ---------------------------------------------------------------- emergency bat
$bat = Join-Path $Root 'Restore-Xbox-Emergency.bat'
Check 'Restore-Xbox-Emergency.bat has CRLF line endings only' {
    $bytes = [IO.File]::ReadAllBytes($bat)
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) { $lf++; if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
    }
    Assert-True ($lf -gt 0) 'no line breaks'
    Assert-Equal $crlf $lf 'bare LF found'
}
Check 'Restore-Xbox-Emergency.bat sets the four core services to start= demand' {
    $txt = [IO.File]::ReadAllText($bat)
    Assert-True ($txt -match 'start= demand') 'no "start= demand"'
    foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') {
        Assert-True ($txt -match "(?s)for %%S in \([^)]*\b$s\b[^)]*\)[^\r\n]*\r?\n[^\r\n]*start= demand") "$s not covered by a start= demand loop"
    }
}

# ---------------------------------------------------------------- Xbox state machine (in-memory fakes)
# Defined AFTER dot-sourcing so these later definitions win over the real implementations.
$global:FX = @{ Reg = @{}; Status = @{}; Tmp = $null }
function Get-FxKey($Path, $Name) { return ('{0}|{1}' -f ([string]$Path).ToLowerInvariant(), ([string]$Name).ToLowerInvariant()) }
function Write-OptiLog { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message, [string]$Level = 'Info') }
function Get-OptiBackupDir { return $global:FX.Tmp }
function Get-OptiConfig { param([string]$Name) return (Read-Json (Join-Path $Root "config/$Name.json")) }
function Get-OptiRegistry { param([string]$Path, [string]$Name)
    $k = Get-FxKey $Path $Name
    if ($global:FX.Reg.ContainsKey($k)) { return $global:FX.Reg[$k] }
    return $null
}
function Set-OptiRegistry { [CmdletBinding(SupportsShouldProcess)] param([string]$Path, [string]$Name, $Value, [string]$Type = 'String')
    $global:FX.Reg[(Get-FxKey $Path $Name)] = $Value
}
function Remove-OptiRegistry { [CmdletBinding(SupportsShouldProcess)] param([string]$Path, [string]$Name)
    if ($Name) { $global:FX.Reg.Remove((Get-FxKey $Path $Name)) }
    else { $pre = ([string]$Path).ToLowerInvariant() + '|'; foreach ($k in @($global:FX.Reg.Keys)) { if ($k.StartsWith($pre)) { $global:FX.Reg.Remove($k) } } }
}
function Get-OptiServiceStartup { param([string]$Name)
    $s = Get-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start'
    if ($null -eq $s) { return 'NotInstalled' }
    switch ([int]$s) { 0 { 'Boot' } 1 { 'System' } 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { 'Manual' } }
}
function Set-OptiServiceStartup { [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$StartupType, [switch]$StopIfDisabled, [switch]$IncludeUserInstances)
    if ((Get-OptiProtectedServices) -contains $Name -and ($StartupType -eq 'Manual' -or $StartupType -eq 'Disabled')) { throw "Service '$Name' is protected" }
    if ((Get-OptiServiceStartup -Name $Name) -eq 'NotInstalled') { return }
    $v = @{ Automatic = 2; AutomaticDelayed = 2; Manual = 3; Disabled = 4 }[$StartupType]
    Set-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start' -Value $v -Type DWord
}
function Get-Service { [CmdletBinding()] param([string]$Name)
    if ($Name -like '*`**' -or $Name -like '*_*') { return $null }
    if ((Get-OptiServiceStartup -Name $Name) -eq 'NotInstalled') { return $null }
    $st = 'Stopped'; if ($global:FX.Status.ContainsKey($Name)) { $st = $global:FX.Status[$Name] }
    return [pscustomobject]@{ Name = $Name; Status = $st }
}
function Start-Service { [CmdletBinding()] param([string]$Name) $global:FX.Status[$Name] = 'Running' }
function Stop-Service { [CmdletBinding()] param([string]$Name, [switch]$Force) $global:FX.Status[$Name] = 'Stopped' }
function Get-Process { [CmdletBinding()] param([string]$Name) return $null }
function Get-AppxPackage { [CmdletBinding()] param([string]$Name, [switch]$AllUsers) return $null }

function Reset-Fakes {
    $global:FX.Reg = @{}; $global:FX.Status = @{}
    $global:FX.Tmp = Join-Path ([IO.Path]::GetTempPath()) ('opti-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($global:FX.Tmp)
    if (-not $env:SystemRoot) { $env:SystemRoot = [IO.Path]::GetTempPath() }
    foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'GamingServicesNet', 'BcastDVRUserService') {
        Set-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name 'Start' -Value 3
    }
    Set-OptiRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\GamingServices' -Name 'Start' -Value 2
}
function Get-Start($n) { Get-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name 'Start' }
$core = 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc'
$gdvr = 'HKCU:\System\GameConfigStore'
$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
$capture = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'

Check 'Xbox: initial mode is Enabled' { Reset-Fakes; Assert-Equal (Get-XboxCurrentMode) 'Enabled' }
Check 'Xbox: Set-XboxMode Enabled -> core four Manual' {
    Reset-Fakes; Set-XboxMode -Mode Enabled
    foreach ($s in $core) { Assert-Equal (Get-OptiServiceStartup $s) 'Manual' $s }
    Assert-Equal (Get-XboxCurrentMode) 'Enabled'
}
Check 'Xbox: Set-XboxMode Disabled -> services Disabled, DVR keys, snapshots' {
    Reset-Fakes; Set-XboxMode -Mode Disabled
    foreach ($s in $core) { Assert-Equal (Get-OptiServiceStartup $s) 'Disabled' $s }
    Assert-Equal (Get-OptiRegistry $gdvr 'GameDVR_Enabled') 0
    Assert-Equal (Get-OptiRegistry $policy 'AllowGameDVR') 0
    Assert-Equal (Get-XboxCurrentMode) 'Disabled'
    $latest = Join-Path $global:FX.Tmp 'xbox_fallback.json'
    $orig = Join-Path $global:FX.Tmp 'xbox_fallback_original.json'
    Assert-True (Test-Path $latest) 'xbox_fallback.json missing'
    Assert-True (Test-Path $orig) 'xbox_fallback_original.json missing'
    $o = [IO.File]::ReadAllText($orig) | ConvertFrom-Json
    $hit = @($o.Services | Where-Object { $_.Service -eq 'XblAuthManager' })[0]
    Assert-Equal $hit.Start 3 'original snapshot should record Start=3'
}
Check 'Xbox: original snapshot is not overwritten by later switches' {
    Reset-Fakes; Set-XboxMode -Mode Disabled; Set-XboxMode -Mode Enabled
    $o = [IO.File]::ReadAllText((Join-Path $global:FX.Tmp 'xbox_fallback_original.json')) | ConvertFrom-Json
    $hit = @($o.Services | Where-Object { $_.Service -eq 'XblGameSave' })[0]
    Assert-Equal $hit.Start 3
}
Check 'Xbox: Restore-XboxFallback after Disabled -> Manual, AllowGameDVR removed' {
    Reset-Fakes; Set-XboxMode -Mode Disabled; Restore-XboxFallback
    foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') { Assert-Equal (Get-Start $s) 3 $s }
    Assert-True ($null -eq (Get-OptiRegistry $policy 'AllowGameDVR')) 'AllowGameDVR still present'
    Assert-Equal (Get-XboxCurrentMode) 'Enabled'
}
Check 'Xbox: Set-XboxMode Lite -> Manual + AppCaptureEnabled 0' {
    Reset-Fakes; Set-XboxMode -Mode Lite
    foreach ($s in $core) { Assert-Equal (Get-OptiServiceStartup $s) 'Manual' $s }
    Assert-Equal (Get-OptiRegistry $capture 'AppCaptureEnabled') 0
    Assert-Equal (Get-XboxCurrentMode) 'Lite'
}
Check 'Xbox: mode round trip Enabled -> Lite -> Disabled -> Enabled' {
    Reset-Fakes
    Set-XboxMode -Mode Enabled; Assert-Equal (Get-XboxCurrentMode) 'Enabled'
    Set-XboxMode -Mode Lite; Assert-Equal (Get-XboxCurrentMode) 'Lite'
    Set-XboxMode -Mode Disabled; Assert-Equal (Get-XboxCurrentMode) 'Disabled'
    Set-XboxMode -Mode Enabled; Assert-Equal (Get-XboxCurrentMode) 'Enabled'
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail -gt 0) { exit 1 }
exit 0
