# DeckPad
<img width="586" height="247" alt="image" src="https://github.com/user-attachments/assets/978397ca-839e-4ae8-a4ae-b6813370c6eb" />

DeckPad is a Windows companion app for small USB macro pads, especially the
common 6-key + 1-knob boards. It listens for the keys your pad already sends and
turns them into useful desktop actions like launching apps, focusing windows,
opening URLs, sending hotkeys, typing text, running commands, and controlling
Spotify.

DeckPad does not require vendor software to run. Vendor software is only useful
if you want to remap the pad to uncommon trigger keys such as `F13` through
`F21`, which helps avoid conflicts with your normal keyboard.

## Features

- Fixed 6-key + 1-knob control surface
- Device lock so your normal keyboard does not trigger actions
- Raw trigger capture using virtual keys, scan codes, modifier chords, and HID data when available
- Per-slot action editor
- Profile creation and startup profile selection
- Minimize-to-tray and close-to-tray behavior
- Desktop and Start menu shortcut installer
- Custom icon support
- Spotify volume, play/pause, previous track, and next track actions

## Requirements

- Windows
- PowerShell 5.1 or newer
- A small HID keyboard-style macro pad

## Quick Start

1. Download or clone this repo.
2. Open `deckpad_app`.
3. Run `Run-DeckPad.bat`.
4. Select your mini pad from the device dropdown and click `Use Selected`.
5. If you are not sure which device is the mini pad, click `Lock To Device`, then press one key on the pad.
6. Click a tile, click `Capture Key`, press the physical key or knob action, choose an action, and click `Save Slot`.

To create desktop and Start menu shortcuts, run:

```text
deckpad_app\Install-Desktop-Shortcut.bat
```

## How It Runs

DeckPad is a local PowerShell WinForms app. When you click the window `X`, it is
designed to stay running in the system tray so your mappings still work. To fully
quit, use the tray icon menu and choose `Exit DeckPad`.

## Repo Layout

```text
DeckPad/
  README.md
  HOW_TO_USE.md
  PUBLISH_CHECKLIST.md
  deckpad_app/
    DeckPad.ps1
    Run-DeckPad.bat
    Install-Desktop-Shortcut.bat
    assets/
    lib/
    profiles/
    settings/
```

## Personal Profiles And Git Safety

The repo ships public-safe sample files:

```text
deckpad_app\profiles\default-profile.sample.json
deckpad_app\settings\app-settings.sample.json
```

When you run DeckPad, it creates local runtime files:

```text
deckpad_app\profiles\default-profile.json
deckpad_app\settings\app-settings.json
```

Those runtime files are ignored by git. That means you can lock DeckPad to your
own device, save private app paths, commands, URLs, and custom profiles without
uploading that personal setup to GitHub.

If you update the app later, use:

```powershell
git pull
```

Your ignored local profile and settings files should stay on your machine.

## Recommended Trigger Keys

For best results, configure the macro pad to send keys that your normal keyboard
does not use:

```text
Top Left       F13
Top Middle     F14
Top Right      F15
Bottom Left    F16
Bottom Middle  F17
Bottom Right   F18
Knob Left      F19 or media previous
Knob Press     F20 or media play/pause
Knob Right     F21 or media next
```

If two physical controls send the exact same low-level input, Windows cannot
tell them apart. DeckPad can store raw trigger signatures when possible, but
identical hardware input has to be fixed by remapping the pad itself.

## Action Types

- `focus_or_launch`: focus an existing app window or launch it, for example `discord|discord`
- `launch_app`: launch a program, for example `notepad.exe`
- `open_url`: open a URL
- `type_text`: type text into the currently focused app
- `send_hotkey`: send a hotkey such as `^+1`
- `run_command`: run a PowerShell command
- `spotify_volume_down`: lower Spotify's app audio session volume
- `spotify_volume_up`: raise Spotify's app audio session volume
- `spotify_play_pause`: send a background media play/pause key
- `spotify_previous_track`: send a background previous-track key
- `spotify_next_track`: send a background next-track key

## Docs

- [`HOW_TO_USE.md`](./HOW_TO_USE.md) is the step-by-step user guide.
- [`deckpad_app/README.md`](./deckpad_app/README.md) explains the runnable app folder.
- [`PUBLISH_CHECKLIST.md`](./PUBLISH_CHECKLIST.md) is a final safety checklist before publishing changes.

## License

DeckPad is source-available for viewing and personal use only. Reuse,
redistribution, resale, rebranding, sublicensing, or republishing of the code,
UI, assets, branding, or documentation requires permission from the rights
holder. See [`LICENSE`](./LICENSE).
