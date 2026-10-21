# External control (v0.3)

Normative spec for the v0.3 external-control surface. Phase 5 tasks in [execution-plan.md](execution-plan.md) are built from this document.

v0.3 is the surface a person, a shell script, a Shortcut, or an AI agent uses to drive oh-my-dock. Agents run the `ohmydock` CLI. There is no MCP server in v0.3. Automatic triggers (trigger engine, schedule, display, frontmost app, Wi-Fi, Focus Filter) stay postponed and are not part of this spec.

This supersedes the M3 sentence in [implementation-plan.md](implementation-plan.md) that says the CLI hands off to a running app through a URL or XPC. Task 5.F updates that sentence to point here.

All command behavior lives in `OhMyDockCore`. The menu-bar app, the CLI, the URL handler, and App Intents are shells over one command center. No shell writes `com.apple.dock` except through `ProfileApplier`, `SnapshotUndo` / `SnapshotStore.restore`, and `DockPrefsWriter` as those types already do.

## 1. Process model

**The CLI links `OhMyDockCore` and applies headless. It does not hand off to the menu-bar app.** The app does not need to be running. URL scheme and App Intents run inside the menu-bar app, which is the only place a confirmation sheet exists.

The CLI and the app are peers on the same support directory and the same Dock. `DockOperationGate` stays an in-process UI mutex. Cross-process exclusion is a pair of advisory `fcntl` locks in the support directory. A running app reloads store and history changes with a file watcher. It does not apply a CLI command on the CLI's behalf.

### Why headless

- Scripts and agents work when the menu-bar app is quit, including over SSH and from a launchd job the user set up.
- A URL handoff cannot return the exit codes or the JSON document below. x-callback-url is a different app opening a URL, not a pipe back to the shell.
- Putting `--allow-quit` or `--yes` on a URL would let any webpage or app quit the user's programs. Those flags exist only on the CLI, in the process the user started.

### Why a lock, not "refuse when the app is open"

Refusing whenever the app is running makes the CLI unusable for the whole session of a menu-bar app. The dangerous overlap is two writers, not "an app happens to be open". Readers (`list`, `show`, `current`, `export`, a dry run) must keep working during normal use.

### Locks

Support root (mode `0700`, created if missing):

| Default | `~/Library/Application Support/oh-my-dock/` |
|---|---|
| Override | `OHMYDOCK_SUPPORT_DIR` (absolute path; see §3) |

| File | Mode | Role |
|---|---|---|
| `operation.lock` | `0600` | Serializes store and Dock mutations, and shared readers |
| `preview.lock` | `0600` | Held for a Dock-preferences preview, and held for the duration of a Dock mutation |

`fcntl(2)` `F_SETLK` / `F_SETLKW` on the whole file (`l_whence = SEEK_SET`, `l_start = 0`, `l_len = 0`). Exclusive is `F_WRLCK`, shared is `F_RDLCK`. The kernel drops the lock when the process exits, including `SIGKILL`. There is no pid file and no lock stealing. A hung holder is cleared by quitting that process; waiters time out and report busy.

`OperationLock` in `OhMyDockCore` owns the file descriptors. It is safe to share across tasks. One `withExclusive` / `withShared` does not nest on the same file. Acquire order, when both are taken, is **preview.lock then operation.lock**. Never wait for `preview.lock` while holding `operation.lock`.

| Action | `preview.lock` | `operation.lock` |
|---|---|---|
| `apply`, `undo`, `restore` | Exclusive, held until the call finishes. Non-blocking: if already held, fail immediately with preview-active / busy | Exclusive, wait up to the lock timeout |
| `save`, `delete`, `rename`, `duplicate`, `import`, snapshot `delete` / `pin` / `unpin` | None, except `save` fails immediately when `preview.lock` is held (a capture must not read a preview) | Exclusive, wait |
| `list`, `show`, `export`, `snapshots` / `history`, `status`, `doctor`, `version`, `completions` | None | `version` and `completions` take no lock. The others take a shared lock and wait |
| `current`, `apply --dry-run` | Non-blocking probe. If held, fail immediately (the Dock prefs on screen are not the saved state) | Shared, wait |
| Prefs preview in the app | Exclusive, held from the first preview write until revert or keep | None |

Default acquire timeout is **180 seconds** (`--lock-timeout`, or `OHMYDOCK_LOCK_TIMEOUT` in seconds). The app's confirmation sheet does not hold `operation.lock` (the sheet can sit for the existing 120s confirmation timeout). The lock is taken after the user accepts, around the actual `ProfileApplier.apply` / undo / restore. 180s covers that wait plus a switch that quits several apps at 5s each. `--lock-timeout 0` tries once and fails if the lock is not free. A failed acquire is exit `7` with `error.code` `locked` and `error.reason` `operationLock` or `previewActive`. The preview-active message string is `DockOperationGate.previewActiveMessage` (`Revert or keep the Dock preferences preview first.`).

The app's `DockOperationGate.run` keeps arrival order for the UI, then takes the same file locks inside the operation. `requireNoPreview()` stays. Both checks remain: the in-memory flag and `preview.lock`.

### How the app notices CLI writes

`StoreChangeWatcher` (app) watches the support root, `profiles/`, and `snapshots/` with `DispatchSource` file-system events (`write`, `rename`, `delete`, `extend`), debounced **200ms**, then calls the existing `DockChangeSignal` and `MenuBarViewModel.refresh()`. Refresh stays read-only.

`ProfileStore` writes are atomic. Snapshot creation writes the plist and then the metadata; the debounce covers that gap. A listing that still sees a torn pair surfaces the existing `ListResult.failures` entry and the next debounce clears it.

Editor: if the open profile has no uncommitted edits, reload it. If it has local edits and the file changed, show a conflict banner with Reload and Keep mine. Do not merge field-by-field. The editor already refuses to clobber a hotkey written by someone else; this is the same rule for the whole file.

### Confirmation

| Source | Who runs it | Quitting apps | Missing apps skipped | Dock write with nothing to quit or skip |
|---|---|---|---|---|
| CLI | Headless `ExternalCommandCenter` | Refuses unless **both** `--allow-quit` and `--yes`. No prompt, even on a TTY | Refuses unless `--yes` | Proceeds |
| URL | App sheet | Sheet, no bypass | Sheet | Sheet whenever the preview would write or launch |
| App Intent | Same sheet as a hotkey | Sheet when `ApplyPreview.confirmationRequired` | Same | Same rule as a menu click |
| Menu / hotkey | Unchanged | Unchanged | Unchanged | Unchanged |

