# Execution plan: phases, tasks, model routing

Breaks [implementation-plan.md](implementation-plan.md) into phases and tasks. Each task is routed to a provider and model based on difficulty. Three providers are used: **Claude**, **Cursor** (including xAI Grok and Cursor Composer models), and **Antigravity**. Tasks are dispatched via T3 `delegate_task`.

## Model tiers

| Tier | Use for | Models |
|---|---|---|
| **Low** | Boilerplate, config, scripts with clear specs, docs, mechanical edits | Antigravity `gemini-3.8-flash-low` / `-medium` · Cursor `composer-2.5` · Claude `haiku-5-5` |
| **Standard** | Typical feature work: SwiftUI views, models, stores, Apple API wrappers + tests, spikes | Claude `sonnet-5-5` · Cursor `gpt-5.6-terra` · Cursor `composer-2.5` · Cursor `grok-4.7` (high) · Antigravity `gemini-3.8-flash-high` |
| **High** | Algorithms, concurrency, rollback/safety paths, security-sensitive code, architecture, reviews | Claude `opus-5-5` · Cursor `gpt-5.6-sol` (xhigh) · Cursor `grok-4.7` (xhigh) |

Short names used below: **Haiku**, **Sonnet**, **Opus** (Claude) · **Composer**, **Terra**, **Sol**, **Grok** (Cursor) · **Flash-L / Flash-M / Flash-H** (Antigravity).

## Process rules

- **No Claude reviewers.** Reviews and verification never use Claude models. Primary reviewer is **Sol** (GPT-5.6); when Sol wrote the task, **Grok** is primary. A writer never approves its own work.
- **Extra review lanes.** Every phase review (X.R) also gets an independent second opinion from **Grok** (all tasks) and a fast checklist pass from **Composer** (scripts, config, docs). Neither reviews tasks written by its own model; Composer skips Composer-authored tasks.
- **Research and debugging lane.** Grok takes open-ended research, spike follow-ups, and second-pass root-cause analysis when a fix stalls (different family from the author).
- **Fix-up lane.** Composer applies low-risk, mechanical review fixes (docs, scripts, config, renames); anything touching safety paths goes back to the original author tier.
- **Code authoring.** All code tasks are written by Sonnet (or the Cursor/Antigravity model listed), never Opus. Opus is used for architecture design only. Bold rows mark safety-critical code that gets the strictest review.
- **Verification** pass per phase: **Terra** (GPT-5.6) runs the build, tests, and acceptance checks.
- **Safety gate.** No agent touches the **live Dock** or quits real apps except in tasks marked 🔴, which need user confirmation first.
- **Parallel groups.** Tasks in the same group (A, B…) run at the same time, in **separate worktrees** when they touch overlapping files. Groups run in order.
- **Phase exit:** all tasks done, `swift test` + `xcodebuild build` green, review findings fixed, verifier passed.
- **Fallback.** If a provider is unavailable, use the same-tier model from another provider.

## Phase 0: Foundations (M0)

| # | Task | Model | Group |
|---|---|---|---|
| 0.1 | `project.yml` (XcodeGen), `OhMyDockCore` SwiftPM package + tests, empty `MenuBarExtra` app (`LSUIElement`, SF Symbol `dock.rectangle`) | Sonnet | A |
| 0.2 | `scripts/build-dockutil.sh`: dockutil v3 from a pinned tag → `App/Resources/Helpers/`, ad-hoc sign; Apache-2.0 LICENSE/NOTICE | Flash-M | A |
| 0.3 | ~~GitHub Actions CI~~ dropped (no Xcode 27 on hosted runners); replaced by a local pre-push hook running `make test` | Composer | A |
| 0.4 | Spike: dockutil on a **temp plist copy** (read-only on the live Dock) | Terra | B |
| 0.5 | Spike: `dockutil --list` format for apps/URLs/folders/spacers (read-only) | Flash-H | B |
| 0.6 | 🔴 Spike: `NSRunningApplication.terminate()` permission. Test only on a TextEdit instance the spike launched | Sonnet | B |
| 0.7 | Write spike findings into `technical-notes.md` | Haiku | C |
| 0.R | Review: Opus (0.2–0.5), Sol (0.1, 0.6) · Verify: Sonnet | Opus + Sol + Grok + Composer (done before the no-Claude rule) | D |

