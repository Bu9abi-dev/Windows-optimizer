# StudentOpti

StudentOpti is a free Windows 10/11 optimizer built for students and shared laptops. It is written in PowerShell 5.1 with a small WPF window, so there is nothing extra to install.

## What it does

- **Debloat**: removes common consumer and OEM apps (never the Xbox apps), clears temp files.
- **Privacy and AI off**: telemetry, activity history, advertising ID, lock screen ads, Bing in Start search, Copilot, and Recall.
- **Service trimming**: sets rarely needed services (DiagTrack, Maps, Fax, and more) to lighter startup modes.
- **Responsiveness**: faster menus and shutdown, lighter visuals, and a power plan that fits studying or gaming.
- **Xbox control**: switch Xbox features between Enabled, Lite, and Disabled, with a 3-tier fallback if anything breaks.

## Safety first

- **Restore point**: before any change, StudentOpti creates a Windows restore point (skip it with `-NoRestorePoint`).
- **Snapshots and backups**: JSON state snapshots and `.reg` exports go to `%LOCALAPPDATA%\StudentOpti\backups`.
- **Every tweak has an undo**: each tweak restores the Windows default, and you can undo any single one with `-Undo <id>`.
- **Protected apps and services**: a whitelist keeps important apps safe from removal, and core Windows services (such as WinDefend, Dhcp, and wuauserv) are never disabled.
- **Xbox apps are never removed**.
- **Dry-run mode**: `-DryRun` shows what would happen and changes nothing.

## Quick start

1. Download or clone this repository and extract it to a folder.
2. Right-click `Run-Optimizer.bat` and choose **Run**. It asks for administrator rights; click **Yes**.
3. Pick a preset in the window and click apply, or use the command line below.

## Command line examples

Run these from an elevated PowerShell in the project folder.

```powershell
.\StudentOpti.ps1 -Preset StudentLaptop -XboxMode Lite -Silent
.\StudentOpti.ps1 -Preset StudyBattery -DryRun
.\StudentOpti.ps1 -ListTweaks
.\StudentOpti.ps1 -RestoreSnapshot
.\StudentOpti.ps1 -XboxMode Repair
.\StudentOpti.ps1 -Undo copilot
```

Other switches include `-Tweaks <id>[,<id>]` to apply single tweaks and `-CleanTemp` to clear temp files.

## Presets

| Id | Name | Xbox | Power plan | Summary |
| --- | --- | --- | --- | --- |
| `StudentLaptop` | Student Laptop Boost | Lite | Balanced | Privacy, AI, and responsiveness tweaks, bloat removal, cleanup. |
| `StudyBattery` | Study Battery Saver | Disabled | Study | Student Laptop Boost plus background app and standby network savings. |
| `GamingXbox` | Gaming / Xbox Ready | Enabled | Performance | Keeps Xbox working; privacy and responsiveness tweaks, no bloat removal. |
| `FactoryDefault` | Restore Defaults | Enabled | Balanced | Reverts every tweak and service to Windows defaults. |

## Xbox broke?

1. Right-click `Restore-Xbox-Emergency.bat` and run it as administrator. It re-enables the Xbox services and restores the Game DVR settings.
2. If Xbox apps are still missing, run `.\StudentOpti.ps1 -XboxMode Repair`. This is the Deep Repair. It reinstalls missing Xbox apps through winget and the Microsoft Store.
3. As a last resort, install "Xbox" and "Gaming Services" from the Microsoft Store.

## Project layout

```
windows-optimizer/
├── StudentOpti.ps1            Entry point: GUI by default, CLI with parameters
├── Run-Optimizer.bat          Asks for admin, then starts StudentOpti
├── Restore-Xbox-Emergency.bat Emergency Xbox restore (no module needed)
├── config/
│   ├── tweaks.json            Tweak definitions (check, apply, undo)
│   ├── services.json          Service trimming definitions and protected list
│   ├── appx_bloat.json        Apps to remove, whitelist, Xbox packages
│   └── presets.json           Preset definitions
├── modules/
│   ├── Common.ps1             Shared helpers (logging, registry, config)
│   ├── Backup-Manager.ps1     Restore point, snapshots, hive exports
│   ├── Debloat-Engine.ps1     App removal, temp cleanup, AI features
│   ├── Process-Optimizer.ps1  Service and startup optimization
│   ├── Responsiveness-Engine.ps1  Power plans, Explorer restart
│   └── Xbox-Controller.ps1    Xbox modes and 3-tier fallback
├── ui/
│   └── MainWindow.xaml        WPF window
└── docs/
    └── CONTRACT.md            Internal module contract
```

## Testing

- `Invoke-Pester .\tests\Optimizer.Tests.ps1` runs the Pester 5 tests. This needs Windows and Pester 5.
- `tests/Validate-Repo.ps1` checks the repository and runs anywhere with PowerShell 7.

## Credits

Design references (no code was copied):

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)
- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)
- [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows)
- [Atlas-OS/Atlas](https://github.com/Atlas-OS/Atlas)
- [hellzerg/optimizer](https://github.com/hellzerg/optimizer)

## Disclaimer

StudentOpti changes system settings. Use it at your own risk, and create a restore point before you start.
