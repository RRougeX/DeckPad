# DeckPad App Folder

This folder contains the runnable DeckPad app. The root
[`README.md`](../README.md) is the project overview; this file explains what is
inside `deckpad_app` and how to run it.

## Start Here

For normal use, double-click:

```text
Run-DeckPad.bat
```

Inside DeckPad:

1. Pick your macro pad in the device dropdown.
2. Click `Use Selected`, or click `Lock To Device` and press one key on the pad.
3. Click a tile.
4. Click `Capture Key`, press the physical control, choose an action, and save.

## Files

- `DeckPad.ps1`: main app script
- `Run-DeckPad.bat`: normal launcher
- `Start-DeckPad.vbs`: hidden PowerShell launcher used by shortcuts
- `Install-Desktop-Shortcut.bat`: creates desktop and Start menu shortcuts
- `assets\`: app icon files
- `lib\`: helper modules
- `profiles\`: local profiles and public sample profile
- `settings\`: local settings and public sample settings

## Icons

Windows shortcuts use:

```text
assets\DeckPad.ico
```

The PNG source artwork is kept as:

```text
assets\deckPad.png
```

If you replace the PNG and rerun `Install-Desktop-Shortcut.bat`, the installer
will rebuild `DeckPad.ico` and refresh the shortcuts.

## Runtime Files

The repo tracks only public-safe samples:

```text
profiles\default-profile.sample.json
settings\app-settings.sample.json
```

DeckPad creates these private local files when you use it:

```text
profiles\default-profile.json
settings\app-settings.json
```

Those runtime files are ignored by git. They can contain your device lock,
custom commands, app paths, profile names, and URLs.

## Tray Behavior

DeckPad is meant to keep running in the system tray.

- Clicking the window `X` hides DeckPad to the tray.
- Double-clicking the tray icon opens DeckPad again.
- `Exit DeckPad` in the tray menu fully closes it.

This lets your macro pad mappings keep working even when the main window is not
open on the desktop.

## Notes

- DeckPad is Windows-only.
- It uses raw keyboard input so it can distinguish your mini pad from your normal keyboard when device lock is set.
- If your pad only sends media controls, some controls may need to be remapped to normal keys such as `F13` through `F21`.
- `type_text` and `send_hotkey` target whichever app is currently focused.
- Spotify volume actions control Spotify's app audio session.