**Exit:** app runs in the menu bar, `make test` + `make build` green locally, bundled dockutil runs from the app bundle, spike answers documented.

## Phase 1: Core engine (M1, logic)

| # | Task | Model | Group |
|---|---|---|---|
| 1.1 | Models: `Profile`, `DockItem`, `AppRef`, `DockPrefs` (Codable, `schemaVersion`) + tests | Sonnet | A |
| 1.2 | `ProfileStore`: JSON in Application Support, atomic writes, migration hook + tests | Composer | B |
| 1.3 | `DockBackend` protocol + `FakeDockBackend` | Flash-H | B |
| 1.4 | Read current Dock via CFPreferences/PropertyListSerialization → `[DockItem]`, resolve bundleId (bare-path and `file://` forms, optional bundle ID — spike 0.5) | Grok | B |
| 1.5 | **`DiffEngine`**: minimal add/remove/move ops; heavy tests (duplicates, spacers, missing apps) | **Sonnet** | C |
| 1.6 | `DockutilBackend.execute(ops)` `--no-restart` + `DockRestarter`; verify by re-reading after write, never trust exit codes (temp-plist integration tests) | Sonnet | C |
| 1.7 | **`SnapshotStore`**: backup before apply, keep last N, restore | **Sol** | C |
| 1.8 | **`ProfileApplier` actor**: snapshot → diff → execute → restart, rollback, cancel in-flight | **Sonnet** | D |
| 1.9 | First-launch Default profile capture | Flash-H | D |
| 1.R | Review: Sol (all except 1.7), Grok (all except 1.4; primary for 1.7). Focus: rollback + concurrency · Verify: Terra | Sol + Grok + Composer | E |

**Exit:** `swift test` covers models, diff, store, snapshot, and applier (fake backend); integration tests pass on a temp plist.

## Phase 2: v0.1 UI (M1, app)

| # | Task | Model | Group |
|---|---|---|---|
| 2.1 | Menu bar: profile list + active check, Save current as…, Undo, Open editor | Sonnet | A |
| 2.2 | Editor window: profile sidebar (CRUD) + Dock strip with drag-reorder | Sonnet | A |
| 2.3 | Add-item flows: app picker + Finder drag, URL, folder options, spacers | Composer | B |
| 2.4 | Diff preview sheet | Flash-H | B |
| 2.5 | History window: snapshots + restore | Terra | B |
| 2.6 | Global hotkeys (KeyboardShortcuts) + launch at login (`SMAppService`) | Composer | B |
| 2.7 ✅ | 🔴 Manual QA on the live Dock with the user: save → 2 profiles → switch → undo (passed) | Sonnet | C |
| 2.R | Review: Sol (all), Grok (second opinion) · Verify: Terra. Two Grok rounds + Composer verification done; the last fix round (77199e1, 90fd93e) was not re-reviewed, by decision | Sol + Grok + Composer | D |

## Phase 3: Release pipeline (parallel with Phase 2)

No Apple Developer account and none planned, so releases are **ad-hoc signed and not notarized**. Users get past Gatekeeper with right-click → Open or `xattr -cr`. Developer ID signing and notarization are deferred until an account exists.

