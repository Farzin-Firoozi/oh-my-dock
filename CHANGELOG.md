# Changelog

## Unreleased

- **`ohmydock` CLI**: headless control of profiles and the Dock (`list`, `show`, `current`, `apply`, `save`, `delete`, `rename`, `duplicate`, `undo`, snapshots/history, `restore`, `export`, `import`, `status`, `doctor`, `version`, shell `completions`). JSON envelope (`schemaVersion` 1), documented exit codes, `--dry-run` apply, quit flags requiring explicit `--allow-quit` and `--yes`.
- **URL scheme** `ohmydock://` for apply, save, undo, and open (editor/history/settings); optional x-callback-url; first-use **Allow external control** consent for mutating URLs.
- **App Intents / Shortcuts**: apply profile, save current Dock, list profiles, undo last change.
- **Settings**: external control mode (ask / allowed / denied) for URL automation.
- **Man page** `ohmydock.1` shipped in the app bundle; Homebrew cask exposes the CLI via a `binary` stanza to `OhMyDock.app/Contents/Helpers/ohmydock`.

## 0.2.0

- Dock preferences panel: size, magnification, position, auto-hide, minimize effect and more, with a live preview, Revert, and Reset to system default. Preferences are saved per profile and applied with the profile.
- App switching: a profile can quit and launch apps when you switch to it. You confirm which apps quit (apps you mark "Keep running" stay open). Apps are quit only after the Dock change is verified, and never from an automatic trigger unless you opt in. Force quit is a separate, explicit action.
- Editor: your Dock now appears inside a MacBook mockup (model detected, color picker), with a plain-strip toggle.
- Export a profile as a shell script, or as a JSON file you can import on another Mac.
- Hotkey failures and app-switch results now show in a floating panel even when the menu is closed.
- Fixes: a Dock preview is reverted on quit, apply/undo/restore are blocked while a preview is active, and Reset removes keys instead of writing guessed defaults.

Known limits: same as 0.1.0 (ad-hoc signed, not notarized; macOS 14 and 15 untested). The mockup shows a stand-in picture instead of your real wallpaper for aerial and many modern wallpapers.


## 0.1.0

First public release.

- Menu bar app that manages the native macOS Dock (macOS 14+).
- Profiles: save the current Dock, switch from the menu bar or with a per-profile global hotkey.
- Visual editor: reorder tiles; add apps, links, folders and spacers.
- Diff preview before any change is applied.
- Snapshots, undo and a history window. The Dock is captured as a pinned "First launch" snapshot on first run.
- Optional launch at login and an optional update check against GitHub Releases.

Known limits: the app is ad-hoc signed and not notarized (open it with right-click, then Open, or `xattr -dr com.apple.quarantine`). Tested on the newest macOS only; macOS 14 and 15 are not yet tested. Launch at login may fail to register on ad-hoc signed builds.
