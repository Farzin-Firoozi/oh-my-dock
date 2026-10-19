cask "oh-my-dock" do
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Farzin-Firoozi/oh-my-dock/releases/download/v#{version}/OhMyDock-#{version}.zip"
  name "oh-my-dock"
  desc "Profiles and automation for the native macOS Dock"
  homepage "https://github.com/Farzin-Firoozi/oh-my-dock"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "OhMyDock.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/OhMyDock.app"]
  end

  zap trash: [
    "~/Library/Application Support/oh-my-dock",
    "~/Library/Preferences/io.github.farzin-firoozi.OhMyDock.plist",
    "~/Library/Caches/io.github.farzin-firoozi.OhMyDock",
  ]

  caveats <<~EOS
    oh-my-dock is ad-hoc signed and not notarized (no Apple Developer ID).
    macOS Gatekeeper may block the first launch; use Right-click → Open, or run:
      xattr -cr /Applications/OhMyDock.app
  EOS
end
