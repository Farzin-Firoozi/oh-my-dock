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
- **Never `--remove spacer-tiles`.** It crashes (SIGTRAP) with several spacers and saves nothing. dockutil 3.1.3 cannot remove a spacer by position: spacers have no label or URL, so `--remove ""` fails. Removing spacers needs one of two paths:
  - **Direct plist edit**: delete the tile from `persistent-apps` / `persistent-others` through CFPreferences on the live Dock, then re-read the Dock to verify, and restart the Dock once.
  - **Full rewrite**: `--remove all`, then re-add every tile, all with `--no-restart`, with one Dock restart at the end. `--remove all` also clears `recent-apps`; `DockutilBackend.preflight` reports this (`clearsRecentApps`).
- **Canonicalize plist paths** with `resolvingSymlinksInPath().standardized`. dockutil's live-plist check is a lowercased string compare, so an aliasing path (symlink, `..`, `//`) would be treated as non-live and `defaults import` into the live domain without a restart. Refuse any path that resolves to the live plist except through the explicit live-write code path.
- **Always pass absolute item paths.** `~` expands relative to the plist path (`--add '~/Downloads' "$P"` adds `$P/Downloads`).
- **Option values starting with `-` need the `--label=` form.** `--label -x` fails with "Missing value". Empty labels are dropped, never passed as `--label ""` (it matches every URL tile with an empty path).
- **Duplicate-label add is refused.** `Dock.add` refuses a tile whose computed label is already the first match (apps, then recents, then others) in the destination section. `Profile` validation throws `duplicateLabel` before any write. Spacers are never stored, so they never collide.
- **Spacer sentinel label** `oh-my-dock-spacer`: every spacer `--add` passes it. Without `--label`, dockutil uses the working directory's last component, which can collide with a real tile.
- **Folders: `--view`, `--display`, `--sort` always passed explicitly**, even at defaults, so dockutil's defaults never decide a written folder's options.
- **Sudo hop.** Non-live writes run `/usr/bin/sudo -u #<owner uid> /usr/bin/defaults import`. Same-user sudo needs no password, but an MDM-locked sudoers could break it. dockutil always prints "not running as the user of this Dock nor root" in this mode.

Preferences are written via `defaults write com.apple.dock <key>` (or `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`).

**Reset to system default.** `DockPrefs.resetKeys` (JSON `resetToSystemDefault`: array of key names, omitted when empty, old files decode unchanged) lists keys that applying removes from the domain, so macOS uses its own value; no default number is ever invented. A key is either set or reset (`conflictingReset` on validate and decode). The writer removes the key, verifies it is absent, and records the old value in the rollback pre-image. A `PrefsDiff.Entry` with `target == nil` is a reset (diff preview: “System default”); it appears only while the domain holds a value for that key. The panel's slider/toggle positions for keys without a value come from `DockPrefs.displayDefaults`, which is display-only.

## Apply and restore

- **Apply flow** (`ProfileApplier`):
  1. *Preview* (read-only): tile plan, plus a `PrefsDiff` when `profile.prefs` is set (`nil` = preferences untouched), plus the `AppSwitcher` `SwitchPlan` (will quit / keep / launch / protected) from the apps running now. `source` (the profile being left) feeds the quit scope: `preview(_:from:trigger:)` and `apply(_:from:trigger:confirm:)`.
  2. *Confirmation*: `ApplyPreview.confirmationRequired` is true when apps are skipped **or** any running app would be quit (unless the trigger is authorized, below). Without a `confirm` closure the apply throws `confirmationRequired` / `quitConfirmationRequired` before touching anything.
  3. *Snapshot* the Dock domain, with the **pre-image** of the preference keys the apply will change stored in the snapshot metadata (`Snapshot.prefsImage`, optional; old snapshots without it load and restore unchanged). Re-read tiles **and** preferences; refuse with `dockChanged` if either differs from the preview (the preference "expecting" guard; `DockPrefsWriter.apply(expecting:)` re-checks right before writing).
  4. *Write* (no restart): `DockBackend.apply(_:expecting:)` for tiles, then `DockPrefsWriter.apply`. **One** `killall Dock`, only when tiles changed or the writer reports `needsDockRestart`. Nothing changed: no snapshot, no write, no restart (`.noChanges`).
  5. *Verify both*: re-read tiles after the restart (`matchesAfterWrite`) and read every changed preference key back against its target.
  6. *Rollback* on any failure, or a cancellation seen after the write: `SnapshotStore.restore(id:createSafetySnapshot:prefsWriter:)` replaces the domain, then writes the recorded preference values explicitly and reads them back; restart once; re-read: tiles equal the pre-apply Dock and the preference keys equal the pre-image. If any step fails: `rollbackFailed` with the snapshot id.
  7. *Apps* run last, only after 4 and 5 succeeded: `AppSwitching.execute` (quit one at a time, graceful `terminate()` only, then launches). The `SwitchOutcome` is `ApplyReport.switchOutcome` (stragglers listed, nothing force-quit). A switch that rolled back never quits an app. If the user cancels, or a newer switch supersedes, during the app phase, it stops before the next quit and reports what happened; **the Dock change is not rolled back** (it is already committed and verified) and quits that happened are not undone. If the Dock and preferences already match but apps must be quit or launched, the result is `.appsOnly(SwitchOutcome)`: no snapshot, no write, no restart.
