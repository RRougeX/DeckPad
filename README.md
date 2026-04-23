# DeckPad

DeckPad is a Windows desktop companion app for small macro keyboards with
6 keys and 1 knob. It listens to the keys your mini pad already sends and maps
them to app launches, window focus, hotkeys, URLs, text, commands, and Spotify
controls.

DeckPad is designed for boards like the common 6-key + knob USB macro pads. It
does not require vendor software to run, but vendor software can still be useful
if you want to remap the pad to unique trigger keys such as `F13` through `F21`.

## Why There Are Two README Files

This repo keeps two `README.md` files on purpose:

- The root [`README.md`](./README.md) is the GitHub landing page. It explains what the project is, how to start, and what is safe to publish.
- [`deckpad_app/README.md`](./deckpad_app/README.md) is the folder-level guide for the actual app files. It is there so someone who opens `deckpad_app` directly still sees run instructions and file notes right away.

If this repo is viewed on GitHub, the root README should answer "what is this project?".
If someone is already inside `deckpad_app`, the app README should answer "what do I run and what files matter here?".

## Repo Layout

```text
RaffSteamDeck/
  README.md                  <- repo overview
  HOW_TO_USE.md              <- step-by-step usage guide
  PUBLISH_CHECKLIST.md       <- pre-GitHub review checklist
  deckpad_app/
    README.md                <- app-folder guide
    DeckPad.ps1              <- main app
    Run-DeckPad.bat          <- easiest launcher
    profiles/                <- local runtime profiles
    settings/                <- local runtime settings
```

## Features

- 6-key + 1-knob control surface
- Device-aware input lock so your normal keyboard does not trigger actions
- Per-slot action editor
- Profile creation and startup profile selection
- Desktop shortcut installer
- Tray support, including minimize-to-tray and close-to-tray settings
- Custom app/tray/shortcut icon
- Raw trigger capture using key codes, scan codes, modifier chords, and HID media controls when available
- Spotify actions for volume, play/pause, next track, and previous track

## Requirements

- Windows
- PowerShell 5.1 or newer
- A small HID macro keyboard, ideally 6 keys + 1 knob

## Quick Start

1. Download or clone this repo.
2. Open `deckpad_app`.
3. Run `Run-DeckPad.bat`.
4. Select your mini pad in the device dropdown and click `Use Selected`.
5. If you are unsure which device is the mini pad, click `Lock Device`, then press a key on the mini pad.
6. Click a tile, click `Capture Key`, press the physical button, choose an action, and click `Save Slot`.

If you want the folder-specific launcher notes and file map, open
[`deckpad_app/README.md`](./deckpad_app/README.md).

To create a desktop shortcut, run:

```text
deckpad_app\Install-Desktop-Shortcut.bat
```

## Profiles

Runtime profiles are stored in:

```text
deckpad_app\profiles
```

The repo ships a public-safe sample profile at:

```text
deckpad_app\profiles\default-profile.sample.json
```

On first run, DeckPad creates the live `default-profile.json` locally. That live
profile is ignored by git so device locks, custom commands, private paths, and
personal URLs do not get staged by accident.

Inside the app, click `Create Profile` to copy your current mappings and actions
into a new profile JSON file. The new profile is automatically selected as the
startup profile.

Startup profile behavior is controlled in `Settings`:

- `Load saved profile on startup`
- `Startup profile`

If a selected startup profile is deleted, DeckPad falls back to
`profiles\default-profile.json`.

## Included Docs

- [`HOW_TO_USE.md`](./HOW_TO_USE.md) for a straightforward usage walkthrough
- [`PUBLISH_CHECKLIST.md`](./PUBLISH_CHECKLIST.md) for the final public-repo sanity check
- [`deckpad_app/README.md`](./deckpad_app/README.md) for the app-folder guide

## Recommended Trigger Keys

For best results, program your mini pad to send keys that your normal keyboard
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

If two physical switches send the exact same low-level input, Windows cannot tell
them apart. DeckPad stores raw trigger signatures when possible, but identical
hardware input must be fixed by remapping the pad itself.

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

## Privacy And Public Repo Safety

The repo is prepared for public release:

- No local Windows user paths are included in the tracked sample profile.
- No API keys, tokens, webhooks, or credentials are included.
- Runtime profile and settings files are ignored from git.
- User-created profiles may contain private paths, URLs, commands, or device IDs, so review them before force-adding anything from `deckpad_app\profiles` or `deckpad_app\settings`.

Before publishing your own customized copy, run:

```powershell
rg -n "C:\\|Users\\|Desktop|AppData|token|secret|password|api[_-]?key|webhook" .
```

## License

DeckPad is source-available for viewing and personal use only. Reuse,
redistribution, resale, rebranding, sublicensing, or republishing of the code,
UI, assets, branding, or documentation requires permission from the rights
holder. See [`LICENSE`](./LICENSE).
