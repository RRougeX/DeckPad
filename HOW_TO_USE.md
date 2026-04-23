# How To Use DeckPad

## First Run

1. Open `deckpad_app`.
2. Double-click `Run-DeckPad.bat`.
3. Pick your mini pad from the device dropdown.
4. Click `Use Selected`.
5. If you are not sure which device is your pad, click `Lock To Device`, then press one key on the pad.

## Map A Button

1. Click a tile in DeckPad.
2. Click `Capture Key`.
3. Press the physical button or knob action you want to assign.
4. Choose an action type.
5. Fill in the action value if that action needs one.
6. Click `Save Slot`.

## Built-In Layout

DeckPad is built around this hardware layout:

- `Key 1`
- `Key 2`
- `Key 3`
- `Key 4`
- `Key 5`
- `Key 6`
- `Knob Left`
- `Knob Press`
- `Knob Right`

## Recommended Trigger Keys

If you can remap your pad, use uncommon keys so your normal keyboard does not
trigger DeckPad:

- `F13`
- `F14`
- `F15`
- `F16`
- `F17`
- `F18`
- `F19`
- `F20`
- `F21`

## Action Values

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
- `spotify_volume_up`
  No value needed.
- `spotify_play_pause`
  No value needed.
- `spotify_previous_track`
  No value needed.
- `spotify_next_track`
  No value needed.

## Tray And Exit

DeckPad keeps working from the system tray.

- Click the window `X` to hide DeckPad to the tray.
- Double-click the tray icon to reopen DeckPad.
- Use `Exit DeckPad` from the tray icon menu to fully quit.

## Desktop Shortcut

To create or refresh the desktop and Start menu shortcuts:

```text
deckpad_app\Install-Desktop-Shortcut.bat
```

## Personal Files

DeckPad creates local runtime files while you use it:

```text
deckpad_app\profiles\default-profile.json
deckpad_app\settings\app-settings.json
```

These are ignored by git so your personal device ID, paths, commands, URLs, and
profiles stay private.

The public sample files are:

```text
deckpad_app\profiles\default-profile.sample.json
deckpad_app\settings\app-settings.sample.json
```
