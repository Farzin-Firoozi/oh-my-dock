# Implementation plan

Covers the build from an empty repo to v0.4+. Read with [features.md](features.md), [technical-notes.md](technical-notes.md), and [roadmap.md](roadmap.md).

## Baseline

| Item | Choice |
|---|---|
| Language | Swift 6 (strict concurrency) |
| UI | SwiftUI, `MenuBarExtra` + settings/editor windows |
| State | `@Observable` (Observation framework) |
| Min macOS | **14 Sonoma** (Observation, modern `MenuBarExtra`, Focus Filters) |
| Dev toolchain | Xcode 27, Swift 6.4 |
| Project gen | **XcodeGen** (`project.yml`, no checked-in `.pbxproj` churn) |
| Dock backend | Bundled **dockutil v3** behind `DockBackend` protocol |
| Storage | JSON files in `~/Library/Application Support/oh-my-dock/` |
| Distribution | Developer ID signed, notarized, GitHub Releases + Homebrew cask, Sparkle updates |
| License | MIT (app), Apache-2.0 notice for dockutil |

## Architecture

```
oh-my-dock/
├── project.yml                 # XcodeGen
├── Packages/
│   └── OhMyDockCore/           # SwiftPM package, all logic, no UI, `swift test`-able
│       ├── Sources/OhMyDockCore/
│       │   ├── Model/          # Profile, DockItem, DockPrefs, Trigger (Codable)
│       │   ├── Dock/           # DockBackend protocol, DockutilBackend, DockPrefsWriter, DockRestarter
│       │   ├── Store/          # ProfileStore (JSON), SnapshotStore (backups/history)
│       │   ├── Apply/          # DiffEngine, ApplyPlan, ProfileApplier (orchestrates)
│       │   ├── Apps/           # AppResolver (bundleId→path), AppSwitcher (quit/launch)
│       │   ├── Triggers/       # TriggerEngine + sources (Focus, Display, WiFi, Schedule, Frontmost)
│       │   └── Export/         # DockutilScriptExporter, JSON import/export, schema validation
│       └── Tests/OhMyDockCoreTests/
├── App/                        # macOS app target
│   ├── OhMyDockApp.swift       # MenuBarExtra + windows
│   ├── MenuBar/                # profile switcher menu
│   ├── Editor/                 # visual Dock editor
│   ├── Prefs/                  # Dock preferences panel
│   ├── Settings/               # app settings (never-quit list, hotkeys, launch at login)
│   ├── Intents/                # App Intents: Shortcuts + Focus Filter
│   └── Resources/
│       └── Helpers/dockutil    # bundled, signed binary
├── CLI/                        # `ohmydock` command (v0.3), links OhMyDockCore
├── scripts/                    # build-dockutil.sh, release.sh, notarize.sh
└── docs/
```

Rule: **all logic lives in `OhMyDockCore`**. App and CLI are thin shells. Keeps it testable and lets the CLI reuse everything.

## Data model (v0.1, stable from day one)

```swift
struct Profile: Codable, Identifiable {
    var id: UUID
    var name: String
    var schemaVersion: Int            // start at 1, migrate forward
    var apps: [DockItem]              // persistent-apps section
    var others: [DockItem]            // persistent-others section (folders, URLs)
    var prefs: DockPrefs?             // nil = don't touch prefs
    var switching: SwitchingOptions   // quit scope, launch list (v0.2)
    var hotkey: Hotkey?
}

enum DockItem: Codable {
    case app(AppRef)
    case url(URL, label: String?)
    case folder(path: String, view: FolderView, display: FolderDisplay, sort: FolderSort, label: String?)
    case spacer(SpacerKind)           // .normal, .small, .flex
}

struct AppRef: Codable {
    var bundleId: String              // primary key for resolution
    var name: String
    var path: String?                 // hint only
    var brewCask: String?
    var appStoreId: Int?
    var launchOnSwitch: Bool = false
}
```

