# Publish Checklist

Use this before pushing the repo to GitHub.

## Safe By Default

This repo has already been cleaned up to avoid obvious personal data leaks:

- no local `C:\Users\...` paths in docs
- no build output
- generic sample profile
- live profile and settings files ignored by git

## Quick Manual Review

Check these before publishing:

1. Open [`deckpad_app/profiles/default-profile.sample.json`](./deckpad_app/profiles/default-profile.sample.json).
2. Make sure it does not include:
   - private file paths
   - private URLs
   - personal names
   - app commands you do not want public
3. If you plan to force-add a live file from `deckpad_app/profiles` or `deckpad_app/settings`, review it line by line first.
4. Open [`deckpad_app/DeckPad.ps1`](./deckpad_app/DeckPad.ps1) if you customized it.
5. Make sure you did not hardcode:
   - usernames
   - API keys
   - tokens
   - Discord webhooks
   - OBS secrets

## Suggested Repo Name

Pick a neutral GitHub repo name, for example:

- `deckpad`
- `deckpad-windows`
- `deckpad-controller`

## Nice-To-Have GitHub Setup

- add a repo description
- add topics like `powershell`, `windows`, `macro-pad`, `stream-deck`
- use the included source-available `LICENSE`
