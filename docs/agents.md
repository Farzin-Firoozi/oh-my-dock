# oh-my-dock — guide for AI agents and automation

This document is the operational contract for driving **oh-my-dock** from scripts, CI, or an AI agent. You do not need to read [external-control-design.md](external-control-design.md) if you follow this page.

## What this is

**oh-my-dock** is a macOS menu-bar app that saves and switches **named Dock profiles** (tile layout, optional Dock preference keys, optional app quit/launch on switch). All Dock writes go through the same core library as the app: bundled **dockutil**, snapshot-before-apply, verify-after-write, and undo.

**What the CLI can do**

- List, show, import, export, save, rename, duplicate, and delete **profiles** (JSON on disk under the support directory).
- Read the **live Dock**, compare it to profiles (`current`), and **apply** a profile (Dock write + one Dock restart + snapshot when something changes).
- **Undo** the last layout change, **restore** or manage **snapshots** (history).
- Report **status** and run **doctor** checks (no Dock mutation).

**What the CLI cannot do**

- There is **no MCP server** in v0.3; shell the CLI (or a future thin wrapper) instead.
- No network, no gallery fetch, no `prefs set` command (Dock prefs are applied only inside `apply` / restore paths).
- No automatic triggers (Focus, display, Wi-Fi, schedule, frontmost app) — those are postponed.
- Cannot bypass quit confirmation with `--yes` alone; quits require **`--allow-quit` and `--yes`** together.
- Does not open the menu-bar app or show GUI confirmation (that is URL / Shortcuts only).

**Never do this yourself**

- Do not edit `~/Library/Preferences/com.apple.dock.plist` by hand.
- Do not run `killall Dock` outside oh-my-dock’s own apply/undo/restore flow.

## Install and locating the binary

| Source | Path |
|---|---|
| Inside the app bundle | `OhMyDock.app/Contents/Helpers/ohmydock` (next to `dockutil`; **not** `Contents/MacOS/`) |
| Homebrew cask | `brew install --cask Farzin-Firoozi/tap/oh-my-dock` installs the app; the cask **`binary`** stanza symlinks `ohmydock` in your PATH to `…/OhMyDock.app/Contents/Helpers/ohmydock` |
| Build from source | `make build` embeds the tool in a Debug/Release app under `build/Build/Products/…/OhMyDock.app/Contents/Helpers/ohmydock`; `make cli` builds the tool alone |

The CLI runs **headless**: the menu-bar app does **not** need to be running. It uses the same support directory as the app.

Default support directory: `~/Library/Application Support/oh-my-dock/` (profiles, snapshots, `operation.lock`, `preview.lock`, `active-profile.json`, `undo-spent.json`).

## Invoke the CLI

Always prefer machine-readable output:

```sh
ohmydock --json --non-interactive <command> …
```

- **Stdout (`--json`)**: exactly **one** JSON document per run (envelope `schemaVersion`: **1**), then a trailing newline. Human-readable lines are **not** a stable API.
- **Exit code**: primary success/failure signal (see below).
- **`--non-interactive`**, **`--json`**, and piped stdin are treated as non-interactive; v0.3 never prompts, but flags reserve behavior for later.
- Ignore unknown JSON keys on the envelope, `result`, and `error` objects.

Global flags (may appear **before or after** the subcommand):

| Flag | Purpose |
|---|---|
| `--json` | JSON envelope on stdout |
| `--quiet` | Minimal stdout on success (see command notes) |
| `--no-color` | Disable ANSI color on human output |
| `--yes` | Required for destructive store ops and for apply when apps would be skipped; with `--allow-quit` for quits |
| `--non-interactive` | Non-interactive mode |
| `--lock-timeout <seconds>` | Advisory lock wait (default **180**; env `OHMYDOCK_LOCK_TIMEOUT`; **0** = try once) |
| `--version` | Same as `ohmydock version` |

`--allow-quit`, `--dry-run`, `--quit-scope`, and `--keep-running` are valid **only** on `apply`; elsewhere they are usage errors (exit **2**).

## Safe workflow

1. **`ohmydock list --json`** — know profile names/ids; handle `unreadable` entries if present.
2. **`ohmydock show <profile> --json`** or inspect list metadata.
3. **`ohmydock current --json`** and/or **`ohmydock apply <profile> --dry-run --json`** — read `willQuit`, `willLaunch`, `skipped`, `confirmationRequired`, `clearsRecentApps`, `planSummary`, `prefsDiff` (on `current` when a profile matches).
4. If the dry run is acceptable and **no quits** (or user agreed to quits): **`ohmydock apply <profile> --yes --json`**; add **`--allow-quit`** only when the user explicitly agreed to every app in `willQuit`.
5. If apps would be **skipped** (missing paths): use **`--yes`** (and often **`--quit-scope none`** if you must avoid quits).
6. On success, **`undo`** is available for the last layout mutation (not for save/delete/rename).

