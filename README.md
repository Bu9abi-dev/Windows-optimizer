# StudentOpti

StudentOpti is a free Windows 10/11 optimizer for students and shared laptops. It is PowerShell 5.1, so there is nothing extra to install. You run it from a console menu; the old window is still there if you want it.

## Quick start

1. Download or clone this repository and extract it to a folder.
2. Double-click `Run-Optimizer.bat`. It asks for administrator rights; click **Yes**.
3. Pick a preset from the menu. A restore point is created first (see Safety below).
4. Watch the live results. Each line is one step: `[ OK ]` done, `[SKIP]` nothing to do, `[FAIL]` failed, `[DRY ]` would run (dry run only).
5. At the end you get a summary and a restart prompt. Choose **Y** and you get a 10-second countdown (press any key to cancel), or **N** to restart later.

Other launchers:

- `Run-Optimizer.bat`: console menu (the main experience).
- `Run-Optimizer-GUI.bat`: opens the older WPF window.

## Presets

Presets are one-click bundles. They are defined in `config/presets.json`.

| Id | Name | Tiers included | Xbox | Power plan | What it does |
| --- | --- | --- | --- | --- | --- |
| `LightestWindows` | Lightest Windows | core, deep | Disabled (one-click fallback) | Balanced | Maximum debloat and background trimming for low-end laptops. Removes bloat apps, runs disk optimize, deep clean, browser cache, DISM cleanup, network flush, one RAM trim, startup trimming, hardware tuning and restore-point size limit. Skips the Caution-level extreme items. |
| `StrongestOptimizer` | Strongest Optimizer | core, deep, extreme | Lite | Performance (Ultimate) | Everything in Lightest Windows plus the extreme tier, which holds the Caution items. Also runs `windows_old` removal. Meant for plugged-in use. Read the list before you confirm. |
| `StudentLaptop` | Student Laptop Boost | (named items) | Lite | Balanced | Privacy, AI and responsiveness tweaks, bloat removal and cleanup. |
| `StudyBattery` | Study Battery Saver | (named items) | Disabled | Study | Student Laptop Boost plus background app and standby network savings. |
| `GamingXbox` | Gaming / Xbox Ready | (named items) | Enabled | Performance | Keeps Xbox working. Privacy and responsiveness tweaks, no bloat removal. |
| `FactoryDefault` | Restore Defaults | none (undo all) | Enabled | Balanced | Reverts every tweak, service and task to Windows defaults. |

**Tiers.** Every tweak, service and scheduled task has one tier:

- `core`: safe, everyday changes. 30 tweaks, 20 services, 11 tasks.
- `deep`: stronger changes that trade some background work for speed. 20 tweaks, 11 services, 8 tasks.
- `extreme`: the riskiest group, mostly Caution-rated. 10 tweaks, 9 services.

Lightest Windows never touches `extreme`. Strongest Optimizer uses all three tiers.

**Protected by the presets.** Even Strongest Optimizer leaves these alone:

- Print Spooler (`svc_spooler`). Disabling it means no printing.
- SysMain (`svc_sysmain`). It helps HDDs, so it is never switched off by a preset.
- Memory compression (`memory_compression_off`). It is only turned off on machines with 16 GB or more RAM, and only by hardware tuning. Below 16 GB it stays on.
- Any Xbox service. Xbox is controlled only by the Xbox setting in the preset (see "Xbox broke?").

Optional items like these only run when you name them yourself (for example `-Tweaks svc_spooler`).

## Safety

