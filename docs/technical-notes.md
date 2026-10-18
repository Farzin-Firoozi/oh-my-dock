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

Two options:

1. **Bundle `dockutil`** (v3 is Swift, Apache-2.0). Shell out to it. Simple, well-tested.
2. **Native plist editing** of `persistent-apps` / `persistent-others` in `com.apple.dock` via `CFPreferences`. No external dependency, faster, more control.

Start with option 1 behind a `DockBackend` protocol so it can be swapped for option 2 later.

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

- **Quit permission**: if `NSRunningApplication.terminate()` needs Accessibility/Automation permission on current macOS, request it **on first use**, when the user first enables quit-on-switch. Never at onboarding.
- **Lock Dock to display**: shelved for the v0.4+ research bucket. Ship without it.
- **Profile format**: **JSON** (native `Codable`, no dependency) for storage and import/export.

- **Dock backend**: **bundle `dockutil`** inside the app, behind a `DockBackend` protocol so native plist editing can replace it later.

## Open questions

- Confirm whether `terminate()` needs any permission (verify during implementation).