| # | Task | Model | Group |
|---|---|---|---|
| 3.1 | `scripts/release.sh`: archive, ad-hoc sign (helper first, then app: inside-out), zip/DMG, sha256. No notarization | Sonnet | A |
| 3.2 | Updates: decide between Sparkle (free EdDSA key, appcast on GitHub Pages) and a "new version available" check against GitHub Releases; verify Sparkle works with ad-hoc signing before committing | Grok | A |
| 3.3 | `homebrew-tap` cask (own tap, `postflight` clears quarantine) + GitHub Action bumping version/sha256 | Composer | B |
| 3.4 | README (install incl. Gatekeeper workaround, usage) | Haiku | B |
| 3.5 | 🔴 **Release gate:** test quit/launch (`terminate()`, `openApplication`) on macOS 14, 15, and current with the ad-hoc signed release build on a clean TCC state (spike 0.6 only covered macOS 27) | Sonnet | C |
| 3.6 | **Release gate:** verify the dockutil license/NOTICE and KeyboardShortcuts license ship in `Contents/Resources`; verify helper and app signatures with `codesign --verify --deep --strict` (ad-hoc) | Flash-M | C |
| 3.R | Review of the release/update path: Sol + Grok · Verify: Terra | Sol + Grok + Composer | D |

**Release gates (mandatory, block any release):** 3.5 and 3.6 pass. No release ships quit/launch without 3.5.

**Needs from user:** GitHub org/username, bundle ID (decided: `io.github.farzin-firoozi.OhMyDock`; GitHub user `Farzin-Firoozi`).

**Deferred (needs a paid account):** Developer ID signing, notarization, stapling, notarized-build gate test. "Launch at login" may fail to register with ad-hoc signing; test it and keep a fallback.

## Phase 4: v0.2 (M2)

| # | Task | Model | Group |
|---|---|---|---|
| 4.1 | `DockPrefsWriter` (CFPreferences), all §3 keys + tests | Composer | A |
| 4.3 | **`AppSwitcher`**: quit/keep/launch sets, never-quit list, `.regular` only, graceful terminate + timeout, stragglers reported, force quit only on explicit user action, queued/cancelled switches. Tests/QA: save sheet, quit veto / `.terminateLater` deferral, sandboxed third-party app, `terminate() == false`; verify `forceTerminate()` behavior separately before shipping force quit | **Sonnet** | A |
| 4.5 | `DockutilScriptExporter` + JSON import/export with strict schema validation | Grok | A |
| 4.2 | Prefs panel: live preview, revert, reset, per-profile | Sonnet | B |
| 4.4 | Confirmation sheet (no permission flow needed in the tested scope — spike 0.6; release gate 3.5 still applies) | Flash-H | B |
| 4.M | MacBook mockup editor canvas: vector MacBook (model auto-detected from `hw.model`, color picker since macOS does not expose color), real desktop wallpaper, menu bar, interactive Dock at the bottom that follows DockPrefs. No network, no Apple images | Sonnet | B |
| 4.F | Phase 4 fix round: Reset removes keys instead of guessed defaults; block apply/undo/restore during a prefs preview; revert preview on quit; AppKit quit/launch on the main thread | Sonnet | B |
| 4.R | Review: Sol (all; focus data loss in 4.3), Grok (all except 4.5; second opinion) · Verify: Terra | Sol + Grok + Composer | C |

**Phase 4 status: done.** 4.R ran as Grok review → Sonnet/Composer fixes (shared confirmation model, preview active from first write, floating hotkey failures, editor layout-loop crash) → Composer verification, then manual QA on the live Dock (prefs preview/revert, app switching with Keep running, undo) passed. Known gap: the mockup wallpaper uses `NSWorkspace.desktopImageURL`, which returns a stand-in image for aerial and many modern wallpapers; reading `com.apple.wallpaper/Store/Index.plist` is deferred.

## Phase 5: v0.3 (M3)

**Scope:** external control only. The spec is [external-control-design.md](external-control-design.md). Automatic triggers stay postponed and are not tasks: trigger engine, display, schedule, frontmost app, Wi-Fi, and Focus Filter (`SetFocusFilterIntent`).

**Models for this phase only:** build tasks are **composer-2.5**. Review and verify are **grok-4.7**. The tier table and the Sol/Terra review rule do not apply here. The model-mix totals at the bottom of this file are not updated for these rows.

**Done when:** `make test` and `make build` are green, `verify-release` passes on the built app, and the CLI, URL scheme, and App Intents match the design. No live Dock and no `killall Dock`.

