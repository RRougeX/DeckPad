# DeckPad App Folder

This `README.md` lives inside `deckpad_app` on purpose.

The root repo [`README.md`](../README.md) is the GitHub/project overview.
This file is the folder guide for the runnable app: what to launch, what files
matter here, and what gets created locally while you use DeckPad.

`DeckPad` is a Windows desktop companion app for small macro keyboards that act
like normal HID devices. Instead of trying to reflash the keypad firmware, this
app listens for the keys your keypad sends and turns them into richer desktop
actions.

This version is specifically designed for:

- 6 keys
- 1 knob with left, press, and right actions

## Start Here

If you just want to run DeckPad:

1. Double-click `Run-DeckPad.bat`
2. Pick your device in the dropdown
3. Click `Use Selected` or `Lock To Device`
4. Click a tile and assign an action

## What This Folder Contains

- `DeckPad.ps1`
  The main app.
- `Run-DeckPad.bat`
  Simple launcher for normal use.
- `Install-Desktop-Shortcut.bat`
  Creates a desktop shortcut.
- `profiles\`
  Live profiles created on your machine.
- `settings\`
  Live settings created on your machine.
- `lib\`
  Helper modules used by the app.
- `assets\`
  App icon and bundled assets.

For the app icon, DeckPad now supports either:

- `assets\DeckPad.ico`
- `assets\DeckPad.png`

If you only provide `DeckPad.png`, the shortcut installer will generate a
`DeckPad.generated.ico` file for the Windows shortcut icon.

## What It Does

- Shows a custom control surface for your macro pad
- Lets you assign actions to each key in a JSON profile
- Listens globally for the mapped keys
- Supports these action types:
  - `focus_or_launch`
  - `launch_app`
  - `open_url`
  - `type_text`
  - `send_hotkey`
  - `run_command`
  - `spotify_volume_down`
  - `spotify_play_pause`
  - `spotify_volume_up`

## Recommended Keypad Setup

Vendor software is optional.

If your macro pad already sends normal keyboard keys, you can use DeckPad without
the vendor software at all. The app can capture key presses directly.

Vendor software is only helpful if you want to remap the pad to uncommon keys such as
`F13` through `F24`. That keeps your macro pad separate from your main keyboard.

The default profile uses:

- `F13`
- `F14`
- `F15`
- `F16`
- `F17`
- `F18`
- `F19`
- `F20`
- `F21`

You can change any binding from the app.

The default control deck ships with:

- Discord focus/launch on `Key 1`
- Spotify focus/launch on `Key 2`
- Spotify volume down on `Knob Left`
- Spotify play/pause on `Knob Press`
- Spotify volume up on `Knob Right`

## Run It

From PowerShell:

```powershell
cd deckpad_app
powershell -ExecutionPolicy Bypass -File .\DeckPad.ps1
```

Or double-click:

- `Run-DeckPad.bat`
- `Install-Desktop-Shortcut.bat` to create a desktop shortcut

Inside the app:

- a device dropdown lets you choose which keyboard device DeckPad should read
- `Use Selected` applies the chosen device immediately
- `Lock To Device` lets you press a key on the mini pad to identify it
- `Compact Mode` switches to a deck-first layout for daily use
- `Pin Window` keeps DeckPad on top

## Profiles And Local Files

Runtime profiles are stored in:

- `profiles\default-profile.json`

The public repo keeps a sample at:

- `profiles\default-profile.sample.json`

On first run, DeckPad creates the live `default-profile.json` locally. The live
profile and runtime settings file are ignored by git so your device lock, custom
commands, and private paths do not get committed by accident.

The same idea applies to:

- `settings\app-settings.json`
- `settings\app-settings.sample.json`

## Notes

- This app is Windows-only.
- It uses raw keyboard input so it can tell your mini pad apart from your normal keyboard.
- You can either select the keyboard from the device list or use `Lock To Device`.
- `type_text` and `send_hotkey` target whatever app is currently focused.
- `focus_or_launch` is good for apps like Discord and Spotify because it can switch to an existing window.
- Spotify knob actions use per-app audio session control for volume.
- Compact mode hides the editor and turns the app into a smaller desktop control deck.
- If your keypad only sends media controls like play/pause, DeckPad may not see them with the current keyboard-hook approach.
- The Activity panel logs unmapped keys, which helps you discover what your keypad is actually sending.

## GitHub Safety

This project is set up to avoid leaking local-machine details:

- docs use relative paths
- the sample profile is generic
- no build output is included

Before publishing, review any runtime profile you plan to share if you changed it
to include private app paths, URLs, commands, or device identifiers.

If you want the project overview instead of folder-level notes, go back to the
root [`README.md`](../README.md).
