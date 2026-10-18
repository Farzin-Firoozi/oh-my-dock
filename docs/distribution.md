# Distribution

## Homebrew

Users install with:

```sh
brew install --cask farzin/tap/oh-my-dock     # own tap (day one)
brew install --cask oh-my-dock                # official homebrew/cask (later)
```

### Phase 1: own tap (ship with v0.1)

- Create a repo `github.com/<user>/homebrew-tap`, containing `Casks/oh-my-dock.rb`.
- No notability requirements; we fully control it.
- The release script bumps `version` + `sha256` automatically, via a GitHub Action on release publish.

### Phase 2: official `homebrew/cask`

- Submit once the project is **notable enough**. Homebrew rejects casks for little-known projects, and the bar is higher for self-submitted ones. Check the current thresholds in Homebrew's "Acceptable Casks" docs before submitting.
- The app must be **signed with Developer ID and notarized**. Homebrew is phasing out casks that fail Gatekeeper.
- Requires a stable download URL (GitHub Releases), versioned artifacts, and a working `livecheck`.

### Cask draft

```ruby
cask "oh-my-dock" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/<user>/oh-my-dock/releases/download/v#{version}/OhMyDock-#{version}.zip"
  name "oh-my-dock"
  desc "Profiles and automation for the native macOS Dock"
  homepage "https://github.com/<user>/oh-my-dock"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true                  # Sparkle handles updates
  depends_on macos: ">= :sonoma"

  app "OhMyDock.app"
  binary "#{appdir}/OhMyDock.app/Contents/MacOS/ohmydock"   # CLI (v0.3+)

  uninstall quit: "com.<user>.ohmydock"

  zap trash: [
    "~/Library/Application Support/oh-my-dock",
    "~/Library/Preferences/com.<user>.ohmydock.plist",
    "~/Library/Caches/com.<user>.ohmydock",
  ]
end
```

The `<user>` placeholders and the bundle ID get filled in once the GitHub org and bundle identifier are decided. The `binary` line ships the `ohmydock` CLI with the cask, with no separate formula needed.

### Release checklist (per version)

1. `scripts/release.sh`: archive → sign (app + bundled dockutil, hardened runtime) → notarize → staple → zip.
2. Publish a GitHub Release with the zip; update the Sparkle appcast.
3. The tap action updates `version` + `sha256` and opens/merges a PR in `homebrew-tap`.
4. Smoke test: `brew uninstall --cask oh-my-dock; brew install --cask <user>/tap/oh-my-dock`, launch it, and confirm Gatekeeper passes with no warning.