Groups run in order. Tasks in one group can run in parallel in separate worktrees; their files do not overlap. Acceptance and tests below are the dispatch contract; the design doc is the behavior contract.

| # | Task | Model | Group | Depends | Status |
|---|---|---|---|---|---|
| 5.A | Core `ExternalCommand` layer, `fcntl` locks, snapshot `source` tag, app gate/watcher | composer-2.5 | A | — | **Done** — known gaps for 5.R: editor conflict banner not implemented; prefs preview may hold only in-memory flag (not `preview.lock` for whole session); `DockOperationGate.runExclusiveMutation` may hold file lock across confirmation UI; some `doctor`/`status`/`export` JSON thinner than design §3; `show` JSON uses `profileDocument` (base64) not `result.profile`; no dedicated `StoreChangeWatcher` unit test |
| 5.B | `ohmydock://` URL scheme, consent setting, x-callback-url | composer-2.5 | B | 5.A | **Done** |
| 5.C | `ohmydock` CLI (swift-argument-parser), headless, embedded in the app | composer-2.5 | B | 5.A | **Done** |
| 5.D | App Intents: apply, save, list, undo | composer-2.5 | C | 5.A, 5.B | **Done** |
| 5.E | Packaging: sign, verify-release, cask `binary` / man page, completions | composer-2.5 | C | 5.C | **Done** |
| 5.F | Docs: `docs/agents.md` and the pointers the design lists | composer-2.5 | D | 5.A–5.E | **Done** |
| 5.R | Review all of 5.A–5.F and run `make test`, `make build`, `verify-release` | grok-4.7 | E | 5.A–5.F | Pending |

### 5.A — Command center, locks, source

**Files:** `Packages/OhMyDockCore/Sources/OhMyDockCore/External/`; `Snapshot` / `SnapshotStore.save` and `restore`; `ProfileApplier.apply` (`controlSource`); move `ActiveProfileRecord`, `SpentUndoRecord`, and `SnapshotUndoService` into the package. App: `DockOperationGate` takes `operation.lock`; prefs preview holds `preview.lock`; `StoreChangeWatcher`; menu bar passes `.menu` / `.hotkey`; editor reload-or-conflict when a profile file changes.

**Acceptance:** Fakes cover the command and exit tables in the design (§3, §4), including quit requiring both `--allow-quit` and `--yes`, idempotent `noChanges`, `--quit-scope` not persisted, preview-lock exit 7, lock timeout 0, source tag on new snapshots, old snapshots still decoding, URL vs intent confirmation policy, and `OHMYDOCK_DOCK_PLIST` refused when it is the live plist. `fcntl` releases when the holder dies.

**Tests:** `OhMyDockCoreTests/External/` and app unit tests for the gate, watcher, and policy. No live Dock.

### 5.B — URL scheme

**Files:** `App/Info.plist`, `App/URL/`, `App/OhMyDockApp.swift`, `AppDelegate.swift`, Settings toggle for `externalControl`. Not `project.yml` or `CLI/`.

**Acceptance:** Routes in design §5. `import?url=` does not fetch. Forbidden quit query names and an `https` callback write nothing. Duplicate URL within 1s does not apply twice. Denied setting blocks mutating URLs and still allows `open`. First-use consent defaults to Allow. Quit URLs show the sheet before any quit. Snapshot source `url`.

**Tests:** Router tests with a fake command center and a fake URL opener. No app launch.

### 5.C — CLI

**Files:** `CLI/`, `project.yml` (tool target, `swift-argument-parser` from 1.5.0, embed into `Contents/Helpers/ohmydock`), `Makefile` `cli` target. Behavior stays in 5.A; this task is the shell.

**Acceptance:** Every §3 command. Global flags before or after the subcommand. Usage exits 2, not 64. `--json` / `--quiet` rules. Debug app build contains `Contents/Helpers/ohmydock`. `scripts/cli-smoke.sh` uses a temp support dir and a temp plist file, asserts `schemaVersion`, and fails if the live Dock plist mtime changes.

