# Profile switching: quit old apps, launch new ones

When the user switches from profile **A** to profile **B**, oh-my-dock can close apps that belong to A and open apps that belong to B, in addition to swapping the Dock layout.

## Flow

> **Order in the implementation:** the Dock layout and preferences are applied, restarted and **verified first** (step 6 below, with rollback). Only then are apps quit and launched. A switch that fails and rolls back never quits anything. Undo restores Dock + preferences, not the apps that were quit.

1. **Compute three sets**
   - **Quit** = running apps from A that are not in B
   - **Keep** = apps in both A and B (left running, untouched)
   - **Launch** = apps in B marked *launch on switch* that aren't running
2. **Confirm** (if enabled): a sheet lists "Will quit: Slack, Figma — Will open: Xcode, Terminal", with a "Don't ask again" checkbox.
3. **Quit gracefully** with `NSRunningApplication.terminate()`. This is the same as ⌘Q: save prompts and quit vetoes are honored. Outcome depends on the target app; apps that don't quit are reported as stragglers (step 4).
4. **Wait** up to a per-app timeout (default 5 s, injectable). Apps still running, typically because a save dialog is open, are left alone and reported in a notification.
5. **Launch** B's apps with `NSWorkspace.openApplication(at:configuration:)`. They open in the background by default (`activates = false`) so they don't steal focus.
6. **Apply** B's Dock layout and preferences, then restart the Dock once.

## Per-profile options

| Option | Values | Default |
|---|---|---|
| Quit scope | *Previous profile's apps only* / *All apps not in new profile* / *Don't quit anything* | Previous profile's apps only |
| Launch on switch | per-app toggle (not every Dock icon should auto-open) | off |
| Launch hidden | start launched apps hidden | off |
| Offer force quit for stragglers | show a "Force quit" action for apps still open after the timeout; runs `forceTerminate()` only after an explicit user click, never automatically | **off** (warn: unsaved work will be lost) |

## Global settings

- **Never-quit list**: always includes Finder and oh-my-dock itself; user-extendable (e.g. Music, 1Password).
- Apps that aren't regular apps (`activationPolicy != .regular`: menu bar apps, agents, background helpers) are **never** touched.
- **Confirm before quitting**: on by default.
- **Automatic triggers** (Focus, display, Wi-Fi, schedule, frontmost app) **don't quit apps** unless the user explicitly opts in. A trigger must not silently close apps.

## Edge cases

- **Multiple windows / documents**: restored by macOS state restoration on next launch.
- **App not installed**: skipped and flagged (ties into missing-app detection / `brew install --cask`).
- **Rapid switching**: switches are queued; a newer switch cancels any in-flight one to avoid quit/launch storms.
- **Stragglers** (apps still running after the timeout, or `terminate()` returned `false`): represented explicitly in the switch result and notification, never silently dropped.
- **App refuses to quit** (modal dialog, save sheet, veto, hung): reported as a straggler. Force quit is never automatic; it is offered only after an explicit user action on that app.
- **Launch timing**: `activates=false` keeps focus on the current app. `hides=true` applies asynchronously: `isHidden` is still `false` in the completion handler and flips to `true` ~1 s later. `NSRunningApplication` state only updates while the run loop runs. Observe `isFinishedLaunching` / `isHidden` / `isTerminated` via KVO, with a timeout, rather than reading them in the callback (see [spike 0.6](spikes/0.6-terminate-permission.md)).

## Permissions

None needed in the tested scope. `terminate()` quit a regular app from a non-sandboxed app with no Accessibility or Automation prompt. Verified on macOS 27.0.1, unmanaged machine, CLI + ad-hoc signed app + ad-hoc hardened app (see [spike 0.6](spikes/0.6-terminate-permission.md)). Not yet tested: macOS 14/15, notarized Developer ID build, MDM/PPPC-managed Macs, save sheets / quit veto / deferral, sandboxed third-party apps, `forceTerminate()`.