- **Who may quit apps.** A quit needs an explicit yes: the `confirm` closure accepted the preview, or the apply came from an `ApplyTrigger.automatic` source and the target profile has `SwitchingOptions.quitOnAutomaticSwitch` (default off, written to JSON only when on, always cleared on import). Hotkeys and future triggers are `.automatic`; without the opt-in they must surface the preview (the hotkey path shows the alert presenter) or the apply fails with `quitConfirmationRequired`.
- **Undo and history restore** put back tiles and Dock preferences only (the snapshot is the whole `com.apple.dock` domain, plus the recorded preference values). **They do not reopen apps that were quit.** The UI says so.
- **Injection.** `ProfileApplier.init(..., prefsWriter: (any DockPrefsWriting)? = nil, appSwitcher: (any AppSwitching)? = nil)`. The defaults keep old call sites and tests unchanged: no switcher means apps are neither quit nor launched; no writer means a profile that sets preferences is refused (`prefsUnavailable`) rather than silently dropped.
- **Restore is a true replace.** `defaults import com.apple.dock <file>` replaces the whole domain. The restored plist is then read back and must equal the snapshot, else `restoreVerificationFailed`.

- **Preview guard.** While a Dock preferences preview is on the Dock (`DockOperationGate.isPreviewActive`, set by the prefs panel), menu-bar and hotkey apply, undo, and history restore/delete are refused with “Revert or keep the Dock preferences preview first.” They check on entry and again inside the gate (`requireNoPreview()`), because a preview can begin while an operation waits for its turn. A failed revert keeps the flag set.

- **Quit with a preview.** `AppDelegate.applicationShouldTerminate` returns `.terminateLater` when a preview is active and asks `PreviewQuitCoordinator.revertForQuit()` to revert it through the gate, waiting at most 10 s. If the revert fails or times out, an alert offers “Quit Anyway” (restore “Before previewing Dock preferences” from History) or Cancel.

### DockPrefsWriter (M2)

- **`DockPrefsDomainIO`**: read/write/remove a single key + `synchronize()`. Live: `CFPreferencesDockPrefsDomainIO` (`com.apple.dock`). Tests: `InMemoryDockPrefsDomainIO` only; any live CFPreferences test uses a throwaway domain, never `com.apple.dock`.
- **`DockPrefsWriter`**: `captureAsDockPrefs()` / `captureCurrent()` for “save current”; `diff(current:target:)` → `PrefsDiff` for the diff preview; `apply(_:expecting:)` validates ranges, refuses when the domain changed since `expecting` (`DockPrefsWriterError.prefsChanged`, same idea as `DockBackendError.dockChanged`), writes only non-`nil` `DockPrefs` fields, verifies every write by re-reading, returns `changedKeys`, `needsDockRestart` (true when any key changed — caller runs one `killall Dock` with tile apply), and `rollbackImage` for `rollback(_:)`.
- **Apply order** (wired in `ProfileApplier`, see Apply and restore): tile `DockBackend.apply` → `DockPrefsWriter.apply` → single `DockRestarter.restart()` → verify both. `ProfileApplier` talks to the writer through `DockPrefsWriting`; the rollback image is built from the preview baseline, not from the result of `apply`, which is lost when a write verification throws midway.

## Export formats

### dockutil shell script

`DockutilScriptExporter.export` turns a profile into a POSIX `sh` script that rebuilds the Dock on a clean account. It returns text. It does not run the script, launch dockutil, or touch the live Dock.

- The script starts with `#!/bin/sh` and `set -eu`. If `dockutil` is not on `PATH`, it prints `brew install dockutil` and exits.
- Then `dockutil --remove all --no-restart`, then one `--add` per tile (apps, then others). Each add passes `--section` and a 1-based `--position` within that section. Folders also pass `--view`, `--display`, and `--sort`. Labels use `--label=` (so a value that starts with `-` is not another flag). Spacers use dockutil's spacer type and the sentinel label `oh-my-dock-spacer`. Every dockutil invocation includes `--no-restart`.
- When the profile has `prefs`, each set key is one `defaults write com.apple.dock <defaults key>` line (`-bool`, `-float`, or `-string`). Each reset key is `defaults delete com.apple.dock <key> 2>/dev/null || true` (tolerant of an absent key under `set -e`). `nil` prefs omit the block. An empty prefs object writes nothing.
- The script ends with a single `killall Dock`. Switching options and hotkeys are not Dock contents, so they are not in the script.
- Every profile value is single-quoted (`'` → `'\''`). `$()`, backticks, newlines, quotes, spaces, and unicode stay data. A path under the home directory passed to `export` is written as `"$HOME"` plus a single-quoted suffix, never as that machine's home path (`/Users/mehack` is not under `/Users/me`). The suffix stays outside the double quotes, where `$()` would run.
- The header comment carries the profile name and `OhMyDockCore.version`. The name is newline-stripped (including Unicode line separators) and single-quoted, so it cannot leave the comment.
- Export refuses a NUL in the profile name or in any tile string, an app with no path (dockutil adds apps by path), and any profile that fails `validate()`.