`DockPrefs` has an optional field for each key in [features.md §3](features.md#3-dock-preferences). `nil` means leave the key unchanged.

## Core flow: apply profile

```
ProfileApplier.apply(profile)
 1. snapshot = SnapshotStore.save(current dock plist)          // always first
 2. current  = DockBackend.read()
 3. plan     = DiffEngine.plan(from: current, to: profile)     // minimal ops
 4. [UI] show diff / confirm (if enabled)
 5. AppSwitcher.quit(plan.quit)  -> wait (timeout)             // v0.2
 6. DockBackend.execute(plan.ops, restart: false)              // all --no-restart
 7. DockPrefsWriter.write(profile.prefs)
 8. DockRestarter.restart()                                    // single killall Dock
 9. AppSwitcher.launch(plan.launch)                            // v0.2
10. on failure at any step -> restore snapshot, restart, report
```

Concurrency: `ProfileApplier` is an `actor`. A new apply request cancels any in-flight request (see [profile-switching.md](profile-switching.md)).

## Milestones

Each milestone ends with a working, shippable build.

### M0: Foundations (spike + skeleton)

- [x] `project.yml`, app target, `OhMyDockCore` package, test target. Local checks: `make test` (pre-push hook) + `make build`. Hosted CI dropped: no Xcode 27 on GitHub runners.
- [x] `scripts/build-dockutil.sh`: build dockutil v3 from a pinned tag, copy to `App/Resources/Helpers/`, sign with our identity. Add the Apache-2.0 LICENSE/NOTICE.
- [x] **Spikes** (findings go into technical-notes.md):
  - [x] Can dockutil target a **non-live plist** (temp copy) for safe integration tests? Yes, temp plist file (spike 0.4).
  - [x] Does `NSRunningApplication.terminate()` need any permission? Not on macOS 27.0.1, unmanaged machine, CLI + ad-hoc app + ad-hoc hardened app (spike 0.6). macOS 14/15, notarized build, MDM, save sheets/veto, sandboxed targets and `forceTerminate()` untested; see release gates.
  - [x] How URL and folder items appear in `dockutil --list` output, for round-trip parsing? Lossy; reads go through CFPreferences instead (spike 0.5).
- [x] Empty `MenuBarExtra` app that launches, with `LSUIElement`.
- [x] Menu bar glyph (SF Symbol `dock.rectangle`).
- [ ] App icon (`AppIcon` asset): pending until a design is chosen. M0 delivered only the menu bar SF Symbol.

**Done when:** the app builds and runs from the menu bar, `make test` and `make build` pass locally, and the bundled dockutil runs from inside the app.

### M1 (v0.1): Profiles, editor, backup

Core:
- [ ] Models + JSON `ProfileStore` (atomic writes, schemaVersion).
- [ ] Read Dock via CFPreferences / PropertyListSerialization (see spike 0.5): parse into `[DockItem]`. Resolve `bundleId` via `Bundle(url:)`.
- [ ] `DiffEngine`: current → target ops (add/remove/move). Unit-tested heavily.
- [ ] `DockutilBackend.execute(ops)` with `--no-restart`, plus `DockRestarter`. Verify by re-reading the Dock after every write and comparing to the expected state (dockutil exit 0 does not prove the write happened); canonicalize plist paths; never `--remove spacer-tiles` (see [technical-notes.md](technical-notes.md)).
- [ ] `SnapshotStore`: copy `com.apple.dock.plist` before each apply. Keep the last N (default 50). Restore via `defaults import com.apple.dock <file>` + restart.
- [ ] `ProfileApplier` with rollback on failure.
- [ ] First launch: auto-save the current Dock as the **Default** profile.

UI:
- [ ] Menu bar: profile list (checkmark on active), "Save current Dock as…", "Undo last change", "Open editor".
- [ ] Editor window: profile sidebar (create/rename/duplicate/delete) and a Dock strip with drag-reorder.
  - Add app (picker + Finder drag), URL, folder (view/display/sort/label), spacers.
- [ ] Diff preview sheet before apply.
- [ ] History window: list of snapshots, restore.
- [ ] Global hotkey per profile ([KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) package).
- [ ] Launch at login toggle (`SMAppService`).

**Done when:** a user can save the Dock, build two profiles, switch between them from the menu bar or a hotkey, and undo. The Dock restarts only once per switch.

### M2 (v0.2): Prefs, app switching, export

- [ ] `DockPrefsWriter` via `CFPreferencesSetAppValue` + synchronize, for all keys in features.md §3.
- [ ] Prefs panel with **live preview** (apply now, revert on Cancel) and Reset to defaults. Prefs are saved per profile.
- [ ] `AppSwitcher`: compute quit/keep/launch sets and apply the never-quit list. Only `.regular` apps are touched. Graceful `terminate()`, timeout, report stragglers explicitly (also handle `terminate() == false`). Force quit never automatic: only after an explicit user action, with a warning, and only after `forceTerminate()` behavior is verified separately. Launch with `activates=false` and optionally hidden.
  - Tests/QA: save sheet, quit veto / deferral, sandboxed third-party app.
- [ ] Confirmation sheet ("Will quit / Will open").
- [ ] No permission needed in the tested scope (spike 0.6); release gate below covers the rest.
- [ ] `DockutilScriptExporter`: profile → `.sh`. JSON import/export with schema validation.

**Done when:** a switch can quit A's apps, open B's, and apply B's prefs. An exported script reproduces the Dock on a clean user account.

### M3 (v0.3): Automation, CLI

- [ ] `TriggerEngine`: rule list (trigger → profile), debounce, and the "never quit apps from automatic triggers unless opted in" rule.
- [ ] Trigger sources:
  - Focus Filter (`SetFocusFilterIntent`)
  - Display (`didChangeScreenParametersNotification` + screen fingerprint)
  - Wi-Fi (CoreWLAN SSID; needs Location permission on modern macOS, verify)
  - Schedule
  - Frontmost app (throttled)
- [ ] App Intents: `ApplyProfileIntent`, `SaveCurrentDockIntent`, `ListProfilesIntent`.
- [ ] URL scheme `ohmydock://apply?profile=…`.
- [ ] `ohmydock` CLI (swift-argument-parser): `list`, `apply <name>`, `save <name>`, `export <name>`, `undo`. It reads the same store. If the app is running, the CLI hands off to it via URL scheme or XPC.

**Done when:** connecting an external display or changing Focus switches the profile automatically, and Shortcuts and the CLI work.

### M4 (v0.4+): Smart features, sync, gallery

- [ ] `AppResolver`: missing-app detection and `brew install --cask` suggestions. Bundle ID → cask mapping via the Homebrew API JSON (cached).
- [ ] Usage tracking (local, opt-in) + auto-ordering + suggestions.
- [ ] iCloud sync (CloudKit private DB or iCloud Drive folder; decide in a spike).
- [ ] MDM script output; `--allhomes`.
- [ ] Invisible mode; regular-app mode toggle.
- [ ] **Profile gallery** per [profile-gallery.md](profile-gallery.md): gallery repo + CI schema validation + `index.json` on Pages, Gallery tab, `ohmydock://import`, security rules.
- [ ] Research: lock Dock to one display.

## Release pipeline (set up during M1)

- `scripts/release.sh`: archive, then Developer ID sign inside-out (dockutil helper first with `--timestamp` + hardened runtime, then the app), then `notarytool submit --wait`, then staple, then DMG/zip, then Sparkle appcast.
- **Mandatory release gates** (block any release):
  - Test quit/launch on macOS 14, 15, and current with the notarized Developer ID build on a clean TCC state (spike 0.6 covered only macOS 27, ad-hoc).
  - Verify the dockutil license/NOTICE ships in `Contents/Resources`.
  - Verify the helper is signed with Developer ID + `--timestamp` + hardened runtime before the app is signed.
- GitHub Release + Homebrew cask (own tap first, e.g. `farzin/tap/oh-my-dock`; submit to `homebrew/cask` once notable). See [distribution.md](distribution.md).
- Requires an Apple Developer account ($99/yr).

## Testing strategy

| Layer | How |
|---|---|
| Models, DiffEngine, exporter, schema validation | Unit tests in `OhMyDockCore` (Swift Testing). Bulk of coverage. |
| DockBackend | `FakeDockBackend` for applier tests. Integration tests against temp plist **file** fixtures (confirmed, spike 0.4). **Never touch the live Dock in automated tests.** |
| AppSwitcher | Protocol over `NSWorkspace`/`NSRunningApplication`; fake in tests (incl. `terminate() == false`, timeout, veto/deferral). Manual QA for real quit/launch: save sheet, quit veto, sandboxed third-party app; `forceTerminate()` verified separately. |
| Triggers | Inject event sources; test debounce and rules. |
| UI | Manual QA checklist per milestone; snapshot tests optional. |

## Risks

| Risk | Mitigation |
|---|---|
| Corrupting the user's Dock | Snapshot before every apply; automatic rollback; Default profile on first launch |
| Dock restart flicker on frequent triggers | Batch ops, debounce triggers, skip apply if the diff is empty |
| macOS update changes the Dock plist format | Isolated behind `DockBackend`; dockutil upstream tracks changes |
| Permission surprises (Wi-Fi SSID needs Location) | Quit needs none in the tested scope (spike 0.6; release gate covers macOS 14/15 + notarized build); Location requested on first use of the Wi-Fi trigger (M3) |
| Quitting apps loses user work | Graceful terminate only; force quit never automatic (explicit user action only, off by default, with a warning); confirmation sheet |
| dockutil reports success but nothing was written | Re-read the Dock after every write and compare; never trust exit codes |

## Next action

Start **M0**: generate the XcodeGen project, the core package, local test hooks, and the dockutil build script, then run the three spikes.
