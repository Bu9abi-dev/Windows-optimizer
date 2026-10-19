#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5 tests for StudentOpti. Run: Invoke-Pester tests/Optimizer.Tests.ps1
# Windows PowerShell 5.1 and PowerShell 7 (Linux/macOS/Windows).

BeforeDiscovery {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Skip = (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core')   # reserved for Windows-only checks
    function Read-JsonFile([string]$p) { [IO.File]::ReadAllText($p) | ConvertFrom-Json }
    $script:ConfigFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'config') -Filter *.json -File |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $t = Read-JsonFile (Join-Path $script:Root 'config/tweaks.json')
    $s = Read-JsonFile (Join-Path $script:Root 'config/services.json')
    $script:ItemCases = @()
    foreach ($i in @($t.tweaks)) { $script:ItemCases += @{ File = 'tweaks'; Id = $i.id; Item = $i } }
    foreach ($i in @($s.services)) { $script:ItemCases += @{ File = 'services'; Id = $i.id; Item = $i } }
    $p = Read-JsonFile (Join-Path $script:Root 'config/presets.json')
    $script:PresetCases = @(@($p.presets) | ForEach-Object { @{ Id = $_.id; Preset = $_ } })
    $script:Ps1Cases = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter *.ps1 -File |
        ForEach-Object { @{ Rel = $_.FullName.Substring($script:Root.Length).TrimStart('\', '/'); Path = $_.FullName } })
    $script:WlCases = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsCalculator',
        'Microsoft.WindowsTerminal', 'Microsoft.ScreenSketch', 'Microsoft.XboxIdentityProvider' | ForEach-Object { @{ Pkg = $_ } })
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    function Read-JsonFile([string]$p) { [IO.File]::ReadAllText($p) | ConvertFrom-Json }
    $script:Tweaks = @((Read-JsonFile (Join-Path $script:Root 'config/tweaks.json')).tweaks)
    $script:ServicesCfg = Read-JsonFile (Join-Path $script:Root 'config/services.json')
    $script:Services = @($script:ServicesCfg.services)
    $script:Appx = Read-JsonFile (Join-Path $script:Root 'config/appx_bloat.json')
    $script:Presets = @((Read-JsonFile (Join-Path $script:Root 'config/presets.json')).presets)
    . (Join-Path $script:Root 'modules/Common.ps1')
    . (Join-Path $script:Root 'modules/Xbox-Controller.ps1')
}

Describe 'Config files' {
    It '<Name> parses as JSON' -ForEach $script:ConfigFiles {
        { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } | Should -Not -Throw
    }

    It '<File>/<Id> has all required fields' -ForEach $script:ItemCases {
        foreach ($p in 'id', 'name', 'category', 'description', 'risk_level', 'check_script', 'apply_script', 'undo_script', 'registry', 'requires_restart') {
            $Item.PSObject.Properties.Name | Should -Contain $p
        }
        foreach ($p in 'id', 'name', 'category', 'description', 'check_script', 'apply_script', 'undo_script') {
            [string]::IsNullOrWhiteSpace([string]$Item.$p) | Should -BeFalse -Because "$p must not be empty"
        }
        'Safe', 'Moderate', 'Caution' | Should -Contain $Item.risk_level
        , $Item.registry | Should -BeOfType ([array])
        $Item.requires_restart | Should -Not -BeNullOrEmpty
    }

    It '<File>/<Id> scripts parse without errors' -ForEach $script:ItemCases {
        foreach ($k in 'check_script', 'apply_script', 'undo_script') {
            $tokens = $null; $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput([string]$Item.$k, [ref]$tokens, [ref]$errs)
            @($errs).Count | Should -Be 0 -Because "$k : $(@($errs) | ForEach-Object { $_.Message })"
        }
    }

    It 'ids are unique across tweaks.json and services.json' {
        $ids = @($script:Tweaks | ForEach-Object { $_.id }) + @($script:Services | ForEach-Object { $_.id })
        $dups = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $dups.Count | Should -Be 0 -Because ($dups -join ', ')
    }

    It 'preset <Id> references existing ids and valid modes' -ForEach $script:PresetCases {
        $tw = @($script:Tweaks | ForEach-Object { $_.id })
        $sv = @($script:Services | ForEach-Object { $_.id })
        foreach ($i in @($Preset.tweaks)) { if ($i) { $tw | Should -Contain $i } }
        foreach ($i in @($Preset.services)) { if ($i) { $sv | Should -Contain $i } }
        if ($Preset.xbox_mode) { 'Enabled', 'Lite', 'Disabled' | Should -Contain $Preset.xbox_mode }
        if ($Preset.power_profile) { 'Study', 'Performance', 'Balanced' | Should -Contain $Preset.power_profile }
    }
}

Describe 'Repository scripts' {
    It '<Rel> parses without errors' -ForEach $script:Ps1Cases {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
        @($errs).Count | Should -Be 0 -Because (@($errs) | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" })
    }
    It 'ui/MainWindow.xaml is well-formed XML (when present)' {
        $x = Join-Path $script:Root 'ui/MainWindow.xaml'
        if (Test-Path -LiteralPath $x) { { [xml](Get-Content -LiteralPath $x -Raw) } | Should -Not -Throw }
    }
}

Describe 'Whitelist and protected services' {
    It 'no safe_to_remove pattern overlaps a whitelist or xbox pattern' {
        $others = @($script:Appx.protected_whitelist) + @($script:Appx.xbox | ForEach-Object { $_.pattern })
        $bad = @()
        foreach ($s in @($script:Appx.safe_to_remove)) {
            foreach ($w in $others) { if ($s.pattern -like $w -or $w -like $s.pattern) { $bad += "$($s.pattern) <-> $w" } }
        }
        $bad.Count | Should -Be 0 -Because ($bad -join '; ')
    }
    It 'whitelist contains <Pkg>' -ForEach $script:WlCases {
        @($script:Appx.protected_whitelist) | Should -Contain $Pkg
    }
    It 'no services.json item targets a protected service' {
        $prot = @(Get-OptiProtectedServices)
        $bad = @($script:Services | Where-Object { $prot -contains $_.service } | ForEach-Object { $_.service })
        $bad.Count | Should -Be 0 -Because ($bad -join ', ')
    }
    It 'critical services are not in services.json and never Disabled/Manual in apply_script' {
        $crit = 'BFE', 'Dhcp', 'Dnscache', 'RpcSs', 'SecurityHealthService'
        @($script:Services | Where-Object { $crit -contains $_.service }).Count | Should -Be 0
        $bad = @()
        foreach ($i in @($script:Tweaks) + @($script:Services)) {
            foreach ($c in $crit) { if ($i.apply_script -match "\b$c\b" -and $i.apply_script -match 'Disabled|Manual') { $bad += "$($i.id):$c" } }
        }
        $bad.Count | Should -Be 0 -Because ($bad -join ', ')
    }
    It 'Set-OptiServiceStartup refuses to disable BFE' {
        { Set-OptiServiceStartup -Name 'BFE' -StartupType Disabled } | Should -Throw
    }
}

Describe 'Restore-Xbox-Emergency.bat' {
    BeforeAll { $script:BatPath = Join-Path $script:Root 'Restore-Xbox-Emergency.bat' }
    It 'resets the four core services with start= demand' {
        $txt = [IO.File]::ReadAllText($script:BatPath)
        $txt | Should -Match 'start= demand'
        foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') {
            $txt | Should -Match "(?s)for %%S in \([^)]*\b$s\b[^)]*\)[^\r\n]*\r?\n[^\r\n]*start= demand"
        }
    }
    It 'uses CRLF line endings only' {
        $b = [IO.File]::ReadAllBytes($script:BatPath)
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10) { $lf++; if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } } }
        $lf | Should -BeGreaterThan 0
        $crlf | Should -Be $lf
    }
}

