# StudentOpti internal contract

Every file in this repo follows this contract so modules can be written independently.

## Runtime
- Windows PowerShell 5.1 compatible (also runs on 7.x). No external modules. No `?.`, `??`, ternary, or `-Parallel`.
- All scripts are dot-sourced by `StudentOpti.ps1` in this order: `modules/Common.ps1`, `Backup-Manager.ps1`, `Debloat-Engine.ps1`, `Process-Optimizer.ps1`, `Responsiveness-Engine.ps1`, `Xbox-Controller.ps1`.
- Module files only define functions (no top-level side effects), so they can be dot-sourced on Linux for tests.
- Every mutating function uses `[CmdletBinding(SupportsShouldProcess)]` and guards writes with `$PSCmdlet.ShouldProcess(...)`. Dry-run = `$WhatIfPreference = $true` set by the entry point.
- Data dir: `$env:LOCALAPPDATA\StudentOpti` (`Get-OptiDataDir`), backups in `...\backups` (`Get-OptiBackupDir`), logs in `...\logs`.
- Registry paths use PowerShell provider form: `HKCU:\...`, `HKLM:\...`.

## modules/Common.ps1 (helpers every module may call)
| Function | Behaviour |
| --- | --- |
| `Get-OptiRoot` | Repo root (parent of `modules`). Uses `$script:OptiRoot` if set, else `Split-Path $PSScriptRoot`. |
| `Get-OptiDataDir` / `Get-OptiBackupDir` | Create-on-demand dirs above (use `[IO.Directory]::CreateDirectory`, not affected by WhatIf). |
| `Write-OptiLog -Message -Level Info\|Warn\|Error\|Success` | Writes to host, appends to log file with `[IO.File]::AppendAllText`, and if `$global:OptiSync` (synchronized hashtable with `.Log` = `[System.Collections.Concurrent.ConcurrentQueue[string]]`) exists, enqueues the line for the GUI. |
| `Test-OptiAdmin` | `$true` when elevated. |
| `Get-OptiConfig -Name tweaks\|services\|appx_bloat\|presets` | Parses `config/<Name>.json` (cached in `$script:OptiConfigCache`). |
| `Get-OptiRegistry -Path -Name` | Value or `$null` if key/value missing. |
| `Set-OptiRegistry -Path -Name -Value -Type String\|DWord\|QWord\|Binary\|ExpandString` | Creates key if missing, sets value. ShouldProcess. |
| `Remove-OptiRegistry -Path [-Name]` | Removes value (or whole key when `-Name` omitted). No error when missing. ShouldProcess. |
| `Test-OptiRegistry -Path -Name -Value` | `$true` when current value equals `-Value` (`$null` means "absent"). Binary compares byte-wise. |
| `Get-OptiProtectedServices` | String array: `BFE, CryptSvc, DcomLaunch, Dhcp, Dnscache, EventSystem, gpsvc, RpcSs, RpcEptMapper, SecurityHealthService, SystemEventsBroker, WpnUserService, WinDefend, mpssvc, wuauserv, AppXSvc, ClipSVC, LSM, Power, ProfSvc, Schedule, Winmgmt` (hardcoded union with `services.json` `.protected`). |
| `Get-OptiServiceStartup -Name` | `'Automatic'`, `'AutomaticDelayed'`, `'Manual'`, `'Disabled'`, `'Boot'`, `'System'` or `'NotInstalled'`, read from `HKLM:\SYSTEM\CurrentControlSet\Services\<Name>` `Start` (+ `DelayedAutostart`). |
| `Set-OptiServiceStartup -Name -StartupType Automatic\|AutomaticDelayed\|Manual\|Disabled [-StopIfDisabled] [-IncludeUserInstances]` | Writes `Start` (2/3/4) and `DelayedAutostart` via registry (works for per-user service templates); `-IncludeUserInstances` also updates `<Name>_*` keys. Skips with a Warn log when NotInstalled. **Throws** if Name is protected and StartupType is Manual/Disabled. Stops service when Disabled + `-StopIfDisabled`. ShouldProcess. |
| `Invoke-OptiScript -Code <string>` | `& ([scriptblock]::Create($Code))` and returns output. |
| `Invoke-OptiTweak -Id -Action Check\|Apply\|Undo` | Looks up id in tweaks.json then services.json, runs that item's `check_script`/`apply_script`/`undo_script`. Check returns `[bool]`. Logs. |
| `Invoke-OptiPreset -Id [-SkipSafetyNet]` | Runs a preset from presets.json: safety net (`Invoke-OptiSafetyNet`), tweaks, services, appx, xbox mode, power profile, cleanup. FactoryDefault runs Undo on everything. |