Tests syntax-check generated scripts with `sh -n` on stdin. They do not execute them.

### JSON profile exchange

`ProfileExchange` is the file format for a profile that leaves the app (export, import, and later the gallery). The app's own store remains a bare `Profile` document.

```json
{
  "format" : "oh-my-dock-profile",
  "profile" : { },
  "version" : 1
}
```

- `format` must be `oh-my-dock-profile`. `version` is the exchange document version and is currently `1`. The embedded `profile` is `Profile.jsonData()` (pretty-printed, sorted keys) and has its own `schemaVersion`.
- Import rejects a document larger than 1 MiB (1,048,576 bytes) before parsing. It rejects malformed JSON, a missing `format` / `version` / `profile`, any key other than those three, and any unknown key inside the profile. A `version` other than `1` (older or newer) fails as an unsupported version, even when the document also has unknown keys, so a newer file reports its version.
- Import always runs `Profile.sanitizedForImport()` and returns that profile plus the sanitizer's change list. The id is new. Quit scope is forced to `none`, force-quit is cleared, and launch-on-switch is cleared. URLs, paths, unknown tiles, and over-long strings follow the gallery rules in [profile-gallery.md](profile-gallery.md).
- Export does not sanitize. A file is checked on the way in, including one this app just wrote.

## Native Dock limits

- **Every change restarts the Dock** (`killall Dock`), so icons flash for about a second. Always batch with `--no-restart` and restart once.
- **One Dock on one display at a time.** Display triggers can switch which profile is active, but each monitor can't have its own dock.
- **Lock Dock to one display**: no clean public API. DockFlow ships it, but how is unknown. Needs research.
- Frontmost-app triggers must be throttled/debounced because of the Dock restart.

## Distribution

- **Not on the Mac App Store.** The sandbox blocks writing `com.apple.dock` preferences, running `killall Dock`, and terminating other apps.
- Ship as an **ad-hoc signed, not notarized** app (no Apple Developer account): direct download + Homebrew cask. Users bypass Gatekeeper via right-click → Open or `xattr -cr`.
- Updates: Sparkle (free EdDSA key) or a GitHub Releases check; decided in Phase 3.2.
- **Bundled dockutil is Apache-2.0**: include its LICENSE and NOTICE in the app bundle and repo (third-party notices).

## Privacy

- All data local: profiles, usage stats, and history live in `~/Library/Application Support/oh-my-dock/`.
- Optional iCloud sync for profiles only.
- No analytics. Network use is limited to update checks.

## Decisions

- **Quit permission**: none needed in the tested scope. `NSRunningApplication.terminate()` works with no Accessibility or Automation permission on macOS 27.0.1, unmanaged machine (CLI, ad-hoc app, and ad-hoc hardened-runtime app tested). Untested: macOS 14/15, notarized Developer ID build, MDM/PPPC Macs, save sheets / quit veto, sandboxed targets, `forceTerminate()`. Always handle `terminate() == false` and timeouts; never force quit automatically. No first-use prompt. Do **not** add `NSAppleEventsUsageDescription` or the apple-events entitlement, and never hand-build quit Apple Events / AppleScript (those need Automation consent). See [spike 0.6](spikes/0.6-terminate-permission.md).
- **AppSwitcher** (`Switching/`): protocol-based (`RunningAppsProviding`, `AppLauncher`, `SwitchClock`) so tests use fakes and never touch real processes. Graceful `terminate()` only, sequential per-app wait with an injectable timeout (default 5 s), stragglers reported and never force quit by `execute`; `forceQuit` is a separate call gated by `SwitchingOptions.offerForceQuit` and `forceTerminate()` is unverified. Cooperative cancellation without rollback; `SwitchQueue` serializes switches. Run it on the main actor: `NSRunningApplication` state only updates while the run loop runs. See [profile switching](profile-switching.md).
- **Lock Dock to display**: shelved for the v0.4+ research bucket. Ship without it.
- **Profile format**: **JSON** (native `Codable`, no dependency) for storage and import/export. From v0.1, every app item stores `bundleId` (plus optional `brewCask` / `appStoreId`), not just a path. The gallery depends on this. A profile shared outside the app is a `ProfileExchange` envelope (`format`, `version`, `profile`); see Export formats.

- **Dock backend**: reads via CFPreferences / `PropertyListSerialization`; writes via **bundled `dockutil`** inside the app. Both behind a `DockBackend` protocol.

## Open questions

- Release gate (Phase 3): re-verify `terminate()` / launch on macOS 14, 15 and current with the ad-hoc signed release build on a clean TCC state.
- Verify `forceTerminate()` behavior separately before shipping force quit.