**Tests:** smoke script. No live Dock, no `killall`, no app launch.

### 5.D — App Intents

**Files:** `App/Intents/` only (`ApplyProfileIntent`, `SaveCurrentDockIntent`, `ListProfilesIntent`, `UndoLastChangeIntent`, `ProfileEntity`, `OhMyDockShortcuts`).

**Acceptance:** Design §6. Apply takes a profile entity id. Undo confirms first. Preview-active fails the dialog without writing. Snapshot source `intent`. No Focus Filter intent.

**Tests:** `perform()` against a fake center in `OhMyDockTests`. No app launch.

### 5.E — Packaging

**Files:** `scripts/release.sh`, `scripts/verify-release.sh`, `scripts/test-verify-release.sh`, `CLI/ohmydock.1`, `ThirdParty/swift-argument-parser/LICENSE`, `THIRD_PARTY_NOTICES.md`, `packaging/homebrew-tap/Casks/oh-my-dock.rb`, `packaging/homebrew-tap/test-cask.sh`, `OhMyDockCore.version`.

**Acceptance:** Sign `dockutil`, then `ohmydock`, then the app (`--options runtime`). `verify-release.sh` stays 7 checks and covers the CLI, the MIT license, and the `ohmydock` URL scheme. Cask `binary` points at `Contents/Helpers/ohmydock` and `manpage` at `OhMyDock.app/Contents/Resources/ohmydock.1`. `zsh -n` accepts `ohmydock completions zsh`.

**Tests:** `test-verify-release.sh`, `test-cask.sh`. Do not install the cask onto the live Dock.

### 5.F — Docs

**Files:** `docs/agents.md` (design §8, including the paste-in snippet and the future MCP tool list), plus the index and pointer edits listed in the design (README, distribution, features, technical-notes, implementation-plan M3). No code.

**Acceptance:** An agent can follow `docs/agents.md` without reading the design, and the doc tells them never to pass `--allow-quit` unless the user agreed.

### 5.R — Review and verify

**Model:** grok-4.7 reviews 5.A–5.F (quit flags, URL rejection, lock order, preview lock, import not fetching, live-plist refusal), then runs `make test`, `make build`, and `verify-release` on the built app. No live Dock and no `killall Dock`.

## Phase 6: v0.4+ (M4)

| # | Task | Model | Group |
|---|---|---|---|
| 6.1 | `AppResolver`: missing apps + brew cask mapping (Homebrew API, cached) | Terra | A |
| 6.2 | Usage tracking (opt-in) + auto-ordering + suggestions | Flash-H | A |
| 6.3 | iCloud sync: architecture (Opus) → build (Sonnet) | **Opus** → Sonnet | A |
| 6.4 | MDM script output, `--allhomes` | Flash-M | A |
| 6.5 | Invisible mode, regular-app toggle | Composer | A |
| 6.9 | Research: lock Dock to one display | Grok | A |
| 6.6 | **Gallery import safety**: schema hardening + rules from profile-gallery.md | **Sonnet** | B |
| 6.7 | Gallery repo: CI validation, `index.json` on Pages | Composer | B |
| 6.8 | Gallery tab UI + `ohmydock://import` | Sonnet | C |
| 6.R | Security review (gallery = untrusted input): Sol + Grok · Verify: Terra | Sol + Grok + Composer | D |

## Model mix

| Provider | Models | Build tasks | Role |
|---|---|---|---|
| Claude | Opus · Sonnet · Haiku | 1 (6.3 design only) · 17 · 2 | Safety-critical engine, SwiftUI, QA (no review or verification role) |
| Cursor | Sol · Terra · Composer · Grok | 2 · 4 · 9 · 4 | Second high-tier author, standard features, reviewer of Claude code. Grok: parsing/validation/trigger logic, research, debugging, second-opinion reviewer. Composer: scaffolding, integrations, CLI, fix-up lane, checklist reviewer |
| Antigravity | Flash-H · Flash-M · Flash-L | 7 · 3 · 2 | Low and standard tasks, protocols, small features, scripts |