CLI confirmation is not a dialog. The center calls `preview` first. When the preview would quit and the two flags are absent, or it would skip apps and `--yes` is absent, the center returns exit `5` and does not call `apply`. When the flags allow it, `apply` is called with `trigger: .user` and a confirm closure that returns `ApplyConfirmResult.accepted` (plus `--keep-running` bundle ids). The CLI never sets `ApplyTrigger.automatic` and never relies on `SwitchingOptions.quitOnAutomaticSwitch`. A profile that opted into silent automatic quits still does not quit from the CLI without the two flags.

URL and Intents also use `trigger: .user`. A URL cannot set `quitsAuthorized`. Query items named `allowQuit`, `yes`, `force`, or `quit` reject the whole URL.

`wouldEmptySection` and an unsatisfiable plan still fail after a yes. Confirm cannot empty a section.

### History source

`Snapshot` gains an optional `source` (`menu`, `hotkey`, `url`, `cli`, `intent`). Synthesized `Codable` already omits nil and ignores unknown keys, so existing snapshot files still load, and an older binary ignores the new key. `ProfileApplier`'s snapshot save and `SnapshotStore.restore`'s safety snapshot take the source and store it. `nil` means "not tagged" (snapshots already on disk).

Save, delete, rename, duplicate, and import do not change the Dock and do not create a snapshot. A history row appears only for apply, undo, and restore.

## 2. Shared command layer

New types under `Packages/OhMyDockCore/Sources/OhMyDockCore/External/`. The center is a struct with async methods, not a second applier. One process still relies on `ProfileApplier`'s actor for its own in-flight cancel; the file lock is what keeps two processes apart.

Move these app types into `OhMyDockCore` so the CLI and the app cannot drift: `ActiveProfileRecord` / `FileActiveProfileRecord`, `SpentUndoRecord` / `FileSpentUndoRecord`, and the undo implementation (`SnapshotUndoService`, `UndoTarget`, `UndoError`). The history window and the CLI both call that undo and a core `restore` that does `SnapshotStore.restore` + one `DockRestarter.restart()`. `DockChangeSignal` stays in the app; the watcher fires it after the files change.

`ActiveProfileMatcher.match(profiles:current:lastAppliedID:)` is the menu bar's `activeProfile(in:)` moved as-is: among profiles whose `dockState.matchesAfterWrite` the live Dock, the last-applied id wins; otherwise the greatest exact-tile score; ties keep name order. `current` also returns the other matching profiles so an agent can see that more than one profile fits.

`ProfileAddressing.resolve(_:in:)` :

- If the string is a UUID (`UUID(uuidString:)`), load that id. A miss is `notFound`. Do not also search names.
- Otherwise case-insensitive name match, the same comparison as `ProfileStore.profile(named:)`.
- One match: `found`. Zero: `notFound`. Two or more: `ambiguous` and the matches (id and name, sorted by id string).

The center sorts `list` by `localizedCaseInsensitiveCompare` on the name, then `id.uuidString` ascending, so the JSON is stable when two names differ only by case. `ProfileStore.list()` itself stays as it is.

### Command API

```swift
public enum ControlSource: String, Codable, Sendable {
    case menu, hotkey, url, cli, intent
}

public struct ExternalRequest: Sendable {
    public var command: ExternalCommand
    public var source: ControlSource          // .cli from the CLI; .url / .intent from the app
    public var yes: Bool
    public var allowQuit: Bool                // CLI apply only; app shells pass false and use `confirm`
    public var nonInteractive: Bool           // accepted; v0.3 has no prompts either way
    public var lockTimeout: Duration
    public var confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
}

public func run(_ request: ExternalRequest) async -> ExternalResult
```

`ExternalResult` carries the exit code, the stable `error.code`, a human message, and the payload the JSON encoder writes. Shells do not catch `ApplyError` themselves.

`ProfileApplier.apply` gains `controlSource: ControlSource? = nil` (default keeps every current call site) and passes it to `SnapshotStore.save`. `SnapshotStore.restore` gains the same parameter for the safety snapshot. `SnapshotStore.save` gains `source: ControlSource? = nil`.

### Dock plist override (tests only)

`OHMYDOCK_DOCK_PLIST`, absolute path to a **file**. The center builds `DockutilBackend` against that file and uses a restarter that does not restart anything (`--no-restart` is already how the backend writes; the restarter is the only `killall`). If the standardized path is the live Dock plist (`~/Library/Preferences/com.apple.dock.plist`, compared after `resolvingSymlinksInPath`), the process refuses before any Dock API call (`error.code` `liveDockPlistRefused`, exit `2`). The variable is not in the man page, not in `docs/agents.md`, and `doctor` does not suggest it. Production runs leave it unset and use the live backend and the real restarter.

## 3. Commands

Global flags (before or after the subcommand): `--json`, `--quiet`, `--no-color`, `--yes`, `--non-interactive`, `--lock-timeout <seconds>`.

`--allow-quit`, `--dry-run`, `--quit-scope`, and `--keep-running` exist only on `apply`. Anywhere else they are usage errors (exit `2`).

`--yes` on a command that does not use it is ignored.

| Command | Arguments and flags | Needs app? | Side effects | Core API |
|---|---|---|---|---|
| `list` | none. `--quiet` prints names only | No | None | `ProfileStore.list()` |
| `show <profile>` | address (§2) | No | None | `ProfileAddressing` + the stored `Profile` |
| `current` | none | No | None | `DockBackend.read()`, `ActiveProfileMatcher`, `ProfileApplier.preview` |
| `apply <profile>` | `--dry-run`, `--allow-quit`, `--yes`, `--quit-scope previous\|all\|none`, `--keep-running <bundleId>` (repeatable) | No | Dock write, one restart, snapshot, quits and launches when allowed. Dry run writes nothing | `preview`; then `apply(_:from:trigger:controlSource:confirm:)` |
| `save <name>` | `--force`, `--include-prefs` | No | New profile, or with `--force` replaces tiles of the one named profile. Does not change the Dock. Sets the active-profile record | `DockBackend.read()`, `ProfileStore.save` / `update`, `DockPrefsWriter.captureAsDockPrefs()` only with `--include-prefs` |
| `delete <profile>` | requires `--yes` | No | Removes the profile file. Clears the active-profile record when that id was current. Dock unchanged | `ProfileStore.delete` |
| `rename <profile> <new-name>` | no force flag | No | Renames. Dock unchanged. Id unchanged | `ProfileStore.rename` after the editor's uniqueness check |
| `duplicate <profile> <new-name>` | destination name required | No | New id, hotkey cleared, name must be free | `ProfileStore.duplicate` then clear hotkey |
| `undo` | none | No | Restores the undo target and restarts the Dock. Does not reopen quit apps. Marks mutation snapshots spent | Moved `SnapshotUndoService` |
| `snapshots` / `history` | `history` is an alias | No | None | `SnapshotStore.list()` |
| `snapshots pin <id>` / `unpin <id>` | id is a UUID | No | Metadata only | `pin` / `unpin` |
| `snapshots delete <id>` | requires `--yes` | No | Deletes that snapshot's plist and metadata. Dock unchanged | `SnapshotStore.delete` |
| `restore <id>` | requires `--yes`. `snapshots restore <id>` is the same command | No | `SnapshotStore.restore` (safety snapshot) + one restart. Does not reopen quit apps | core restore |
| `export <profile>` | `--format json\|script` (default `json`), `--output <file>` | No | Writes a file only when `--output` is set. `--output` refuses an existing path unless `--force` | `ProfileExchange.export` or `DockutilScriptExporter.export` |
| `import <file\|->` | `--name <name>` when the sanitized name is taken | No | Stores a new profile. Never overwrites. Never applies. Never fetches | `ProfileExchange.importProfile` then `ProfileStore.save` |
| `status` | none | No | None | lock probe, `NSRunningApplication` by bundle id, active-profile record, matcher |
| `version` | none | No | None | `OhMyDockCore.version` |
| `doctor` | none | No | None | helper lookup, store list, lock probe |
| `completions <zsh\|bash\|fish>` | shell name required | No | None | ArgumentParser's completion generator, plus profile names from `list` |

