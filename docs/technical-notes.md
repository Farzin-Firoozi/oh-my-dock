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

Write rules (from [spike 0.4](spikes/0.4-dockutil-temp-plist.md) source review of dockutil 3.1.3):

- **Verify by re-reading.** After every write, re-read the Dock and compare to the expected state. Never trust dockutil's exit code: it exits 0 even when `defaults import` failed (e.g. read-only plist).
- **Never `--remove spacer-tiles`.** It crashes (SIGTRAP) with several spacers and saves nothing. Remove spacers one at a time by position / GUID-equivalent.
- **Canonicalize plist paths** with `resolvingSymlinksInPath().standardized`. dockutil's live-plist check is a lowercased string compare, so an aliasing path (symlink, `..`, `//`) would be treated as non-live and `defaults import` into the live domain without a restart. Refuse any path that resolves to the live plist except through the explicit live-write code path.
- **Always pass absolute item paths.** `~` expands relative to the plist path (`--add '~/Downloads' "$P"` adds `$P/Downloads`).
- **Sudo hop.** Non-live writes run `/usr/bin/sudo -u #<owner uid> /usr/bin/defaults import`. Same-user sudo needs no password, but an MDM-locked sudoers could break it. dockutil always prints "not running as the user of this Dock nor root" in this mode.

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

- **Quit permission**: none needed in the tested scope. `NSRunningApplication.terminate()` works with no Accessibility or Automation permission on macOS 27.0.1, unmanaged machine (CLI, ad-hoc app, and ad-hoc hardened-runtime app tested). Untested: macOS 14/15, notarized Developer ID build, MDM/PPPC Macs, save sheets / quit veto, sandboxed targets, `forceTerminate()`. Always handle `terminate() == false` and timeouts; never force quit automatically. No first-use prompt. Do **not** add `NSAppleEventsUsageDescription` or the apple-events entitlement, and never hand-build quit Apple Events / AppleScript (those need Automation consent). See [spike 0.6](spikes/0.6-terminate-permission.md).
- **Lock Dock to display**: shelved for the v0.4+ research bucket. Ship without it.
- **Profile format**: **JSON** (native `Codable`, no dependency) for storage and import/export. From v0.1, every app item stores `bundleId` (plus optional `brewCask` / `appStoreId`), not just a path. The gallery depends on this.

- **Dock backend**: reads via CFPreferences / `PropertyListSerialization`; writes via **bundled `dockutil`** inside the app. Both behind a `DockBackend` protocol.

## Open questions

- Release gate (Phase 3): re-verify `terminate()` / launch on macOS 14, 15 and current with a notarized Developer ID build on a clean TCC state.
- Verify `forceTerminate()` behavior separately before shipping force quit.
