# Competitor research

Researched October 2026. Most details come from vendor pages and directory listings (AlternativeTo, Setapp, Softpedia). Prices and features may change.

## Two categories

- **Layout managers** that drive the native Dock (our category): DockFlow, Modoki, DockProfiles, DockIt Space, Dockfinity, Hidock, Dockey.
- **Dock replacements** that draw their own dock (out of scope): DockDoor Pro, uBar, ActiveDock, HyperDock, ExtraDock, InfyniDock, CoolDock, cDock, GeekDock.

## Layout managers

| App | Price | Notable features |
|---|---|---|
| **DockFlow** | $9.99/yr (Setapp), Gumroad €9.99 | Presets that also launch apps, browser profiles, and projects; closes unneeded apps on switch; menu bar + hotkey; Shortcuts + Focus integration; "Lock Dock" to one display; no special permissions; save current Dock in one click; rename presets |
| **Modoki** | $5.99 one-time | Unlimited layouts; Focus mode auto-switch; custom hotkeys per layout; drag and drop from Finder; auto-quit/reopen apps; invisible mode (hides menu bar + Dock icons); layout editing and history previews (v1.2); local-only |
| **DockProfiles** | Free | Save/switch layouts in one click; apps, folders, websites; menu bar; saves a default profile on first launch |
| **DockIt Space** | Paid | Multiple profiles; per-profile Dock settings; auto app discovery incl. external drives; usage-based auto-ordering; context-aware profile suggestions; menu bar or regular app |
| **Dockfinity** | Free, open source | Profiles with apps, URLs, folders; menu bar; hotkeys; import/export |
| **Hidock** | Free | Different Dock settings per display configuration |
| **Dockey** | Free | GUI for hidden Dock prefs; live preview before saving; autohide delay/speed; position; reset button |

## Dock replacements (reference only)

- **DockDoor** (free, MIT) / **DockDoor Pro**: window previews, Alt-Tab, per-display profiles, AppSense (frontmost app → profile), widgets, file tray, music player, custom icons, themes, gestures, settings export.
- **uBar** ($39): taskbar/dock modes, window grouping, live previews, per-monitor bars, CPU/RAM, badges, device/battery/sound controls, AI command bar.
- **ActiveDock**, **HyperDock**: window previews and window management. HyperDock is reportedly unmaintained.
- **ExtraDock**, **CoolDock**: floating extra docks with widgets.

## Borrowed into oh-my-dock

- One-click save current Dock; auto default profile — DockFlow, DockProfiles
- Focus mode triggers — Modoki, DockFlow
- Shortcuts integration — DockFlow
- Display-config triggers — Hidock
- Frontmost-app triggers — DockDoor Pro (AppSense)
- Launch/quit apps on switch — DockFlow, Modoki
- Per-profile Dock settings; usage-based ordering; external-drive discovery — DockIt Space
- Live preview of prefs + reset — Dockey
- Import/export; URLs in profiles — Dockfinity
- Invisible mode — Modoki
- Layout history — Modoki

## Our differentiators (not found in competitors)

1. Export a profile as a `dockutil` shell script (dotfiles / new Mac setup)
2. Missing-app detection with `brew install --cask`
3. CLI + URL scheme
4. MDM / fleet script output (Jamf, Kandji)
5. Wi-Fi and time-of-day triggers
6. iCloud sync of profiles
7. Diff preview before applying

## Sources

- https://setapp.com/apps/dockflow
- https://353640881875.gumroad.com/l/dockflow
- https://modoki.app
- https://www.alternativeto.net/software/modoki/about/
- https://alternativeto.net/software/dockit-space/about
- https://alternativeto.net/software/hidock
- https://alternativeto.net/software/dockprofiles
- https://www.ifun.de/dockprofiles-mac-app-verwaltet-individuelle-dock-layouts-267184/
- https://alternativeto.net/software/dockfinity/about
- https://aloa.co/blog/dockey-mac-app-tip
- https://mac.softpedia.com/get/Utilities/Dockey.shtml
- https://pro.dockdoor.net/llms.txt
- https://github.com/ejbills/DockDoor
- https://ubarapp.com/
- https://dev.to/appish/best-dock-apps-for-mac-whats-actually-worth-installing-in-2026-57em