### `apply`

`--quit-scope` overrides `SwitchingOptions.quitScope` on a **copy** of the profile for this call. The stored profile is not modified. Default is the stored scope.

`--keep-running` fills `ApplyConfirmResult.excludedBundleIDs` (case-insensitive bundle ids). It still requires `--allow-quit` and `--yes` when any app remains in `willQuit`. It does not authorize quits by itself.

Previous profile for the quit scope is the matcher's result when that profile's id differs from the target; otherwise `nil` (`.previousProfileApps` then quits nothing). Same input the menu bar passes as `from`.

Idempotent apply: `ApplyResult.noChanges` is exit `0` and `result.status` `noChanges`. Nothing is snapshotted, written, or restarted. If apps would be skipped and `--yes` was not passed, the result is exit `5` even when the rest of the Dock already matches (the applier's current rule: a nil confirm and a non-empty `skipped` throw `confirmationRequired` before `.noChanges`). If apps would be quit, both flags are required even when the tiles and prefs already match; success is then `appsOnly`.

`--dry-run` is exit `0` when the preview was computed, including when a later real apply would exit `5`. The payload sets `confirmationRequired`, `willQuit`, and `skipped`. Unsatisfiable, `wouldEmptySection`, not found, ambiguous, locked, and preview-active are still errors. Dry run does not take a snapshot.

### `save`

Name is trimmed. Empty, or longer than `Profile.maxNameLength` (100), is exit `2`.

A new name stores `Profile(name:apps:others:)` from `DockBackend.read()`, prefs nil, default switching, no hotkey. That matches `MenuBarViewModel.saveCurrentDock`. The new id is written to the active-profile record.

`--force` when **exactly one** stored profile has that name: replace `apps` and `others`, keep `id`, `hotkey`, `switching`, and `prefs`. Zero matches with `--force` creates the profile. Two or more matches is exit `4` even with `--force` (pass nothing; names are not disambiguated by `--force`).

Without `--force`, an existing name is exit `6`, `error.code` `nameInUse`, and the store is unchanged.

`--include-prefs` sets `prefs` from `DockPrefsWriter.captureAsDockPrefs()` on the profile being written (new or overwritten). It does not write the Dock. Refused while `preview.lock` is held.

### `import`

Reads a local file, or stdin when the path is `-`. Stdin on a TTY is exit `2` (`pass a file or a pipe`). More than `ProfileExchange.maximumDocumentBytes` (1 MiB) is rejected by `ProfileExchange` before decode. `http:` and `https:` paths are exit `2`. A `file:` URL is accepted only as a local path.

The stored profile is the sanitized one (`ProfileExchange.importProfile`): new id, quit scope forced to `none`, force-quit cleared, launch-on-switch cleared. The command does not apply it and does not change the active-profile record.

If the sanitized name collides, exit `6` `nameInUse` and write nothing, unless `--name` provides a free name. There is no overwrite. The JSON lists `changes` from `SanitizedProfile` (stable case names: `droppedItem`, `forcedQuitScopeNone`, `clearedOfferForceQuit`, `clearedQuitOnAutomaticSwitch`, `clearedLaunchOnSwitch`, `idReassigned`, and the other `ImportSanitizationChange` cases).

### `export`

`json` is a `ProfileExchange` document (version 1, format `oh-my-dock-profile`). `script` is `DockutilScriptExporter` text. The script is not executed. `appMissingPath` and `invalidProfile` from the exporter are exit `6`, `error.code` `exportRefused`.

### `prefs`

**No `prefs` command in v0.3.** Dock preference keys are written only inside `ProfileApplier` (`DockPrefsWriter.apply`, snapshot, verify, rollback). A free `prefs set` would bypass that path and would fight a live preview. App settings (never-quit list, launch at login, hotkeys, the external-control switch) are not on the preview/apply path either. `show` includes the stored `prefs`. `current` includes the prefs diff from `ApplyPreview`. `save --include-prefs` captures through `captureAsDockPrefs()` and still does not write the Dock until a later `apply`.

### `status` and `doctor`

`status` is exit `0` when the support directory can be read, whether or not the app is running. Fields: `appRunning`, `bundleId` (`io.github.farzin-firoozi.OhMyDock`), `lock` (`free` or `held`), `preview` (`inactive` or `active`), `activeProfile` (`{id, name}` or null), `dockMatchesActive`, `externalControl` (`ask`, `allowed`, or `denied`), `supportDir`, `version`.

`doctor` prints checks. Exit `0` when none failed. Warnings do not fail the command.

| Check | Fail | Warn |
|---|---|---|
| `dockutil` | Missing or not executable | — |
| `support` | Root missing and cannot be created, or not writable | — |
| `profiles` | Directory unreadable | Individual files in `ListResult.failures`; duplicate names |
| `snapshots` | Directory unreadable | Individual failures |
| `app` | — | Not running |
| `operationLock` | — | Held |
| `previewLock` | — | Held |
| `plistOverride` | `OHMYDOCK_DOCK_PLIST` is set and resolves to the live plist | Set to some other file (the test hook is on) |

`dockutil` lookup order: `BundledTools.dockutilURL(in: Bundle.main)` when `Bundle.main` is `OhMyDock.app`; else the executable's sibling `../dockutil` (both live in `Contents/Helpers/`).

`externalControl` is read from the app's preference domain `io.github.farzin-firoozi.OhMyDock` (`UserDefaults(suiteName:)`), never from the CLI tool's own domain. The CLI does not write that domain.

## 4. Machine-readable contract

### stdout and stderr

| | stdout | stderr |
|---|---|---|
| Human success | The payload: list lines, show summary, dry-run text, export bytes, completions script, version line | Empty |
| Human failure | Empty | One message |
| `--json` success or failure | Exactly one JSON document, no other bytes, trailing newline | One short line on failure |
| `--json --quiet` | That document | Empty |
| `--quiet` human success | Empty for apply/save/delete/rename/duplicate/undo/restore/import. `list` prints one name per line. export, dry-run, completions, and version still print their payload | Empty on success |

Color is for human stdout/stderr only. It is off when `--no-color` is set, when `NO_COLOR` is set, or when the stream is not a TTY. JSON never contains ANSI.

### Non-interactive

v0.3 never prompts. `--non-interactive`, `--json`, and a non-TTY stdin are accepted so a later prompt cannot ignore them. A prompt added later must treat any of those three as "do not prompt; take the refusal exit". The quit rule does not loosen on a TTY: quits still need `--allow-quit` and `--yes`.

### Exit codes

| Exit | `error.code` | When |
|---|---|---|
| 0 | — (`ok: true`) | Success, including `noChanges` |
| 2 | `usage` | Bad arguments, unknown command, `--allow-quit` off `apply`, TTY stdin import, relative `OHMYDOCK_SUPPORT_DIR`, `liveDockPlistRefused`, `completions` combined with `--json` |
| 3 | `notFound` | Profile or snapshot id missing. `nothingToUndo` uses this exit with `error.code` `nothingToUndo` |
| 4 | `ambiguous` | Name matched more than one profile. `error.matches` is `[{id, name}]` |
| 5 | `needsConfirmation` | Apply would quit or skip apps and the required flags were not passed. Nothing written. Payload lists `quitApps`, `launchApps`, `skippedApps` |
| 6 | `conflict` | `nameInUse`, `dockChanged`, `targetChanged`, `wouldEmptySection`, `unsatisfiable`, `invalidProfile`, `prefsRejected`, `rejectedByBackend`, `exportRefused`. `error.reason` is that finer token |
| 7 | `locked` | `error.reason` `operationLock` or `previewActive` |
| 8 | `rolledBack` or `rollbackFailed` | `ApplyError.failedAndRolledBack` (`rolledBack`, Dock is back). `rollbackFailed` also exit `8`, `error.snapshotID` set, Dock may be inconsistent |
| 1 | `internal` | Anything else, including `prefsUnavailable` |
| 130 | — | `SIGINT` / cancellation. If the applier had started writing, it rolls back first (existing applier rule) and the process still exits `130` |

ArgumentParser's default validation exit (64) is not part of the contract. The CLI entry point maps validation and unknown commands to exit `2`. `--help` and `--version` exit `0`.

`error` always has `code`, `exitCode`, and `message`. Other keys appear only when they carry data. Unknown keys must be ignored by clients. Adding a key is not a `schemaVersion` bump; removing or retyping one is.

### JSON envelope

`schemaVersion` here is the **command envelope**, integer `1`. It is not `Profile.schemaVersion` and not `ProfileExchange`'s `version`.

Dates are ISO-8601 UTC with fractional seconds (`2026-10-20T15:04:05.000Z`). UUIDs are `UUID.uuidString` (uppercase), matching on-disk filenames. Clients compare ids case-insensitively.

```json
{
  "schemaVersion": 1,
  "command": "apply",
  "ok": true,
  "result": {}
}
```

```json
{
  "schemaVersion": 1,
  "command": "apply",
  "ok": false,
  "error": {
    "code": "needsConfirmation",
    "exitCode": 5,
    "message": "Switching would quit 1 app and needs confirmation: Slack",
    "reason": "quit",
    "quitApps": [{ "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap" }],
    "launchApps": [],
    "skippedApps": []
  }
}
```

`command` is the canonical name: `history` and `snapshots restore` still report `snapshots` and `restore`.

### Per-command `result`

**list**

```json
{
  "profiles": [
    {
      "id": "UUID",
      "name": "Work",
      "appCount": 12,
      "otherCount": 3,
      "hasPrefs": true,
      "quitScope": "previousProfileApps"
    }
  ],
  "unreadable": [{ "path": "/…/x.json", "message": "…" }]
}
```

**show** — `result.profile` is the stored profile object (`Profile.jsonData()` shape): `id`, `name`, `schemaVersion`, `apps`, `others`, `prefs`, `switching`, `hotkey`.

**current**

```json
{
  "matchedProfile": { "id": "UUID", "name": "Work" },
  "otherMatches": [],
  "differs": true,
  "noChanges": false,
  "confirmationRequired": false,
  "clearsRecentApps": false,
  "planSummary": "…",
  "prefsDiff": [{ "key": "autohide", "target": true }],
  "willQuit": [],
  "willLaunch": [],
  "skipped": []
}
```

`matchedProfile` is null when nothing matches. That is still exit `0`. `prefsDiff[].target` is a bool, a number, a string, or null for a reset key. Omitted when the profile has no prefs.

**apply** (and dry run)

```json
{
  "status": "applied",
  "profile": { "id": "UUID", "name": "Work" },
  "snapshotID": "UUID",
  "restarted": true,
  "clearsRecentApps": false,
  "skipped": [{ "name": "Gone", "bundleId": "com.example.gone", "section": "apps" }],
  "prefsChangedKeys": ["autohide"],
  "planSummary": "…",
  "confirmationRequired": false,
  "willQuit": [{ "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap" }],
  "willLaunch": [{ "name": "Xcode", "bundleId": "com.apple.dt.Xcode" }],
  "switchOutcome": {
    "summary": "Quit 1",
    "wasCancelled": false,
    "quits": [{ "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap", "status": "quit" }],
    "launches": [{ "name": "Xcode", "bundleId": "com.apple.dt.Xcode", "status": "launched" }]
  }
}
```

`status` is `applied`, `noChanges`, `appsOnly`, or `dryRun`. `snapshotID` and `switchOutcome` are omitted when there is none. Quit `status` is the `QuitStatus` raw name: `quit`, `alreadyExited`, `refused`, `stillRunningAfterTimeout`, `quitRequestedUnconfirmed`, `skippedProtected`, `skippedCancelled`. Launch `status` is `launched`, `alreadyRunning`, `failed`, `skippedCancelled`. No process ids.

**save / delete / rename / duplicate / import** — `{ "profile": { "id", "name" } }` after the write. Import also has `changes: [{ "kind": "forcedQuitScopeNone", "detail": "previousProfileApps" }]`. Delete has `profile` of the removed one.

**undo / restore** — `{ "snapshotID", "restarted": true, "source": "cli" }`.

**snapshots**

```json
{
  "snapshots": [
    {
      "id": "UUID",
      "createdAt": "2026-10-20T15:04:05.000Z",
      "reason": "Before applying profile Work",
      "profileName": "Work",
      "pinned": false,
      "byteSize": 12345,
      "sha256": "…",
      "source": "cli"
    }
  ],
  "unreadable": []
}
```

`source` is omitted when the file has none.

**export** — with no `--output`, stdout is the document itself in human mode (not wrapped). With `--json` and no `--output`, `result.format` is `json` or `script` and `result.document` is the string. With `--output`, both modes write the file and the JSON `result` is `{ "format", "path" }` (the document is not also inlined).

**status** — the fields in §3. **doctor** — `{ "checks": [{ "name", "status": "pass"|"warn"|"fail", "detail": "…" }] }`. **version** — `{ "version": "0.3.0" }` using `OhMyDockCore.version`.

### Environment

| Variable | Contract |
|---|---|
| `OHMYDOCK_SUPPORT_DIR` | Absolute path replacing `~/Library/Application Support/oh-my-dock`. Profiles, snapshots, both locks, `active-profile.json`, and `undo-spent.json` live under it. Relative paths exit `2` |
| `OHMYDOCK_LOCK_TIMEOUT` | Whole seconds. `--lock-timeout` wins. Default 180. `0` is try-once |
| `NO_COLOR` | Any value disables human color |
| `OHMYDOCK_DOCK_PLIST` | Test-only. See §2. Not documented in the man page or the agent doc |

No network from any command, URL handler, or intent. No credentials, no update check on the CLI path.

### Idempotency summary

| Call | Second call with the same inputs and an unchanged Dock |
|---|---|
| `apply` of the matching profile, nothing to quit or skip | Exit `0`, `noChanges` |
| `apply` that would quit, without both flags | Exit `5` every time, Dock unchanged |
| `save` of an existing name without `--force` | Exit `6` every time, store unchanged |
| `delete` of a missing profile | Exit `3` |
| `undo` after a successful undo | Exit `3`, `nothingToUndo` |
| `import` of a document whose name now exists | Exit `6` unless `--name` is free |

## 5. URL scheme

Registered on the app only (`CFBundleURLTypes` in `App/Info.plist`, scheme `ohmydock`, URL name `io.github.farzin-firoozi.OhMyDock`). The app does not register as a handler for JSON or shell files.

Grammar: `ohmydock://<command>?<query>`. The command is the host. There is no path. Parse with `URLComponents`. `+` is not a space. Invalid percent-encoding rejects the URL. Names and ids are UTF-8 percent-encoded (`Work` stays `Work`, `A B` is `A%20B`).

| URL | v0.3 behavior |
|---|---|
| `ohmydock://apply?profile=<name-or-uuid>` | Resolve, then the app confirmation rule in §1. On accept, `ExternalCommandCenter` with `source: .url` |
| `ohmydock://save?name=<name>` | Sheet to confirm the save. Existing name asks before overwrite (same bytes as `save --force`: tiles replaced, id, hotkey, switching, prefs kept). Missing `name` opens the menu bar's existing naming UI |
| `ohmydock://undo` | Sheet: restore the previous Dock; quit apps are not reopened. On accept, undo with `source: .url` |
| `ohmydock://open?window=editor\|history\|settings` | Opens that window. Always allowed, including when external control is denied |
| `ohmydock://import?url=<percent-encoded-url>` | **Not implemented.** No `URLSession`, no fetch, no file read. Error `notImplemented`. Reserved for Phase 6 gallery import |

Unknown hosts are `usage`. Unknown query items on `apply`, `save`, `undo`, and `open` are ignored, except the forbidden authorization names in §1, which reject the URL. `import` allows only `url`, `x-success`, and `x-error`.

### App not running

The system launches the app. `AppDelegate` holds the URL until `MenuBarViewModel.start()` has finished (first-launch capture included), then the router runs. A failed launch has no callback.

### External control setting

`UserDefaults` key `externalControl` in the app domain. Values: absent or `ask`, `allowed`, `denied`.

**Recommended default: `ask`.** The first mutating URL (`apply`, `save`, `undo`) shows one consent sheet: other apps and web pages can ask oh-my-dock to apply a profile, save, or undo; they still cannot quit apps without the in-app sheet. Buttons: Allow (default) and Don't Allow. Allow stores `allowed`. Don't Allow stores `denied` and drops that URL.

The setting gates **URLs only**. The CLI is a process the user started. App Intents are a Shortcut the user ran; Shortcuts has its own permission. `open` is always allowed.

Settings shows the current value and can switch it later. Denied mutating URLs show a banner and, when `x-error` is legal, call it with `errorCode=externalControlDenied`.

### x-callback-url

`x-success` and `x-error` are optional. A missing callback means the action still runs and nothing is opened afterward.

When either value is present it must parse as a URL whose scheme matches `^[A-Za-z][A-Za-z0-9+.-]*$` and is not `http`, `https`, `file`, `javascript`, `data`, `ohmydock`, `about`, `blob`, or `ftp`. No userinfo. An illegal callback rejects the **whole** URL before any Dock or store write, so the app cannot be used as an arbitrary-URL opener.

On success the app opens `x-success` with `profile`, `profileID`, and `status` appended (existing query items kept). On failure it opens `x-error` with `errorCode` and `errorMessage` (message truncated to 200 characters). One callback per URL. The profile body is not put on the callback.

### Dedupe

In-memory, per app launch. The key is host plus query items except `x-success` and `x-error`, names sorted. The same key within **1.0s**, or while that command is in flight, is dropped. A dropped URL with a legal `x-error` gets `errorCode=duplicate`. At most one mutating URL (`apply`, `save`, `undo`) starts every **2 seconds**; excess gets `errorCode=rateLimited`. `open` is not rate-limited. The CLI is not rate-limited.

## 6. App Intents

Intents live in the app target (`App/Intents/`). No extension, so they share the command center, the locks, and `ConfirmationPresenting`. `openAppWhenRun` is false (menu-bar app). When a sheet is required, reuse the hotkey presenter's floating panel. The system launches the app if it is quit.

| Intent | Parameters | Confirmation | Result |
|---|---|---|---|
| `ApplyProfileIntent` | `profile: ProfileEntity` | Sheet iff `ApplyPreview.confirmationRequired`, `source: .intent`, `trigger: .user` | Dialog: applied / already on the Dock / cancelled. Returns the profile entity |
| `SaveCurrentDockIntent` | `name: String`, `overwrite: Bool` default false | Sheet when `overwrite` is true and the name exists | Dialog with the saved name. Same overwrite bytes as `save --force`. Does not capture prefs (no `--include-prefs` equivalent; a Shortcut that wants prefs uses the editor) |
| `ListProfilesIntent` | none | None | `ReturnsValue<[ProfileEntity]>` plus a dialog with the count |
| `UndoLastChangeIntent` | none | Always `requestConfirmation` ("Restore the previous Dock? Apps that were quit are not reopened.") | Dialog. `nothingToUndo` is a failed dialog |

Preview-active and lock-busy return a failed dialog with the same messages as the CLI. No intent calls `forceTerminate`.

`ProfileEntity`: `id` is the UUID string, `name` is the display title, `defaultQuery` is `ProfileEntityQuery` (`entities(for:)`, `suggestedEntities()` sorted like `list`, `entities(matching:)` case-insensitive contains). The apply parameter is the entity, not a free-form string, so a duplicate name is chosen in the Shortcuts picker rather than guessed.

`OhMyDockShortcuts` (`AppShortcutsProvider`), system image `dock.rectangle`:

| Intent | Phrases |
|---|---|
| Apply | "Apply \(\.$profile) Dock profile with \(.applicationName)", "Switch Dock to \(\.$profile) with \(.applicationName)" |
| Save | "Save my Dock as a profile with \(.applicationName)" |
| Undo | "Undo my last Dock change with \(.applicationName)" |

`ListProfilesIntent` is in the Shortcuts app and has no Siri phrase.

Focus Filter (`SetFocusFilterIntent`) is not in v0.3.

## 7. Packaging

### Where the binary lives

`OhMyDock.app/Contents/Helpers/ohmydock`, next to `dockutil`. Not `Contents/MacOS/`: that directory is the main executable (`CFBundleExecutable` is `OhMyDock`). Homebrew's `binary` stanza symlinks its Cellar/`bin` path at the helper inside the installed app; it does not copy the binary out. Upgrades replace the app and rewrite the symlink. `xattr -dr com.apple.quarantine` on the app, which the cask `postflight` already does, covers the helper and the CLI. Update the `binary` line in [distribution.md](distribution.md) (task 5.F) and `packaging/homebrew-tap/Casks/oh-my-dock.rb` (task 5.E). The cask test that currently forbids a `binary` stanza is inverted.

`Bundle.main` for a helper executed from `Contents/Helpers/` is the `.app` (the walk up finds `Contents/Info.plist`). `doctor` still has the sibling-path fallback for a copy that was not launched from the bundle.

### How it is built

XcodeGen tool target `ohmydock`, sources in `CLI/`, macOS 14, Swift 6 strict concurrency. Dependencies: `OhMyDockCore` and `swift-argument-parser` from `1.5.0`. The library does not depend on ArgumentParser. The app target depends on the tool target and copies the product to `Contents/Helpers/ohmydock` with a post-build script in the same style as dockutil (fail the Release build if the product is missing). `ENABLE_HARDENED_RUNTIME` on the tool matches the app. No Apple Events entitlement and no `NSAppleEventsUsageDescription` (spike 0.6).

`make cli` builds the tool scheme. `make build` builds the app scheme, which builds and embeds the tool. `OhMyDockCore.version` is bumped to the marketing version in task 5.E so `ohmydock version` and the app agree.

### Signing

`scripts/release.sh` already signs inside-out. Add an explicit ad-hoc sign of `Contents/Helpers/ohmydock` **after** `dockutil` and **before** the outer app, with the same `codesign --force --sign - --options runtime --timestamp=none` used for the helper. The existing `find` for frameworks does not see a bare Mach-O in Helpers; do not rely on it for the CLI. Verify both helpers and the app with `codesign --verify --deep --strict`.

### `verify-release.sh`

`TOTAL_CHECKS` stays **7**. Each existing check grows:

| Check | Addition |
|---|---|
| 2 | `Contents/Resources/ThirdParty/swift-argument-parser/LICENSE` exists and is non-empty (MIT, the upstream text pinned with the package). `THIRD_PARTY_NOTICES.md` lists it |
| 3 | `Contents/Helpers/ohmydock` exists and is executable |
| 4 | `codesign --verify --deep --strict --verbose=2` on `ohmydock` as well as the app and dockutil |
| 5 | `codesign -dv` on `ohmydock` contains `Signature=adhoc` |
| 6 | `ohmydock` has its own signature; `CodeResources` seals `Helpers/ohmydock` and that CDHash |
| 7 | `CFBundleURLTypes` contains the scheme `ohmydock` exactly once. Existing bundle id, `LSMinimumSystemVersion` 14.0, and `LSUIElement` checks stay |

`scripts/test-verify-release.sh` plants a fake `ohmydock`, the license file, and a CodeResources seal, and asserts the same pass/fail shape it already asserts for dockutil.

### Cask, completions, man page

```ruby
binary "#{appdir}/OhMyDock.app/Contents/Helpers/ohmydock"
manpage "OhMyDock.app/Contents/Resources/ohmydock.1"
```

The man page source is `CLI/ohmydock.1` (NAME, SYNOPSIS, DESCRIPTION, GLOBAL OPTIONS, COMMANDS, EXIT STATUS, ENVIRONMENT, FILES, EXAMPLES, SEE ALSO), copied into `Contents/Resources/`. It documents exit codes, `--json`, the quit flags, and `OHMYDOCK_SUPPORT_DIR`. It does not document `OHMYDOCK_DOCK_PLIST`.

`ohmydock completions zsh|bash|fish` prints a script that completes subcommands, flags, and profile names by invoking `ohmydock list --quiet`. The cask does not install completion files (no stable cask stanza for that). The man page and the cask caveats show `eval "$(ohmydock completions zsh)"` and the bash/fish equivalents. `--json` with `completions` is exit `2`.

### Tests

Library: `Packages/OhMyDockCore/Tests/OhMyDockCoreTests/External/` against `FakeDockBackend`, a temp support directory, in-memory prefs, and the fake switcher. No live Dock, no `killall`. Cover the exit map, both quit flags, idempotent `noChanges`, ambiguous names, preview-lock refusal, lock timeout `0`, import sanitizer report, and `OHMYDOCK_DOCK_PLIST` refused when it is the live plist path.

App: view-model tests for URL vs intent confirmation policy, watcher reload, and the gate taking the file lock. No app launch.

Process smoke, `scripts/cli-smoke.sh`, from `make test` after the tool is built: temp `OHMYDOCK_SUPPORT_DIR`, temp plist **file** (a fixture copy, never a directory), `OHMYDOCK_DOCK_PLIST` set to that file. Run `list`, `save`, `apply --dry-run`, `doctor`, and one `--json` error (`apply` missing). Assert exit codes and `schemaVersion`. Stat the real `~/Library/Preferences/com.apple.dock.plist` before and after and fail if it changed. Do not launch `OhMyDock.app`.

## 8. Agent doc (`docs/agents.md`, written in task 5.F)

Outline, in this order:

1. **What this is.** Local CLI and URL/Shortcuts. No MCP in v0.3. No network. No live-Dock advice beyond the commands.
2. **Invoke.** `ohmydock --json --non-interactive …`. Human text is not stable. JSON envelope §4 is the contract. Ignore unknown keys.
3. **Safe sequence.** `current` or `apply <profile> --dry-run` first. Read `willQuit`, `skipped`, `confirmationRequired`, `clearsRecentApps`. Apply only after that.
4. **Exit codes.** Table from §4. `0` with `status: noChanges` is success. `5` means do not retry with `--allow-quit` unless the user agreed. `7` means wait and retry once. `8` with `rollbackFailed` means stop and tell the user the snapshot id.
5. **Quitting apps.** The sentence to keep: never pass `--allow-quit` unless the user has agreed to quit those apps. `--yes` alone does not permit quits. `--quit-scope none` applies a layout without quits. There is no force-quit flag.
6. **Examples.** `list`, `current`, `apply Work --dry-run`, `apply Work --yes` when the dry run shows no quits, `apply Work --quit-scope none --yes` when apps would be skipped, a `5` response body, `save "Client call"`, `import ./work.json`, `undo`.
7. **Paste-in snippet** for a user's `AGENTS.md` / `CLAUDE.md`:

```markdown
## oh-my-dock

Use the `ohmydock` CLI with `--json --non-interactive`. Treat stdout as one JSON document (`schemaVersion` 1); the exit code is the contract (0 success, 2 usage, 3 not found, 4 ambiguous name, 5 needs confirmation, 6 conflict, 7 busy, 8 rolled back, 1 internal). Dry-run `ohmydock apply <profile> --dry-run --json` before applying. Never pass `--allow-quit` unless the user has agreed to quit the apps listed in `willQuit`. `--yes` alone does not permit quits. Do not write `~/Library/Preferences/com.apple.dock.plist` yourself and do not `killall Dock`.
```

8. **Future MCP wrapper.** Not in v0.3. A thin wrapper shells `ohmydock --json --non-interactive` and maps exit codes. Tools match commands 1:1: `list`, `show`, `current`, `apply`, `save`, `delete`, `rename`, `duplicate`, `undo`, `snapshots`, `restore`, `export`, `import`, `status`, `doctor`. `apply` parameters: `profile`, `dryRun`, `allowQuit` default false, `yes` default false, `quitScope`, `keepRunning`. The wrapper must not default `allowQuit` to true. No tool for `completions` or the test plist variable. No network tool. The URL `import?url=` slot is where a later gallery tool would go; the wrapper does not fetch in v0.3.

## 9. Tasks

Phase 5 uses only **composer-2.5** (every build task) and **grok-4.7** (review and verify). That overrides the tier table, the Sol/Terra review rule, and the "safety-critical goes to a high-tier author" rule for this phase only. Triggers stay postponed and are not assigned.

Groups run in order. Tasks in the same group may run in parallel in separate worktrees because their files do not overlap.

### 5.A — Command center, locks, source tag

**Model:** composer-2.5. **Group:** A. **Depends on:** —

**Files:** `Packages/OhMyDockCore/Sources/OhMyDockCore/External/` (new), `Snapshot.swift` / `SnapshotStore.save` / `restore`, `ProfileApplier.apply` signature, moved `ActiveProfileRecord`, `SpentUndoRecord`, `SnapshotUndoService`. App: `DockOperationGate` acquires `OperationLock`; prefs preview holds `preview.lock`; `StoreChangeWatcher`; `MenuBarViewModel` passes `.menu` / `.hotkey` and calls `ExternalConfirmationPolicy`; editor conflict banner. App tests for the policy and the watcher.

**Acceptance:**

- CLI-shaped requests run against fakes with no app process: the command table in §3, the exit table in §4, idempotent `noChanges`, `--allow-quit` without `--yes` exits `5` and does not quit, both flags quit, `--quit-scope` does not persist, `--keep-running` fills `excludedBundleIDs`.
- `preview.lock` held → apply, current, dry-run, and save exit `7` with the preview message.
- `operation.lock` held and `--lock-timeout 0` → exit `7`.
- Killing a holder releases the lock (fcntl). A second process acquires it.
- New snapshots from apply and from restore carry `source`. Old snapshot JSON still decodes.
- URL policy: a URL preview that writes or launches requires a prompt even when `confirmationRequired` is false. An intent preview requires a prompt only when `confirmationRequired` is true.
- `OHMYDOCK_DOCK_PLIST` equal to the live plist path fails before any backend call.

**Tests:** Swift Testing in `OhMyDockCoreTests/External/` plus the existing applier tests still passing. App unit tests for the gate and the policy. No live Dock.

### 5.B — URL scheme

**Model:** composer-2.5. **Group:** B. **Depends on:** 5.A.

**Files:** `App/Info.plist` (`CFBundleURLTypes`), `App/URL/` (router, dedupe, consent), `App/OhMyDockApp.swift` / `AppDelegate.swift` (queue until `start()` finishes), Settings toggle. Does not edit `project.yml` or `CLI/`.

**Acceptance:**

- Each route in §5 does what that table says. `import?url=` performs no network (test double fails if a session is created).
- Forbidden query names and an `https` `x-success` cause no store write and no Dock write.
- A second identical `apply` inside 1.0s does not apply twice.
- `externalControl=denied` drops mutating URLs and still opens `open?window=settings`.
- First `ask` shows consent, then the action sheet. Allow persists.
- A URL that would quit shows the sheet and quits nothing before accept. Source on the snapshot is `url`.

**Tests:** router unit tests with a fake center and a fake opener. No app launch, no live Dock.

### 5.C — CLI

**Model:** composer-2.5. **Group:** B. **Depends on:** 5.A. Parallel with 5.B.

**Files:** `CLI/` (ArgumentParser shells only), `project.yml` (tool target, package `from: 1.5.0`, embed script), `Makefile` `cli` target. Does not edit `App/` sources other than what the embed script in `project.yml` needs. No man page yet (5.E).

**Acceptance:**

- Every command in §3 is reachable. Global flags work before and after the subcommand. Validation exits `2`, not 64.
- `--json` rules in §4, including quiet and `completions` rejecting `--json`.
- The binary is embedded at `Contents/Helpers/ohmydock` in a Debug app build.
- Smoke script §7 passes, including the live-plist mtime check.

**Tests:** smoke script plus the 5.A library tests. The shell contains no new policy; if a test needs a behavior, it belongs in 5.A.

### 5.D — App Intents

**Model:** composer-2.5. **Group:** C. **Depends on:** 5.A and 5.B (5.B owns the app entry and Settings; intents add `App/Intents/` only).

**Files:** `App/Intents/` (`ApplyProfileIntent`, `SaveCurrentDockIntent`, `ListProfilesIntent`, `UndoLastChangeIntent`, `ProfileEntity`, `OhMyDockShortcuts`).

**Acceptance:**

- The four intents call the command center with `source: .intent` and the confirmation column in §6.
- Apply takes a `ProfileEntity` id, not a raw name.
- Undo uses `requestConfirmation` before restore.
- Preview-active returns a failed dialog and does not write.
- Snapshot source is `intent`.
- No `SetFocusFilterIntent`.

**Tests:** intent `perform()` against the fake center / fake presenter in `OhMyDockTests`. No app launch.

### 5.E — Packaging

**Model:** composer-2.5. **Group:** C. **Depends on:** 5.C. Parallel with 5.D (scripts, cask, license, man page; no `App/Intents/`).

**Files:** `scripts/release.sh`, `scripts/verify-release.sh`, `scripts/test-verify-release.sh`, `CLI/ohmydock.1`, `ThirdParty/swift-argument-parser/LICENSE`, `THIRD_PARTY_NOTICES.md`, `packaging/homebrew-tap/Casks/oh-my-dock.rb`, `packaging/homebrew-tap/test-cask.sh`, `OhMyDockCore.version` bump to the marketing version.

**Acceptance:**

- Release signs `dockutil`, then `ohmydock`, then the app. `codesign --verify --deep --strict` passes on all three.
- `verify-release.sh` is still 7 checks and covers §7. `test-verify-release.sh` passes.
- Cask has the `binary` and `manpage` stanzas in §7 and still has no network beyond the existing release URL.
- `ohmydock completions zsh` emits a script; `zsh -n` accepts it. The man page lists every command and the exit table.

**Tests:** `test-verify-release.sh`, `test-cask.sh`, `zsh -n` on the completion script. Do not run the cask against the live machine's Dock.

### 5.F — Docs

**Model:** composer-2.5. **Group:** D. **Depends on:** 5.A–5.E.

**Files:** `docs/agents.md` (from §8), `docs/README.md` index rows for this design and `agents.md`, `docs/distribution.md` binary path, `docs/features.md` CLI/URL lines, `docs/technical-notes.md` short "External control" pointer, `docs/implementation-plan.md` M3 (remove the handoff sentence, point here, drop triggers from the v0.3 done-when). No behavior changes.

**Acceptance:** `docs/agents.md` matches §8, including the paste-in snippet and the MCP tool list. A reader can run every example from the command table without reading this design.

### 5.R — Review and verify

**Model:** grok-4.7. **Group:** E. **Depends on:** 5.A–5.F.

Review every Phase 5 change. Focus on quit authorization (CLI flags, URL query rejection, intent sheet), lock order, preview interaction, import not fetching, and the live-plist test hook refusing the real Dock file. Then run `make test`, `make build`, and `verify-release` on the built app. No live Dock and no `killall Dock`.

## 10. Risks

| Risk | What the spec does |
|---|---|
| CLI and app write the Dock at the same time | `operation.lock` plus `preview.lock` around apply, undo, and restore |
| A webpage fires `ohmydock://apply` and quits apps, or rewrites the Dock with no sheet | URLs cannot carry quit flags. URL writes and launches always go through the sheet. First-use consent gates mutating URLs. Dedupe and the 2s rate limit cut repeats |
| A webpage uses `x-success=https://…` as an opener | Illegal callbacks reject the whole URL before any write |
| `import?url=` fetches a profile early | Handler does not create a `URLSession`. Phase 6 owns the fetch, under the gallery rules |
| CLI `--allow-quit` from an agent | Exit `5` unless both flags are present. Agent doc forbids `--allow-quit` without a user yes. No force-quit on any shell |
| Prefs preview is undone by a CLI apply, or a CLI captures previewed prefs | Mutations and `current` / dry-run / `save` fail while `preview.lock` is held |
| Stale lock after a crash | `fcntl` releases on process death. No pid file |
| Apply holds the lock for a long quit loop; a second client gives up | 180s default timeout; `--lock-timeout` to change it. Exit `7` is safe to retry |
| Duplicate profile names already on disk | Resolver returns ambiguous (exit `4`). `doctor` warns. No automatic rename |
| `OHMYDOCK_DOCK_PLIST` pointed at the live plist | Refused before any Dock call |
| ArgumentParser exiting 64 | Entry point maps usage to exit `2` |
| Helper signed after the outer app, so the seal breaks | `release.sh` signs `ohmydock` before the app; check 6 compares CDHash |
| Two undo implementations | One undo type in `OhMyDockCore`, used by the app and the CLI |

## 11. Open questions

Decisions already made above stand unless you override them. These five change behavior enough that they should be an explicit yes:

1. **External-control default.** Recommended: stored value `ask`, first mutating URL shows Allow / Don't Allow, Allow is the default button. The switch gates URLs only; CLI and App Intents are not gated. `open` always works.
2. **URL sheet when nothing would quit.** Recommended: a URL that would write the Dock or launch an app always shows the sheet, even when `confirmationRequired` is false. Intents stay on the menu-bar rule (sheet only when confirmation is required).
3. **`save --force` and `--include-prefs`.** Recommended: `--force` replaces tiles and keeps id, hotkey, switching, and prefs. `--include-prefs` copies live Dock prefs onto that profile via `captureAsDockPrefs()` and does not write the Dock. Import never overwrites.
4. **Duplicate names already in the store.** Recommended: do not migrate or rename them. `apply`/`show` by name exits `4` until the user renames one. `doctor` warns.
5. **`OHMYDOCK_SUPPORT_DIR`.** Recommended: public, documented, absolute path only, so tests and agents can use a spare store. Anyone who can run the CLI as the user can already read the real support directory.
