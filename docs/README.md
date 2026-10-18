# oh-my-dock — Docs

A macOS menu bar app for managing the **native macOS Dock** with profiles, automation, and a visual editor. Under the hood it drives [`dockutil`](https://github.com/kcrawford/dockutil) and `defaults write com.apple.dock`.

## Scope

oh-my-dock **only modifies Apple's real Dock**. It does not draw its own dock, replace the Dock, or overlay UI on top of it.

## Documents

| Doc | Contents |
|---|---|
| [features.md](features.md) | Full feature list, grouped by area |
| [profile-switching.md](profile-switching.md) | Quit-old / launch-new app behavior on profile switch |
| [competitors.md](competitors.md) | Competitor research and what we borrow / skip |
| [technical-notes.md](technical-notes.md) | Implementation notes, APIs, platform limits, distribution |
| [profile-gallery.md](profile-gallery.md) | Community profile gallery (GitHub registry), portability, security rules |
| [roadmap.md](roadmap.md) | MVP and later phases |

## Example of what the app automates

```sh
dockutil --add '/Applications/Safari.app' --position 1 --no-restart
dockutil --add '/Applications/Google Chrome.app' --after 'Safari' --no-restart
dockutil --add '/System/Applications/Utilities/Terminal.app' --position end --no-restart
killall Dock
```

## Business model

**Free and open source (MIT).** Every feature is free, with no paid tier. Funding comes from GitHub Sponsors and donations. Distributed through GitHub Releases and a Homebrew cask (Developer ID–signed and notarized).