**Release gates:** before shipping quit/launch, test on macOS 14, 15 and current with the ad-hoc signed release build on a clean TCC state, and verify `forceTerminate()` separately before shipping force quit. Always handle `terminate() == false` and timeouts. Never hand-build quit Apple Events / AppleScript: those need Automation consent.

## AppSwitcher API (`OhMyDockCore/Switching`)

Implemented in task 4.3 and wired into `ProfileApplier` through the `AppSwitching` protocol (task 4.I): the plan is part of `ApplyPreview`, and `execute` runs after the verified Dock apply. A quitting plan needs confirmation unless an automatic trigger runs a profile with `quitOnAutomaticSwitch`.

```swift
let switcher = AppSwitcher(provider: LiveRunningApps(), launcher: LiveAppLauncher(),
                           neverQuit: .live(extraBundleIds: userList))
let plan = switcher.plan(from: previousProfile, to: targetProfile)   // pure: willQuit / willKeep / willLaunch / protected
// show the confirmation sheet from `plan`, then:
let outcome = await queue.run { await switcher.execute(plan) }       // SwitchQueue serializes switches
// outcome.summary == "Quit 3, Safari refused, Notes still running"
// after an explicit click on a straggler, only if the profile's offerForceQuit is on:
let result = await switcher.forceQuit(app, after: outcome, options: profile.switching)
```

- **Plan** (`AppSwitcher.plan(from:to:running:neverQuit:)`, static and pure) uses the **target** profile's `switching` options. `.none` quits and keeps nothing (launches still happen); `.previousProfileApps` quits running regular apps in the source but not the target (no source profile: quits nothing); `.allNotInProfile` quits every running regular app not in the target. Bundle ids compare case-insensitively. Duplicate instances of one bundle id are each planned. Apps in both profiles are kept and never relaunched. `protected` lists apps the scope covered but that were skipped (never-quit, no bundle id, still launching).
- **Never quit**: `NeverQuitPolicy` = Finder, Dock, SystemUIServer, loginwindow, WindowServer, Control Center, Notification Center, oh-my-dock (by bundle id and, via `.live`, by pid) + the user list; non-`.regular` apps; processes without a bundle id. `execute` re-checks all of this per app right before `terminate()`, so a stale or hand-built plan can't quit them.
- **Execute** quits one app at a time (a save sheet is visible before the next app is asked): `terminate()` only, then polls until exit or the timeout. Per-app status: `quit`, `alreadyExited`, `refused` (`terminate() == false`), `stillRunningAfterTimeout` (save sheet, veto, `.terminateLater`, hung), `quitRequestedUnconfirmed`, `skippedProtected`, `skippedCancelled`. Stragglers (`refused`, `stillRunningAfterTimeout`, `quitRequestedUnconfirmed`) are reported and left alone. Then launches: `activates = false`, `hides = launchHidden`; failures are reported per app; an app that is running by then is not relaunched.
- **Force quit** is the separate `forceQuit(_:after:options:)`. It does nothing unless `options.offerForceQuit` is on and the app is a straggler in the given outcome, and re-checks never-quit and activation policy. `forceTerminate()` behavior is **unverified**; verify it before wiring a UI for it.
- **Cancellation**: cancelling the task (or a newer switch superseding it in `SwitchQueue`) stops before the next app is asked to quit and skips the launch phase. Quits that already happened are **not rolled back**: relaunching wouldn't restore windows or unsaved state, and could reopen apps the user saved and closed. `outcome.wasCancelled` plus the per-app list say exactly what happened.
- **Queue**: `SwitchQueue.run` runs switches strictly one after another. By default a newer switch cancels earlier ones (as above); pass `supersedingEarlier: false` to just queue.
- **Testing**: `FakeRunningApps`, `FakeAppLauncher` and `FakeSwitchClock` (virtual time) cover everything; tests never call the live implementations, which would quit and launch real apps.