Describe 'Xbox state machine (in-memory fakes)' {
    BeforeAll {
        $global:FX = @{ Reg = @{}; Status = @{}; Tmp = $null }
        $script:RootForFake = $script:Root
        # Defined after dot-sourcing the modules so they replace the real implementations.
        function Get-FxKey($Path, $Name) { return ('{0}|{1}' -f ([string]$Path).ToLowerInvariant(), ([string]$Name).ToLowerInvariant()) }
        function Write-OptiLog { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message, [string]$Level = 'Info') }
        function Get-OptiBackupDir { return $global:FX.Tmp }
        function Get-OptiConfig { param([string]$Name) return ([IO.File]::ReadAllText((Join-Path $global:FX.Root "config/$Name.json")) | ConvertFrom-Json) }
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
        function Get-FxStart($n) { Get-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name 'Start' }
        $script:Core = 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc'
    }
    BeforeEach {
        $global:FX.Root = $script:Root
        $global:FX.Reg = @{}; $global:FX.Status = @{}
        $global:FX.Tmp = Join-Path $TestDrive ('bk' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($global:FX.Tmp)
        if (-not $env:SystemRoot) { $env:SystemRoot = [IO.Path]::GetTempPath() }
        foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'GamingServicesNet', 'BcastDVRUserService') {
            Set-OptiRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name 'Start' -Value 3
        }
        Set-OptiRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\GamingServices' -Name 'Start' -Value 2
    }
    AfterAll { Remove-Variable -Name FX -Scope Global -ErrorAction SilentlyContinue }

    It 'starts in Enabled mode' { Get-XboxCurrentMode | Should -Be 'Enabled' }

    It 'Enabled keeps the core four Manual' {
        Set-XboxMode -Mode Enabled
        foreach ($s in $script:Core) { Get-OptiServiceStartup $s | Should -Be 'Manual' }
        Get-XboxCurrentMode | Should -Be 'Enabled'
    }

    It 'Disabled disables services, sets DVR keys and writes both snapshots' {
        Set-XboxMode -Mode Disabled
        foreach ($s in $script:Core) { Get-OptiServiceStartup $s | Should -Be 'Disabled' }
        Get-OptiRegistry 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' | Should -Be 0
        Get-OptiRegistry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' | Should -Be 0
        Get-XboxCurrentMode | Should -Be 'Disabled'
        Join-Path $global:FX.Tmp 'xbox_fallback.json' | Should -Exist
        $orig = Join-Path $global:FX.Tmp 'xbox_fallback_original.json'
        $orig | Should -Exist
        $o = [IO.File]::ReadAllText($orig) | ConvertFrom-Json
        @($o.Services | Where-Object { $_.Service -eq 'XblAuthManager' })[0].Start | Should -Be 3
    }

    It 'original snapshot survives later mode switches' {
        Set-XboxMode -Mode Disabled
        Set-XboxMode -Mode Enabled
        $o = [IO.File]::ReadAllText((Join-Path $global:FX.Tmp 'xbox_fallback_original.json')) | ConvertFrom-Json
        @($o.Services | Where-Object { $_.Service -eq 'XblGameSave' })[0].Start | Should -Be 3
    }

    It 'Restore-XboxFallback returns services to Manual and removes AllowGameDVR' {
        Set-XboxMode -Mode Disabled
        Restore-XboxFallback
        foreach ($s in $script:Core) { Get-FxStart $s | Should -Be 3 }
        Get-OptiRegistry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' | Should -BeNullOrEmpty
        Get-XboxCurrentMode | Should -Be 'Enabled'
    }

    It 'Lite keeps services Manual and turns AppCaptureEnabled off' {
        Set-XboxMode -Mode Lite
        foreach ($s in $script:Core) { Get-OptiServiceStartup $s | Should -Be 'Manual' }
        Get-OptiRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' | Should -Be 0
        Get-XboxCurrentMode | Should -Be 'Lite'
    }

    It 'Get-XboxCurrentMode follows Enabled -> Lite -> Disabled -> Enabled' {
        Set-XboxMode -Mode Enabled; Get-XboxCurrentMode | Should -Be 'Enabled'
        Set-XboxMode -Mode Lite; Get-XboxCurrentMode | Should -Be 'Lite'
        Set-XboxMode -Mode Disabled; Get-XboxCurrentMode | Should -Be 'Disabled'
        Set-XboxMode -Mode Enabled; Get-XboxCurrentMode | Should -Be 'Enabled'
    }
}
