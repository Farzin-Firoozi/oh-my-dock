# Changelog

## 0.1.0

First public release.

- Menu bar app that manages the native macOS Dock (macOS 14+).
- Profiles: save the current Dock, switch from the menu bar or with a per-profile global hotkey.
- Visual editor: reorder tiles; add apps, links, folders and spacers.
- Diff preview before any change is applied.
- Snapshots, undo and a history window. The Dock is captured as a pinned "First launch" snapshot on first run.
- Optional launch at login and an optional update check against GitHub Releases.

Known limits: the app is ad-hoc signed and not notarized (open it with right-click, then Open, or `xattr -dr com.apple.quarantine`). Tested on the newest macOS only; macOS 14 and 15 are not yet tested. Launch at login may fail to register on ad-hoc signed builds.