## config/*.json schemas
`tweaks.json`: `{ "version": 1, "tweaks": [ Item ] }`
`services.json`: `{ "version": 1, "protected": [names], "services": [ Item + service fields ] }`
Item fields (all required): `id` (snake_case, unique across both files), `name`, `category` (`Privacy`, `AI`, `Debloat`, `Processes`, `Responsiveness`, `Power`, `Input`, `Services`, `Xbox`), `description`, `risk_level` (`Safe`\|`Moderate`\|`Caution`), `check_script`, `apply_script`, `undo_script` (PowerShell strings using only Common.ps1 helpers + built-ins), `registry` (array of `{ "path", "name" }` the item touches, used by snapshots; `[]` if none), `requires_restart` (`none`\|`explorer`\|`signout`\|`reboot`).
Service extra fields: `service` (service name), `default_startup`, `optimized_startup`, `optional` (bool: not in presets unless listed), `per_user` (bool), `xbox_modes` (only for category Xbox: `{ "Enabled": "...", "Lite": "...", "Disabled": "..." }`).
`undo_script` restores the **factory Windows default** (remove policy values that do not exist by default).
`appx_bloat.json`: `{ "version": 1, "safe_to_remove": [ {"name", "pattern", "category": "Consumer|OEM|AI", "description"} ], "protected_whitelist": [patterns], "xbox": [ {"name", "pattern", "store_id", "description"} ] }`. `pattern` is a `-like` wildcard. Xbox packages are never removed by the debloat engine.
`presets.json`: `{ "version": 1, "presets": [ { "id", "name", "description", "tweaks": [ids], "services": [ids], "remove_appx": bool, "xbox_mode": "Enabled|Lite|Disabled|null", "power_profile": "Study|Performance|Balanced|null", "cleanup": bool, "undo_all": bool } ] }`. Preset ids: `StudentLaptop`, `StudyBattery`, `GamingXbox`, `FactoryDefault`.

## Module public functions
- Backup-Manager: `New-OptiRestorePoint`, `New-OptiStateSnapshot [-Label]` (returns path), `Export-OptiRegistryHives`, `Restore-OptiStateSnapshot [-Path]` (latest if omitted), `Get-OptiSnapshots`, `Invoke-OptiSafetyNet` (restore point + snapshot + hive export, once per session via `$script:OptiSafetyNetDone`).
- Debloat-Engine: `Get-OptiBloatApps`, `Test-OptiAppxProtected -Name`, `Remove-OptiBloatApps [-Names] [-AllUsers]`, `Restore-OptiRemovedApps`, `Clear-OptiTempFiles [-IncludePrefetch]`, `Set-OptiAIFeatures -Disable|-Enable`.
- Process-Optimizer: `Get-OptiServiceReport` (objects: Id, Service, DisplayName, Status, CurrentStartup, DefaultStartup, OptimizedStartup, RiskLevel, Optional), `Invoke-OptiServiceOptimization [-Ids] [-Revert]`, `Get-OptiSvcHostThreshold` (recommended KB), `Get-OptiStartupItems`, `Set-OptiStartupItem -Name -Enabled $bool`, `Get-OptiDriveInfo` (IsSSD, RAMGB).
- Responsiveness-Engine: `Set-OptiPowerProfile -Profile Study|Performance|Balanced`, `Get-OptiActivePowerPlan`, `Restart-OptiExplorer`.
- Xbox-Controller: `Get-XboxStatus`, `Set-XboxMode -Mode Enabled|Lite|Disabled`, `Save-XboxFallbackSnapshot`, `Restore-XboxFallback [-Deep]`, `Install-XboxEmergencyScript`.