- **Restore point is mandatory.** Before any change, StudentOpti creates a Windows restore point and a state snapshot. If the restore point cannot be created, it stops and changes nothing.
- **System Protection must be on.** If it is off for drive C:, StudentOpti stops and tells you how to turn it on: press Win+R, open `sysdm.cpl`, go to the **System Protection** tab, click **Configure**, choose **Turn on**, then run StudentOpti again.
- **Dry run is the only exception.** `-DryRun` (or `D` in the menu) shows what would happen and changes nothing, so no restore point is needed.
- **Snapshots and backups.** State snapshots and `.reg` exports go to `%LOCALAPPDATA%\StudentOpti\backups`. Logs go to `%LOCALAPPDATA%\StudentOpti\logs`.
- **Every tweak has an undo.** Use `-Undo <id>` to revert one tweak, or `-RestoreSnapshot` to restore the last snapshot.
- **Protected apps and services.** A whitelist keeps important apps safe from removal. Core Windows services (such as WinDefend, Dhcp, and wuauserv) are never disabled.
- **Xbox apps are never removed.**
- **Scheduled tasks.** No task in `tasks.json` touches Windows Update or Windows Defender, and the built-in defrag task (`ScheduledDefrag`) is not in the list.

## Disk, RAM and cleanup

Open the menu and press **M** for "Disk, RAM & cleanup". You can choose several items by number, or `a` for every Safe and Moderate item. You can also run them from the command line with `-Maintenance`.

| Id | What it does | Risk |
| --- | --- | --- |
| `disk_optimize` | SSDs get ReTrim. HDDs get a defrag. StudentOpti never defragments an SSD. It also makes sure TRIM is on. | Safe |
| `deep_clean` | Temp files, thumbnails, shader cache, logs, crash dumps, Recycle Bin. | Safe |
| `browser_cache` | Clears the cache for Edge, Chrome, Brave and Firefox. | Safe |
| `component_cleanup` | Windows component store cleanup with DISM. Needs admin. | Safe |
| `windows_old` | Removes the `Windows.old` folder. Afterwards you cannot roll back to the previous Windows version. | Caution |
| `network_flush` | Flushes DNS, ARP and network caches. | Safe |
| `ram_trim` | Trims working sets and purges the standby list. This is a one-off boost; Windows refills its cache over time. Run it again whenever you want. | Safe |
| `startup_trim` | Disables a list of known non-essential startup items. Undo with `startup_undo`. | Moderate |
| `hardware_tuning` | Picks tweaks for your machine: memory compression off only on 16 GB+ RAM, and SysMain restored to Windows default on HDDs (it helps them). Protects low-RAM laptops from a disabled pagefile. | Moderate |
| `restore_size` | Limits restore point storage to 5% of the drive. Undo with `restore_size_undo`. | Moderate |

Also available: `pagefile_managed` and `pagefile_fixed` (set the pagefile to system managed or to 1.5x RAM; both are Caution). They take effect after a restart.

**DISM and ResetBase.** `component_cleanup` runs DISM's standard cleanup. The stronger `component_cleanup_resetbase` also removes old update versions, so those updates can no longer be uninstalled. It is not in any preset.

## Command line

Run these from an elevated PowerShell in the project folder. Each flag is in the `param()` block of `StudentOpti.ps1`.

| Flag | What it does |
| --- | --- |
| `-Preset <id>` | Apply a preset: `LightestWindows`, `StrongestOptimizer`, `StudentLaptop`, `StudyBattery`, `GamingXbox`, `FactoryDefault`. |
| `-XboxMode <mode>` | `Enable`, `Enabled`, `Lite`, `Disable`, `Disabled`, or `Repair` (Deep Repair of Xbox apps). |
| `-Tweaks <id[,id]>` | Apply specific tweaks by id. |
| `-Undo <id[,id]>` | Undo specific tweaks by id. |
| `-Maintenance <id[,id]>` | Run maintenance actions by id (see the table above). |
| `-CleanTemp` | Clear temp files. |
| `-RestoreSnapshot` | Restore the most recent StudentOpti snapshot. |
| `-ListTweaks` | List every tweak, service and task with its id, category, risk and tier. |
| `-DryRun` | Show what would happen; change nothing. No restore point is needed. |
| `-Yes` | Skip the Y/N confirmations. |
| `-Silent` | Headless run. Also implies `-NoRestartPrompt`. |
| `-NoRestartPrompt` | Do not ask to restart at the end. |
| `-NoRestorePoint` | Ignored. The restore point is always required. |
| `-Gui` | Open the older WPF window. |

