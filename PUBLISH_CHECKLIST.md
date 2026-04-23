# Publish Checklist

Use this before committing or pushing public changes.

## Safe By Default

The repo is designed so personal runtime state stays local:

- `deckpad_app/profiles/*.json` is ignored.
- `deckpad_app/settings/app-settings.json` is ignored.
- `default-profile.sample.json` and `app-settings.sample.json` are the public files.

## Before Committing

Run:

```powershell
git status --short
```

Only commit files you intentionally changed. Do not force-add local runtime
profiles or settings unless you reviewed them line by line.

## Secret Scan

Before publishing, run:

```powershell
rg -n -i "C:\\|Users\\|Desktop|AppData|token|secret|password|api[_-]?key|webhook|client[_-]?secret|private[_-]?key" .
```

Expected harmless matches may include documentation that mentions these words.
Review any match that points to real code, profiles, settings, or commands.

## Manual Review

Check:

- `deckpad_app/profiles/default-profile.sample.json`
- `deckpad_app/settings/app-settings.sample.json`
- `README.md`
- `HOW_TO_USE.md`
- `deckpad_app/README.md`

Make sure they do not include private paths, device identifiers, tokens,
webhooks, personal URLs, or commands you do not want public.

## GitHub Setup

Suggested topics:

- `powershell`
- `windows`
- `macro-pad`
- `stream-deck`
- `tray-app`
