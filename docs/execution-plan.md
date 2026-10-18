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

- **Cross-family review.** The reviewer is always from a **different model family** than the author: Claude-written code is reviewed by Sol, and Cursor/Antigravity-written code is reviewed by Opus. A writer never approves its own work.
- **Extra review lanes.** Every phase review (X.R) also gets an independent second opinion from **Grok** (all tasks) and a fast checklist pass from **Composer** (scripts, config, docs). Neither reviews tasks written by its own model; Composer skips Composer-authored tasks.
- **Research and debugging lane.** Grok takes open-ended research, spike follow-ups, and second-pass root-cause analysis when a fix stalls (different family from the author).
- **Fix-up lane.** Composer applies low-risk, mechanical review fixes (docs, scripts, config, renames); anything touching safety paths goes back to the original author tier.
- **Verification** pass per phase: Sonnet runs the build, tests, and acceptance checks.
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
| 0.R | Review: Opus (0.2–0.5), Sol (0.1, 0.6) · Verify: Sonnet | Opus + Sol + Grok + Composer | D |

**Exit:** app runs in the menu bar, `make test` + `make build` green locally, bundled dockutil runs from the app bundle, spike answers documented.

## Phase 1: Core engine (M1, logic)

| # | Task | Model | Group |
|---|---|---|---|
| 1.1 | Models: `Profile`, `DockItem`, `AppRef`, `DockPrefs` (Codable, `schemaVersion`) + tests | Sonnet | A |
| 1.2 | `ProfileStore`: JSON in Application Support, atomic writes, migration hook + tests | Composer | B |
| 1.3 | `DockBackend` protocol + `FakeDockBackend` | Flash-H | B |
| 1.4 | Read current Dock via CFPreferences/PropertyListSerialization → `[DockItem]`, resolve bundleId (bare-path and `file://` forms, optional bundle ID — spike 0.5) | Grok | B |
| 1.5 | **`DiffEngine`**: minimal add/remove/move ops; heavy tests (duplicates, spacers, missing apps) | **Opus** | C |
| 1.6 | `DockutilBackend.execute(ops)` `--no-restart` + `DockRestarter`; verify by re-reading after write, never trust exit codes (temp-plist integration tests) | Sonnet | C |
| 1.7 | **`SnapshotStore`**: backup before apply, keep last N, restore | **Sol** | C |
| 1.8 | **`ProfileApplier` actor**: snapshot → diff → execute → restart, rollback, cancel in-flight | **Opus** | D |
| 1.9 | First-launch Default profile capture | Flash-H | D |
| 1.R | Review: Sol (1.1, 1.5, 1.6, 1.8), Opus (1.2–1.4, 1.7, 1.9). Focus: rollback + concurrency · Verify: Sonnet | Opus + Sol + Grok + Composer | E |

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
| 2.7 | 🔴 Manual QA on the live Dock with the user: save → 2 profiles → switch → undo | Sonnet | C |
| 2.R | Review: Sol (2.1, 2.2), Opus (2.3–2.6) · Verify: Sonnet | Opus + Sol + Grok + Composer | D |

## Phase 3: Release pipeline (parallel with Phase 2)

| # | Task | Model | Group |
|---|---|---|---|
| 3.1 | `scripts/release.sh`: archive, Developer ID sign (helper first with `--timestamp` + hardened runtime, then app: inside-out), notarize, staple, zip | Sonnet | A |
| 3.2 | Sparkle integration + appcast generation | Terra | A |
| 3.3 | `homebrew-tap` cask + GitHub Action bumping version/sha256 | Composer | B |
| 3.4 | README (install, usage) | Haiku | B |
| 3.5 | 🔴 **Release gate:** test quit/launch (`terminate()`, `openApplication`) on macOS 14, 15, and current with the notarized Developer ID build on a clean TCC state (spike 0.6 only covered macOS 27, ad-hoc) | Sonnet | C |
| 3.6 | **Release gate:** verify the dockutil license/NOTICE ships in `Contents/Resources`; verify helper signature (Developer ID, `--timestamp`, hardened runtime) with `codesign --verify --deep --strict` | Flash-M | C |
| 3.R | Security review of the signing/update path: Opus + Sol · Verify: Sonnet | Opus + Sol + Grok + Composer | D |