Examples:

```powershell
.\StudentOpti.ps1                                    # console menu
.\StudentOpti.ps1 -Preset LightestWindows -Yes
.\StudentOpti.ps1 -Preset StrongestOptimizer -DryRun
.\StudentOpti.ps1 -Maintenance disk_optimize,deep_clean,ram_trim -Yes
.\StudentOpti.ps1 -Preset StudentLaptop -XboxMode Lite -Silent
.\StudentOpti.ps1 -ListTweaks
.\StudentOpti.ps1 -Undo copilot
```

## Xbox broke?

1. Right-click `Restore-Xbox-Emergency.bat` and run it as administrator. It re-enables the Xbox services and restores the Game DVR settings.
2. If Xbox apps are still missing, run `.\StudentOpti.ps1 -XboxMode Repair`. This is the Deep Repair. It reinstalls missing Xbox apps through winget and the Microsoft Store.
3. As a last resort, install "Xbox" and "Gaming Services" from the Microsoft Store.

## What it changes

The catalog has 119 items. Each one has a check, an apply step and an undo step.

| Source | Items | Safe | Moderate | Caution |
| --- | --- | --- | --- | --- |
| `config/tweaks.json` | 60 | 39 | 14 | 7 |
| `config/services.json` | 40 | 18 | 17 | 5 |
| `config/tasks.json` | 19 | 17 | 2 | 0 |

Areas covered: privacy and AI (telemetry, Recall, Copilot, advertising ID), responsiveness (menus, shutdown, visual effects, power plans), services and scheduled tasks, Xbox modes, bloat app removal, and the disk, RAM and cleanup items above.

## Project layout

```
windows-optimizer/
├── StudentOpti.ps1            Entry point: console menu by default, flags for headless runs, -Gui for the window
├── Run-Optimizer.bat          Asks for admin, then opens the console menu
├── Run-Optimizer-GUI.bat      Asks for admin, then opens the older WPF window
├── Restore-Xbox-Emergency.bat Emergency Xbox restore (no module needed)
├── config/
│   ├── tweaks.json            Tweak definitions (check, apply, undo, tier)
│   ├── services.json          Service trimming definitions and protected list
│   ├── tasks.json             Scheduled task definitions
│   ├── appx_bloat.json        Apps to remove, whitelist, Xbox packages
│   └── presets.json           Preset definitions
├── modules/
│   ├── Cli.ps1                Console menu and results summary
│   ├── Common.ps1             Shared helpers (logging, registry, config, presets)
│   ├── Backup-Manager.ps1     Restore point, snapshots, hive exports, safety net
│   ├── Debloat-Engine.ps1     App removal, temp cleanup, AI features
│   ├── Maintenance-Engine.ps1 Disk, RAM, cache and cleanup actions
│   ├── Process-Optimizer.ps1  Service and startup optimization
│   ├── Responsiveness-Engine.ps1  Power plans, Explorer restart
│   └── Xbox-Controller.ps1    Xbox modes and 3-tier fallback
├── ui/
│   └── MainWindow.xaml        WPF window
├── tests/
│   ├── Validate-Repo.ps1      Dependency-free checks (PowerShell 7 works anywhere)
│   └── Optimizer.Tests.ps1    Pester 5 version of the same checks
└── docs/
    └── CONTRACT.md            Internal module contract
```

## Testing

- `pwsh -NoProfile -File tests/Validate-Repo.ps1` runs the repository checks. It needs no extra modules and works on Windows and Linux with PowerShell 7.
- `Invoke-Pester .\tests\Optimizer.Tests.ps1` runs the Pester 5 tests. This needs Pester 5.

## Credits

Design references (no code was copied):

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)
- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)
- [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows)
- [Atlas-OS/Atlas](https://github.com/Atlas-OS/Atlas)
- [hellzerg/optimizer](https://github.com/hellzerg/optimizer)

## Disclaimer

StudentOpti changes system settings. Use it at your own risk. The restore point is there for you to roll back, but keep your own backups of anything important.
