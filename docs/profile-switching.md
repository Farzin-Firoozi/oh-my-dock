# Profile switching: quit old apps, launch new ones

When the user switches from profile **A** to profile **B**, oh-my-dock can close apps that belong to A and open apps that belong to B, in addition to swapping the Dock layout.

## Flow

1. **Compute three sets**
   - **Quit** = running apps from A that are not in B
   - **Keep** = apps in both A and B (left running, untouched)
   - **Launch** = apps in B marked *launch on switch* that aren't running
2. **Confirm** (if enabled): a sheet lists "Will quit: Slack, Figma — Will open: Xcode, Terminal", with a "Don't ask again" checkbox.
3. **Quit gracefully** with `NSRunningApplication.terminate()`. This is the same as ⌘Q, so apps still show "Save changes?" dialogs and no work is lost.
4. **Wait** up to a timeout (default 10 s). Apps still running, typically because a save dialog is open, are left alone and reported in a notification.
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

**Release gates:** before shipping quit/launch, test on macOS 14, 15 and current with a notarized Developer ID build on a clean TCC state, and verify `forceTerminate()` separately before shipping force quit. Always handle `terminate() == false` and timeouts. Never hand-build quit Apple Events / AppleScript: those need Automation consent.
