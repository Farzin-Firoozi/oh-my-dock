# Technical notes

## Stack

- **Swift + SwiftUI**, `MenuBarExtra` for the menu bar UI.
- `SMAppService` for launch at login.
- **App Intents** for Shortcuts actions and the Focus Filter (`SetFocusFilterIntent`).
- `NSScreen` / `didChangeScreenParametersNotification` for display triggers.
- `NWPathMonitor` + CoreWLAN for Wi-Fi triggers.
- `NSWorkspace.didActivateApplicationNotification` for frontmost-app triggers.
- `NSMetadataQuery` (Spotlight) for app discovery, including external drives.
- `NSRunningApplication` / `NSWorkspace.openApplication` for quit/launch on switch.

## Dock backend

Split by operation, behind a `DockBackend` protocol:

- **Reads**: read the Dock directly, not via `dockutil --list`. Live Dock: `CFPreferencesCopyAppValue("persistent-apps" / "persistent-others", "com.apple.dock")`. Fixture files: `PropertyListSerialization`. `--list` drops spacer kinds, folder view/display/sort, and GUIDs, and its tab-delimited output is unescaped. See [spike 0.5](spikes/0.5-dockutil-list-format.md).
- **Writes**: bundled `dockutil` (v3, Swift, Apache-2.0) only, for `--add` / `--remove` / `--move`, always with `--no-restart`.
- **Testing**: integration tests run dockutil against a temp plist **file** path, never a directory (dockutil treats a directory as a home dir), with `--no-restart`. dockutil uses CFPreferences only for the exact live plist of the console user; other paths go through `defaults export` / `defaults import`. dockutil rewrites files as binary plists. See [spike 0.4](spikes/0.4-dockutil-temp-plist.md).

Preferences are written via `defaults write com.apple.dock <key>` (or `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`).

## Native Dock limits

- **Every change restarts the Dock** (`killall Dock`), so icons flash for about a second. Always batch with `--no-restart` and restart once.
- **One Dock on one display at a time.** Display triggers can switch which profile is active, but each monitor can't have its own dock.
- **Lock Dock to one display**: no clean public API. DockFlow ships it, but how is unknown. Needs research.
- Frontmost-app triggers must be throttled/debounced because of the Dock restart.

## Distribution

- **Not on the Mac App Store.** The sandbox blocks writing `com.apple.dock` preferences, running `killall Dock`, and terminating other apps.
- Ship as a **Developer ID–signed, notarized** app: direct download + Homebrew cask.
- Updates via Sparkle.
- **Bundled dockutil is Apache-2.0**: include its LICENSE and NOTICE in the app bundle and repo (third-party notices).

## Privacy

- All data local: profiles, usage stats, and history live in `~/Library/Application Support/oh-my-dock/`.
- Optional iCloud sync for profiles only.
- No analytics. Network use is limited to update checks.

## Decisions

- **Quit permission**: none needed. `NSRunningApplication.terminate()` works with no Accessibility or Automation permission on macOS 27 (CLI, ad-hoc app, and hardened-runtime app tested). No first-use prompt. Do **not** add `NSAppleEventsUsageDescription` or the apple-events entitlement, and never hand-build quit Apple Events / AppleScript (those need Automation consent). See [spike 0.6](spikes/0.6-terminate-permission.md).
- **Lock Dock to display**: shelved for the v0.4+ research bucket. Ship without it.
- **Profile format**: **JSON** (native `Codable`, no dependency) for storage and import/export. From v0.1, every app item stores `bundleId` (plus optional `brewCask` / `appStoreId`), not just a path. The gallery depends on this.

- **Dock backend**: reads via CFPreferences / `PropertyListSerialization`; writes via **bundled `dockutil`** inside the app. Both behind a `DockBackend` protocol.

## Open questions

- Re-verify `terminate()` needs no permission on a notarized Developer ID build (Phase 3).