If exit **7** (`locked` / preview active): wait for the menu-bar prefs preview to finish or for the other process to release the lock, then retry with `--lock-timeout 0` once to probe, or a normal timeout.

If exit **8** with `rollbackFailed`: stop and give the user the `error.snapshotID`; the Dock may be inconsistent.

## Command reference

Side effects: **Dock** = modifies live Dock plist + restart; **Store** = profiles/snapshots/active record only; **None** = read-only.

| Command | Arguments / flags | App running? | Side effects | Exit (typical) | JSON `command` | Main `result` fields |
|---|---|---|---|---|---|---|
| `list` | `--quiet` → names only | No | None | 0 | `list` | `profiles[]`, `unreadable[]` |
| `show` | `<profile>` name or UUID | No | None | 0 / 3 / 4 | `show` | `profileDocument` (base64 profile JSON) |
| `current` | | No | None | 0 / 7 | `current` | `matchedProfile`, `otherMatches`, `differs`, `noChanges`, `confirmationRequired`, `willQuit`, `willLaunch`, `skipped`, `prefsDiff`, … |
| `apply` | `--dry-run`, `--allow-quit`, `--quit-scope previous\|all\|none`, `--keep-running <bundleId>` (repeat) | No | Dock when not dry-run | 0 / 3–8 | `apply` | `status`, `profile`, `snapshotID`, `switchOutcome`, preview fields on dry-run |
| `save` | `<name>`; `--force`, `--include-prefs` | No | Store; sets active profile | 0 / 2 / 4 / 6 / 7 | `save` | `profile` |
| `delete` | `<profile>`; requires **`--yes`** | No | Store | 0 / 2 / 3 | `delete` | `profile` (removed) |
| `rename` | `<profile> <new-name>` | No | Store | 0 / 3 / 6 | `rename` | `profile` |
| `duplicate` | `<profile> <new-name>` | No | Store | 0 / 3 / 6 | `duplicate` | `profile` |
| `undo` | | No | Dock + snapshot bookkeeping | 0 / 3 / 7 / 8 | `undo` | `snapshotID`, `restarted`, `source` |
| `snapshots` / `history` | list (default) | No | None | 0 | `snapshots` | `snapshots[]`, `unreadable[]` |
| `snapshots pin` / `unpin` | `<uuid>` | No | Store metadata | 0 / 3 | `snapshots` | (often empty) |
| `snapshots delete` | `<uuid>`; **`--yes`** | No | Store | 0 / 2 / 3 | `snapshots` | |
| `snapshots restore` / `restore` | `<uuid>`; **`--yes`** | No | Dock | 0 / 2 / 3 / 7 / 8 | `restore` | `snapshotID`, `restarted`, `source` |
| `export` | `<profile>`; `--format json\|script`, `--output <file>`, `--force` | No | File if `--output` | 0 / 3 / 6 | `export` | `document` or `format`+`path` |
| `import` | `<file\|->`; `--name <name>` | No | Store | 0 / 2 / 6 | `import` | `profile`, `changes[]` |
| `status` | | No | None | 0 | `status` | `appRunning`, `bundleId`, `lock`, `preview`, `activeProfile`, `dockMatchesActive`, `externalControl`, `supportDir`, `version` |
| `doctor` | | No | None | 0* | `doctor` | `checks[]` (`name`, `status`, `detail`) |
| `version` | | No | None | 0 | `version` | `version` |
| `completions` | `zsh` \| `bash` \| `fish` | No | None | 0 / 2 | — | Human script only; **`--json` → exit 2** |

\* **`doctor`**: process exit code stays **0** even when checks fail; read `ok` and `checks[].status` (`pass` \| `warn` \| `fail`).

### Profile addressing

- **UUID** (canonical string): lookup by id only; miss → exit **3**.
- **Name**: case-insensitive; one match → ok; zero → **3**; two+ → **4** with `error.matches`: `[{ "id", "name" }]`.

### `apply` details

- **`--quit-scope`**: overrides quit scope for this invocation only (`previous` → `previousProfileApps`, `all` → `allNotInProfile`, `none` → `none`); stored profile unchanged.
- **`--keep-running`**: bundle IDs kept running (case-insensitive); still requires **`--allow-quit` and `--yes`** if any other app would quit.
- **Idempotent**: matching Dock with nothing to quit/skip → `result.status`: **`noChanges`**, exit **0**.
- **Would quit without both flags** → exit **5**, Dock unchanged (even if tiles already match).
- **Would skip apps without `--yes`** → exit **5**.
- **`--dry-run`**: exit **0** when preview computed; `result.status`: **`dryRun`**; includes `confirmationRequired`, `willQuit`, `skipped`; no snapshot.

