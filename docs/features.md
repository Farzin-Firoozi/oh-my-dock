# Features

Everything here works against the native macOS Dock.

## 1. Dock editor

- Read the current Dock (`dockutil --list`) and show it live.
- Drag-and-drop reorder; add apps from `/Applications` or by dragging from Finder; remove items.
- Item types: apps, **URLs**, folders/stacks, spacers (`spacer`, `small-spacer`, `flex-spacer`).
- Folder/stack options: `--view grid|fan|list|auto`, `--display folder|stack`, `--sort name|dateadded|datemodified|datecreated|kind`, custom `--label`.
- **Diff preview** before applying ("+ Xcode, − Slack, moved Safari → 1").
- All operations batched with `--no-restart`, then a single `killall Dock`.
- App discovery via Spotlight, including apps on external drives.

## 2. Profiles

- Unlimited named profiles (Work, Dev, Gaming, Presentation, Minimal…).
- **Save current Dock as profile** in one click.
- Create, rename, edit, duplicate, delete.
- On first launch, the current Dock is auto-saved as a **Default** profile (safety net).
- Each profile can carry its own **Dock preferences** (see §3).
- Each profile can define apps to **launch / quit on switch** (see [profile-switching.md](profile-switching.md)).
- Switch via **menu bar**, **global hotkey per profile**, CLI, URL scheme, or Shortcuts.
- **Presentation mode** preset: hide personal apps, enable autohide, clean Dock.

## 3. Dock preferences

Wraps `defaults write com.apple.dock …`:

| Setting | Key |
|---|---|
| Icon size | `tilesize` |
| Magnification on/off + size | `magnification`, `largesize` |
| Position | `orientation` (left / bottom / right) |
| Auto-hide | `autohide` |
| Auto-hide delay / speed | `autohide-delay`, `autohide-time-modifier` |
| Show recent apps | `show-recents` |
| Only show running apps | `static-only` |
| Minimize effect | `mineffect` (genie / scale / suck) |
| Minimize into app icon | `minimize-to-application` |
| Running indicators | `show-process-indicators` |
| Launch animation | `launchanim` |
| Scroll to open | `scroll-to-open` |

- **Live preview** — apply temporarily, revert on Cancel.
- **Reset to defaults** button.

## 4. Automation & triggers

**Shipped (v0.3 external control)**

- **CLI** (`ohmydock`): list/show/current/apply/save/import/export/undo/snapshots/status/doctor — headless, JSON envelope. See [agents.md](agents.md).
- **URL scheme** `ohmydock://apply|save|undo|open` (mutating URLs need in-app confirmation; `import?url=` reserved, not implemented).
- **Apple Shortcuts / App Intents**: Apply profile, Save current Dock, List profiles, Undo last change.
- **Allow external control** setting (URLs only): ask / allowed / denied.

**Postponed (not in v0.3)**

- **Focus mode → profile** (Focus Filter).
- **Display configuration change → profile** (external monitor connected / disconnected).
- **Wi-Fi network → profile** (home / office).
- **Time of day / schedule → profile**.
- **Frontmost app → profile** (e.g. Xcode active → Dev Dock). Throttled, because each switch restarts the Dock.

## 5. Smart features

- **Missing-app detection**: if a profile references an app that isn't installed, warn, skip, or offer `brew install --cask <app>`.
- **Usage-based auto-ordering**: sort Dock icons by how often and how long you use each app (tracked locally).
- Suggestions: frequently used apps not in the Dock; Dock apps never opened.
- Suggest a profile switch based on context (later).

## 6. Backup, import & export

- Snapshot `~/Library/Preferences/com.apple.dock.plist` before every apply.
- **Undo / layout history** with previews.
- Export / import profiles as JSON (git- and dotfiles-friendly).
- **Export a profile as a `dockutil` shell script** for setting up a new Mac.
- **MDM / fleet script output** (Jamf, Kandji).
- Multi-user admin: `--allhomes`, `--homeloc`.
- **iCloud sync** of profiles across Macs.
- **Profile gallery**: browse and install community profiles; share your own (see [profile-gallery.md](profile-gallery.md)).

## 7. App shell

- Menu bar app (`MenuBarExtra`); optional regular-app mode with a Dock icon.
- **Invisible mode**: hide the menu bar icon, controlled via hotkeys/CLI only.
- Launch at login (`SMAppService`).
- 100% local, no tracking. Network use is limited to update checks.

## Out of scope

These require replacing the Dock and will not be built:

- Window previews, Alt-Tab switcher
- Different Dock per monitor, floating extra docks
- Widgets (clock, weather, music, system stats), file tray
- Themes, custom Dock styling, custom magnification effects
- Taskbar mode, per-window buttons