**Release gates (mandatory, block any release):** 3.5 and 3.6 pass. No release ships quit/launch without 3.5.

**Needs from user:** Apple Developer account, GitHub org/username, bundle ID.

## Phase 4: v0.2 (M2)

| # | Task | Model | Group |
|---|---|---|---|
| 4.1 | `DockPrefsWriter` (CFPreferences), all §3 keys + tests | Composer | A |
| 4.3 | **`AppSwitcher`**: quit/keep/launch sets, never-quit list, `.regular` only, graceful terminate + timeout, stragglers reported, force quit only on explicit user action, queued/cancelled switches. Tests/QA: save sheet, quit veto / `.terminateLater` deferral, sandboxed third-party app, `terminate() == false`; verify `forceTerminate()` behavior separately before shipping force quit | **Opus** | A |
| 4.5 | `DockutilScriptExporter` + JSON import/export with strict schema validation | Grok | A |
| 4.2 | Prefs panel: live preview, revert, reset, per-profile | Sonnet | B |
| 4.4 | Confirmation sheet (no permission flow needed in the tested scope — spike 0.6; release gate 3.5 still applies) | Flash-H | B |
| 4.R | Review: Sol (4.2, 4.3; focus data loss), Opus (4.1, 4.4, 4.5) · Verify: Sonnet | Opus + Sol + Grok + Composer | C |

## Phase 5: v0.3 (M3)

| # | Task | Model | Group |
|---|---|---|---|
| 5.1 | **`TriggerEngine`**: rules, debounce, priority, "no quit from automatic triggers" | **Sol** | A |
| 5.2 | Triggers: display, schedule, frontmost app (throttled) | Grok | B |
| 5.3 | Focus Filter (`SetFocusFilterIntent`) + App Intents (apply/save/list) | Sonnet | B |
| 5.4 | Wi-Fi trigger (CoreWLAN + Location permission flow) | Flash-H | B |
| 5.5 | URL scheme `ohmydock://` | Flash-L | B |
| 5.6 | `ohmydock` CLI (swift-argument-parser) + app handoff | Composer | B |
| 5.7 | Cask `binary` stanza for the CLI | Flash-L | C |
| 5.R | Review: Opus (5.1, 5.2, 5.4–5.7), Sol (5.3) · Verify: Sonnet | Opus + Sol + Grok + Composer | D |

## Phase 6: v0.4+ (M4)

| # | Task | Model | Group |
|---|---|---|---|
| 6.1 | `AppResolver`: missing apps + brew cask mapping (Homebrew API, cached) | Terra | A |
| 6.2 | Usage tracking (opt-in) + auto-ordering + suggestions | Flash-H | A |
| 6.3 | iCloud sync: architecture (Opus) → build (Sonnet) | **Opus** → Sonnet | A |
| 6.4 | MDM script output, `--allhomes` | Flash-M | A |
| 6.5 | Invisible mode, regular-app toggle | Composer | A |
| 6.9 | Research: lock Dock to one display | Grok | A |
| 6.6 | **Gallery import safety**: schema hardening + rules from profile-gallery.md | **Opus** | B |
| 6.7 | Gallery repo: CI validation, `index.json` on Pages | Composer | B |
| 6.8 | Gallery tab UI + `ohmydock://import` | Sonnet | C |
| 6.R | Security review (gallery = untrusted input): Opus + Sol · Verify: Sonnet | Opus + Sol + Grok + Composer | D |

## Model mix

| Provider | Models | Build tasks | Role |
|---|---|---|---|
| Claude | Opus · Sonnet · Haiku | 5 · 13 · 2 (6.3 counted in both Opus and Sonnet) | Safety-critical engine, SwiftUI, QA, verifier, reviewer of non-Claude code |
| Cursor | Sol · Terra · Composer · Grok | 2 · 4 · 9 · 4 | Second high-tier author, standard features, reviewer of Claude code. Grok: parsing/validation/trigger logic, research, debugging, second-opinion reviewer. Composer: scaffolding, integrations, CLI, fix-up lane, checklist reviewer |
| Antigravity | Flash-H · Flash-M · Flash-L | 7 · 3 · 2 | Low and standard tasks, protocols, small features, scripts |