`result.status` on real apply: `applied`, `noChanges`, `appsOnly`, or `cancelled` (app/Intent paths; CLI uses headless confirm).

`switchOutcome` in JSON includes `summary` and `wasCancelled` only (not per-app quit/launch arrays).

### `show` JSON

`result.profileDocument` is the **base64** encoding of the profile’s UTF-8 JSON document (same shape as on disk: `id`, `name`, `schemaVersion`, `apps`, `others`, `prefs`, `switching`, `hotkey`). Decode base64, then parse JSON. Human mode prints that JSON directly (not wrapped in the envelope’s inner object).

### `save`

- New name: captures current Dock tiles; optional **`--include-prefs`** (refused while a Dock prefs preview lock is active — exit **7**).
- Without **`--force`**, existing name → exit **6**, `error.reason`: **`nameInUse`**.
- With **`--force`**, exactly one same-named profile: replace `apps`/`others`, keep id, hotkey, switching, prefs; zero matches creates; 2+ names → exit **4**.

### `import`

- Local file or **`-`** on stdin (not a TTY). No `http:`/`https:`.
- Never applies; never overwrites; sanitizes document (see `result.changes[].kind`).
- Name collision → exit **6** unless **`--name`** is free.

### Envelope shape

Success:

```json
{
  "schemaVersion": 1,
  "command": "list",
  "ok": true,
  "result": { }
}
```

Failure (example: confirmation):

```json
{
  "schemaVersion": 1,
  "command": "apply",
  "ok": false,
  "result": {
    "confirmationRequired": true,
    "willQuit": [{ "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap" }]
  },
  "error": {
    "code": "needsConfirmation",
    "exitCode": 5,
    "message": "…",
    "reason": "quit",
    "quitApps": [{ "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap" }],
    "launchApps": [],
    "skippedApps": []
  }
}
```

`error` always includes `code`, `exitCode`, and `message`. Optional: `reason`, `matches`, `snapshotID`, `quitApps`, `launchApps`, `skippedApps`.

Dates in snapshot lists: ISO-8601 UTC with fractional seconds. UUIDs in JSON use uppercase strings.

## Exit codes

| Exit | `error.code` | Agent guidance |
|---|---|---|
| 0 | — (`ok: true`) | Success, including `noChanges`. For `doctor`, also inspect `checks` even when exit is 0. |
| 1 | `internal` | Unexpected failure; report message; do not retry blindly. |
| 2 | `usage` | Fix argv; includes unknown command, bad flags, `delete`/`restore`/`snapshots delete` without `--yes`, TTY stdin import, relative `OHMYDOCK_SUPPORT_DIR`, `completions --json`. |
| 3 | `notFound` or `nothingToUndo` | Missing profile/snapshot or nothing to undo; do not retry same args. |
| 4 | `ambiguous` | Ask user which profile id/name; or use UUID. |
| 5 | `needsConfirmation` | **Do not** add `--allow-quit` unless the user agreed to quit listed apps. Use dry-run payload; for skips only, retry with `--yes` (and `--quit-scope none` if appropriate). |
| 6 | `conflict` | `error.reason`: `nameInUse`, `dockChanged`, `wouldEmptySection`, `unsatisfiable`, `invalidProfile`, `exportRefused`, etc. Fix input or refresh `current` / dry-run. |
| 7 | `locked` | `error.reason`: `operationLock` or `previewActive`. Wait, then retry; preview message: revert or keep Dock prefs preview first. |
| 8 | `rolledBack` / `rollbackFailed` | Apply failed; rolled back or rollback failed. On `rollbackFailed`, stop and report `error.snapshotID`. |
| 130 | — | Interrupted (`SIGINT`); apply may roll back first. |

ArgumentParser validation is mapped to exit **2**, not 64. `--help` / `--version` → **0**.

## URL scheme (`ohmydock://`)

Handled **only** by the menu-bar app (confirmation sheets, consent). Grammar: `ohmydock://<command>?query` — command is the **host**; no path.

| URL | Behavior |
|---|---|
| `ohmydock://apply?profile=<name-or-uuid>` | Resolve profile; **sheet** before Dock write or quits; cannot pass quit bypass query params |
| `ohmydock://save?name=<name>` | Confirm save; existing name prompts overwrite (same semantics as `save --force`); omit `name` to open naming UI |
| `ohmydock://undo` | Sheet: restore previous Dock; quit apps not reopened |
| `ohmydock://open?window=editor\|history\|settings` | Opens window; **always allowed** |
| `ohmydock://import?url=…` | **Not implemented** (no fetch); reserved |

Forbidden query keys on mutating routes: `allowQuit`, `yes`, `force`, `quit` → entire URL rejected.

**External control** (`UserDefaults`, app domain `io.github.farzin-firoozi.OhMyDock`, key `externalControl`):

