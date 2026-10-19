import Testing
@testable import OhMyDockCore

@Suite("NeverQuitPolicy")
struct NeverQuitPolicyTests {
    @Test(arguments: [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
        "com.apple.WindowServer", "io.github.farzin-firoozi.OhMyDock",
    ])
    func builtInsAreProtected(bundleId: String) {
        #expect(NeverQuitPolicy().protects(info(1, bundleId)))
    }

    @Test func ordinaryAppIsNotProtected() {
        #expect(!NeverQuitPolicy().protects(info(1, "com.apple.Safari")))
    }

    @Test func extrasAreNormalized() {
        let policy = NeverQuitPolicy(extraBundleIds: ["  Com.Music.App "])
        #expect(policy.protects(info(1, "com.music.app")))
    }

    @Test func ownProcessAndBundleProtected() {
        let policy = NeverQuitPolicy(ownBundleId: "dev.copy.OhMyDock", ownProcessIdentifier: 42)
        #expect(policy.reason(for: info(42, "x.y")) == .ownApp)
        #expect(policy.reason(for: info(7, "DEV.copy.ohmydock")) == .ownApp)
    }

    @Test func missingBundleIdProtected() {
        #expect(NeverQuitPolicy().reason(for: info(1, nil)) == .noBundleId)
    }
}
