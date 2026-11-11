# monitor-control

A small Windows tray app that switches a PC between **desktop mode** (your monitors), **TV mode** (the TV only) and **all screens**, and also looks after the TV itself: sleep and wake, jumping to the PC's HDMI input, and going back Home (or to the app it was on) when you return to the desk.

Built for a PC with an NVIDIA GPU driving two monitors and an Android TV, but nothing is hard-coded to those screens: you pick what each screen is in the Settings window.

## At a glance

| | |
|---|---|
| **What** | Windows tray app that switches a PC between desktop, TV and all-screens modes and looks after the TV itself |
| **Stack** | PowerShell 5.1 and VBScript tray app; NirSoft MultiMonitorTool for display control; ADB and Wake-on-LAN for the Android TV |
| **Config** | Settings window and `config.json`: nothing is hard-coded to a particular set of screens |

## What it does

| | |
|---|---|
| **Desktop mode** | Turns the desktop screens on and the TV screen off in one Windows call (a single short blink). Sound goes back to what you were using. If the TV is showing the PC's input, it is sent Home (or back to the app it was on). A TV showing YouTube or anything else is left alone. |
| **TV mode** | Turns the TV on and the monitors off. Sound goes to the TV. The TV wakes and jumps to the PC's HDMI input. |
| **All screens** | Everything on. |
| **Sleep / Wake TV** | Over ADB, with Wake-on-LAN as a fallback for waking. |
| **Layout** | Screens always sit in the order you set, the main screen holds the taskbar, and each runs its native resolution at its highest refresh rate. |

Why "Home" matters: a TV left on the PC's input while Windows has that screen turned off keeps re-probing the HDMI link, and some GPUs hitch every few seconds because of it. Sending the TV away from that input stops it.

## Requirements

- Windows 10 / 11 (uses the built-in Windows PowerShell 5.1)
- [MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html) (NirSoft, free): put `MultiMonitorTool.exe` (64-bit) in this folder
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (`adb`) on your PATH, for the TV features. `winget install Google.PlatformTools` works
- An Android TV / Google TV with **network debugging** turned on (Developer options). Give the TV a fixed IP address (on the TV itself if your router won't do reservations). The first connection asks you to allow the PC on the TV: tick "always allow"

## Setup

1. Put `MultiMonitorTool.exe` in this folder.
2. Double-click `tray.vbs`. A small monitor icon appears next to the clock.
3. Click it, then **Settings...**:
   - say which screens are **Desktop** and which is the **TV** (top of the list = leftmost screen on your desk) and which desktop screen is **Main**
   - enter the TV's IP address
   - set the TV's **PC input** name (see below)
   - pick the **sound device** to use in TV mode, and whether going back to desktop mode sends the TV **Home** or to its **previous app**
4. Optional: tick **Start with Windows**.

Left-click or right-click the icon for the menu. Hotkeys (can be turned off in Settings): `Ctrl+Alt+D` desktop, `Ctrl+Alt+T` TV, `Ctrl+Alt+A` all.

`desk-mode.vbs`, `tv-mode.vbs` and `all-on.vbs` run a mode with no window and no tray app, if you prefer plain shortcuts.

### Finding your TV's input name

On the TV, switch to the PC's HDMI input and run `tools\probe-tv.bat <tv-ip> hdmi`. In `tv-probe-hdmi.txt`, the `sessionStateMap` section shows `inputId: ...` for the input in use (for example `com.tcl.tvinput/.TvPassThroughService/HW15`). Put that in Settings. The `mCurrentFocus` line shows the TV's own app package (`tvApp` in `config.json`, default `com.tcl.tv`).

## Files

- `tray.ps1` - the tray app and Settings window
- `switch-mode.ps1` - does the actual switching (`-Mode desk|tv|all|list|tvaction`)
- `config.json` - your settings (written by the Settings window; safe to edit by hand)
- `MonitorControl.exe` - double-click to start the tray app (no window). It is a small launcher and needs the other files next to it. Rebuild it with `tools\build-exe.bat` if you change `tools\launcher.cs`.
- `*.vbs` - launchers that run without a console window
- `tools/probe-tv.bat` - helper for finding the TV's input name

Logs, for when something misbehaves: `switch-log.txt` (every screen switch with timings), `tv-log.txt` (TV commands), `tray-log.txt`.

## Known limits

- Screens are matched by their hardware model ID, so two identical monitors can't be told apart.
- TV control is for Android TV over ADB. Other TVs would need a different command set.
- **TV picture** (tray menu) switches the TV between 4K 60 Hz and 1080p 120 Hz; it is applied right away if the TV is on, otherwise next time.
- All screens mode keeps the sound device you last used in desktop mode (it only moves it back from the TV's sound if the TV had taken over).
- Waking a TV that is fully off by network works only if it keeps its network alive in standby. The app tries ADB, then Wake-on-LAN (needs the TV's MAC, saved the first time it answers). If `tv-log.txt` says the TV "is not answering", the TV is in deep standby: turn on Wake on Wi-Fi/LAN, Instant Power On or Quick Start in the TV's power/network settings, or wake it with the remote.
- "Previous app" reopens the app that was in front before the PC input was shown; the result of each launch attempt is written to `tv-log.txt`.
- 4K at 120 Hz needs an HDMI 2.1 path (a DisplayPort-to-HDMI adapter is usually limited to 4K 60 Hz).