- **`ask`** (default when unset): first mutating URL shows Allow / Don't Allow.
- **`allowed`**: mutating URLs proceed to normal confirmation sheets.
- **`denied`**: mutating URLs blocked; `open` still works.

CLI and Shortcuts are **not** gated by this setting.

Optional **x-callback-url**: `x-success`, `x-error` (must be safe custom schemes; illegal callback rejects URL before any write). Success appends `profile`, `profileID`, `status`; failure appends `errorCode`, `errorMessage`.

Dedupe: identical mutating URL within **1s** dropped; rate limit **2s** between mutating URLs per app launch.

## Shortcuts / App Intents

Available in the Shortcuts app (system image `dock.rectangle`):

| Intent | Parameters | Confirmation |
|---|---|---|
| **Apply Profile** | Profile picker (`ProfileEntity` id) | Sheet when `confirmationRequired` (same as menu hotkey rule) |
| **Save Current Dock** | `name`, `overwrite` (default false) | Sheet when overwriting existing name |
| **List Profiles** | none | None; returns profile list + dialog count |
| **Undo Last Change** | none | Always confirms; `nothingToUndo` → failed dialog |

Siri phrases (examples): “Apply \<profile\> Dock profile with oh-my-dock”, “Save my Dock as a profile…”, “Undo my last Dock change…”. List has no Siri phrase.

Preview-active and lock-busy return failed dialogs with the same messages as the CLI. Snapshot `source` tags: `cli`, `url`, `intent`, `menu`, `hotkey`.

## Environment variables

| Variable | Effect |
|---|---|
| `OHMYDOCK_SUPPORT_DIR` | Absolute path to support root (required absolute; relative → exit **2**) |
| `OHMYDOCK_LOCK_TIMEOUT` | Default lock timeout seconds if `--lock-timeout` omitted |
| `NO_COLOR` | Disables human ANSI color |

Test-only (not for agents): `OHMYDOCK_DOCK_PLIST` — absolute path to a **file** plist; refused if it resolves to the live Dock plist.

## Paste into your `AGENTS.md` / `CLAUDE.md`

```markdown
## oh-my-dock

Use the `ohmydock` CLI with `--json --non-interactive`. Treat stdout as one JSON document (`schemaVersion` 1); the exit code is the contract (0 success, 2 usage, 3 not found, 4 ambiguous name, 5 needs confirmation, 6 conflict, 7 busy, 8 rolled back, 1 internal). Dry-run `ohmydock apply <profile> --dry-run --json` before applying. Never pass `--allow-quit` unless the user has agreed to quit the apps listed in `willQuit`. `--yes` alone does not permit quits. Do not write `~/Library/Preferences/com.apple.dock.plist` yourself and do not `killall Dock`.
```

## Examples

```sh
ohmydock --json --non-interactive list
ohmydock --json --non-interactive current
ohmydock --json --non-interactive apply Work --dry-run
ohmydock --json --non-interactive apply Work --yes
ohmydock --json --non-interactive apply Work --quit-scope none --yes
ohmydock --json --non-interactive save "Client call"
ohmydock --json --non-interactive import ./work.json
ohmydock --json --non-interactive undo
```

When exit **5**, inspect `error.quitApps` / `result.willQuit` and ask the user before adding `--allow-quit`.

## Future MCP wrapper (NOT implemented)

A thin MCP server could expose tools that shell `ohmydock --json --non-interactive` and map exit codes 1:1. Proposed tools (names only — **not shipped**):

| Tool | Maps to | Parameters |
|---|---|---|
| `list` | `list` | (none) |
| `show` | `show` | `profile` |
| `current` | `current` | (none) |
| `apply` | `apply` | `profile`, `dryRun`, `allowQuit` (default **false**), `yes` (default **false**), `quitScope`, `keepRunning[]` |
| `save` | `save` | `name`, `force`, `includePrefs` |
| `delete` | `delete` | `profile`, `yes` |
| `rename` | `rename` | `profile`, `newName` |
| `duplicate` | `duplicate` | `profile`, `newName` |
| `undo` | `undo` | (none) |
| `snapshots` | `snapshots` | (none) |
| `restore` | `restore` | `id`, `yes` |
| `export` | `export` | `profile`, `format`, `output`, `force` |
| `import` | `import` | `path`, `name` |
| `status` | `status` | (none) |
| `doctor` | `doctor` | (none) |

No MCP tools for `completions`, `version`, or `OHMYDOCK_DOCK_PLIST`. **`allowQuit` must default false.** Gallery fetch would correspond to future `ohmydock://import?url=` — out of scope for v0.3.

## Further reading

- Normative spec: [external-control-design.md](external-control-design.md)
- Man page (shipped): `OhMyDock.app/Contents/Resources/ohmydock.1`
