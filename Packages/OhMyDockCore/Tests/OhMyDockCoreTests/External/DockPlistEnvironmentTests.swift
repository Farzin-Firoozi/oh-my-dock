import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct DockPlistEnvironmentTests {
    @Test func tildePathToLivePlistIsRefused() async throws {
        try await ExternalTestSupport.withExclusiveEnvironment {
            unsetenv(DockPlistEnvironment.overrideKey)
            defer { unsetenv(DockPlistEnvironment.overrideKey) }
            setenv(DockPlistEnvironment.overrideKey, "~/Library/Preferences/com.apple.dock.plist", 1)
            #expect(throws: DockPlistEnvironmentError.liveDockPlistRefused) {
                _ = try DockPlistEnvironment.resolvedOverridePlist()
            }
        }
    }

    @Test func hardLinkToLivePlistIsRefused() async throws {
        let live = DockPlistEnvironment.liveDockPlistURL
        guard FileManager.default.fileExists(atPath: live.path) else {
            Issue.record("No live Dock plist; skipping hard-link test")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-plist-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hardLink = directory.appendingPathComponent("hardlink.plist")
        try FileManager.default.linkItem(at: live, to: hardLink)

        try await ExternalTestSupport.withExclusiveEnvironment {
            unsetenv(DockPlistEnvironment.overrideKey)
            defer { unsetenv(DockPlistEnvironment.overrideKey) }
            setenv(DockPlistEnvironment.overrideKey, hardLink.path, 1)
            #expect(throws: DockPlistEnvironmentError.liveDockPlistRefused) {
                _ = try DockPlistEnvironment.resolvedOverridePlist()
            }
        }
    }
}
