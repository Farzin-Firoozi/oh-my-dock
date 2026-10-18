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
| Force quit after timeout | `forceTerminate()` on apps still open after the timeout | **off** (warn: unsaved work will be lost) |

## Global settings

- **Never-quit list**: always includes Finder and oh-my-dock itself; user-extendable (e.g. Music, 1Password).
- Apps that aren't regular apps (`activationPolicy != .regular`: menu bar apps, agents, background helpers) are **never** touched.
- **Confirm before quitting**: on by default.
- **Automatic triggers** (Focus, display, Wi-Fi, schedule, frontmost app) **don't quit apps** unless the user explicitly opts in. A trigger must not silently close apps.

## Edge cases

- **Multiple windows / documents**: restored by macOS state restoration on next launch.
- **App not installed**: skipped and flagged (ties into missing-app detection / `brew install --cask`).
- **Rapid switching**: switches are queued; a newer switch cancels any in-flight one to avoid quit/launch storms.
- **App refuses to quit** (modal dialog, hung): reported, never force-killed unless force quit is enabled.

## Permissions

`terminate()` on regular apps should work from a non-sandboxed app without Accessibility permission. **Needs verification on current macOS during implementation.** If a permission turns out to be required, request it on first use (when the user first enables quit-on-switch), never at onboarding.
