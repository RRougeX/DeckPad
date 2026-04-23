# How To Use DeckPad

## Goal

Use your 6-key keypad with one knob like a mini Stream Deck with your own software and your own mappings.

## Fast Start

1. Open [`deckpad_app`](./deckpad_app).
2. Double-click [`Run-DeckPad.bat`](./deckpad_app/Run-DeckPad.bat).
3. Pick your mini pad from the device dropdown and click `Use Selected`.
4. If you are not sure which device it is, click `Lock To Device` instead.
5. Press one key on the mini pad.
6. Press buttons on your keypad.
7. Watch the Activity log in the app.

## What To Look For

If the app logs something like:

- `Unmapped key detected: [F13] VK=124`
- `Unmapped key detected: [A] VK=65`

then that is good. It means DeckPad can see your keypad without vendor software.

If pressing the keypad does something in YouTube but DeckPad logs nothing, then the keypad is probably sending media-control events instead of normal keyboard keys.

If DeckPad reacts when you type on your normal keyboard, the app is not locked to the mini pad yet. Pick the device from the dropdown or use `Lock To Device`, then press one key on the mini pad.

## Set Up A Button

1. Click a slot tile in the app.
2. Click `Capture Next Key`.
3. Press the physical keypad button you want to assign.
4. Choose an action type.
5. Enter the action value.
6. Click `Save Current Slot`.

## Built-In Layout

This version of DeckPad is built around a fixed hardware layout:

- `Key 1`
- `Key 2`
- `Key 3`
- `Key 4`
- `Key 5`
- `Key 6`
- `Knob Left`
- `Knob Press`
- `Knob Right`

The bottom row in the UI is always for the knob actions.

## Action Types

- `focus_or_launch`
  Example: `discord|discord`
- `launch_app`
  Example: `notepad.exe`
- `open_url`
  Example: `https://twitch.tv`
- `type_text`
  Example: `Starting stream now`
- `send_hotkey`
  Example: `^+1`
- `run_command`
  Example: `Start-Process calc.exe`
- `spotify_volume_down`
  No value needed.
- `spotify_play_pause`
  No value needed.
- `spotify_volume_up`
  No value needed.

## Default Starter Setup

The default profile is already wired for common use:

- `Key 1` focuses or launches Discord
- `Key 2` focuses or launches Spotify
- `Knob Left` lowers Spotify volume
- `Knob Press` toggles Spotify play/pause
- `Knob Right` raises Spotify volume

## Best Trigger Keys

If you eventually do get vendor software or another remap tool, the best keys to use for a macro pad are:

- `F13`
- `F14`
- `F15`
- `F16`
- `F17`
- `F18`
- `F19`
- `F20`
- `F21`

Those usually avoid conflicts with your normal keyboard.

## Files You May Edit

- [`deckpad_app/profiles/default-profile.sample.json`](./deckpad_app/profiles/default-profile.sample.json)
  The public-safe sample bindings kept in the repo.
- [`deckpad_app/DeckPad.ps1`](./deckpad_app/DeckPad.ps1)
  The app itself.
- [`deckpad_app/README.md`](./deckpad_app/README.md)
  App-specific notes.

When you run DeckPad, it creates a local `deckpad_app/profiles/default-profile.json`
file for your live bindings. That runtime file is ignored by git.

## What You Do Not Need

You do not need any extra programming tool to run DeckPad.

## Put It On Your Desktop

If you want DeckPad to feel more like a normal app:

1. Open [`deckpad_app`](./deckpad_app).
2. Double-click [`Install-Desktop-Shortcut.bat`](./deckpad_app/Install-Desktop-Shortcut.bat).
3. A `DeckPad` shortcut will be created on your Windows desktop.

## Compact Mode

DeckPad now has a compact desktop mode for daily use.

- `Compact Mode` hides the editor and keeps the deck front and center.
- `Pin Window` keeps DeckPad on top of other windows.
- the device dropdown lets you choose the exact keyboard device
- `Lock To Device` tells DeckPad which physical keyboard is your mini pad by listening for one press

That gives you a better "real Stream Deck companion" feel when it is sitting on your desktop.
