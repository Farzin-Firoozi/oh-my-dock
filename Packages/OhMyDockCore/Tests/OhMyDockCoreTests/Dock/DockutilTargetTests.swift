import Darwin
import Foundation
import Testing
@testable import OhMyDockCore

/// `.file` target validation. The runner is a recorder, so nothing can be written even if a
/// check fails: the assertion is that no command is ever issued.
@Suite struct DockutilTargetTests {
    private func attempt(
        _ url: URL,
        harness h: FakeDockHarness,
        liveCandidates: [URL]? = nil
    ) async -> (any Error)? {
        let live = liveCandidates ?? [h.livePlist]
        let backend = DockutilBackend(
            dockutilURL: h.dockutil,
            target: .file(url),
            runner: h.runner,
            reader: { DockState() },
            liveDockPlistURLs: { live }
        )
        do {
            try await backend.apply([.insert(Sample.calculator, section: .apps, index: 0)])
            return nil
        } catch {
            return error
        }
    }

    @Test func ordinaryFileIsAccepted() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        // The reader never changes, so verification fails; reaching it proves the target passed.
        let error = await attempt(h.plist, harness: h)

        #expect(error as? DockBackendError != nil)
        #expect(h.runner.calls.count == 1)
    }

    @Test func refusesTheLivePlistItself() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let error = await attempt(h.livePlist, harness: h)

        #expect(error as? DockutilBackendError == .targetIsLiveDockPlist(path: h.livePlist.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesASymlinkToTheLivePlist() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let link = h.directory.appendingPathComponent("innocent.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.livePlist)

        let error = await attempt(link, harness: h)

        #expect(error as? DockutilBackendError == .targetIsLiveDockPlist(path: h.livePlist.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesAChainOfSymlinksToTheLivePlist() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let first = h.directory.appendingPathComponent("first.plist")
        let second = h.directory.appendingPathComponent("second.plist")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: h.livePlist)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        let error = await attempt(second, harness: h)

        #expect(error as? DockutilBackendError == .targetIsLiveDockPlist(path: h.livePlist.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesDotDotAndDoubleSlashPathsToTheLivePlist() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let sub = h.directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let dotDot = URL(fileURLWithPath: sub.path + "/../live-com.apple.dock.plist")
        let doubleSlash = URL(fileURLWithPath: h.directory.path + "//live-com.apple.dock.plist")
        let dot = URL(fileURLWithPath: h.directory.path + "/./live-com.apple.dock.plist")

        for url in [dotDot, doubleSlash, dot] {
            let error = await attempt(url, harness: h)
            #expect(error as? DockutilBackendError == .targetIsLiveDockPlist(path: h.livePlist.path), "\(url.path)")
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesACaseVariantOfTheLivePlist() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let shouted = URL(fileURLWithPath: h.directory.path + "/LIVE-COM.APPLE.DOCK.PLIST")
        // Only meaningful on a case-insensitive volume, where this names the same file.
        guard FileManager.default.fileExists(atPath: shouted.path) else { return }

        let error = await attempt(shouted, harness: h)

        #expect(error is DockutilBackendError)
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesAHardLinkToTheLivePlist() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let hardLink = h.directory.appendingPathComponent("hardlink.plist")
        try FileManager.default.linkItem(at: h.livePlist, to: hardLink)

        let error = await attempt(hardLink, harness: h)

        #expect(error as? DockutilBackendError == .targetIsLiveDockPlist(path: hardLink.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesADirectory() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let error = await attempt(h.directory, harness: h)

        #expect(error as? DockutilBackendError == .targetIsDirectory(path: h.directory.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesASymlinkToADirectory() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let link = h.directory.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.directory)

        let error = await attempt(link, harness: h)

        #expect(error as? DockutilBackendError == .targetIsDirectory(path: h.directory.path))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesAMissingFile() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let missing = h.directory.appendingPathComponent("missing.plist")

        let error = await attempt(missing, harness: h)

        #expect(error as? DockutilBackendError == .targetMissing(path: missing.path))
        #expect(h.runner.calls.isEmpty)
    }

    /// Uses the real default definition of "live": this user's `~/Library/Preferences/com.apple.dock.plist`.
    /// A symlink to it is created in a temp directory; nothing is written to either file.
    @Test func refusesASymlinkToTheRealLivePlistWithDefaultDetection() async throws {
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard FileManager.default.fileExists(atPath: live.path) else {
            Issue.record("No live Dock plist at \(live.path) to alias; test cannot run on this machine")
            return
        }
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let link = h.directory.appendingPathComponent("alias.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: live)
        let backend = DockutilBackend(
            dockutilURL: h.dockutil,
            target: .file(link),
            runner: h.runner,
            reader: { DockState() }
        )

        let error = await #expect(throws: DockutilBackendError.self) {
            try await backend.apply([.insert(Sample.calculator, section: .apps, index: 0)])
        }

        guard case .targetIsLiveDockPlist? = error else {
            Issue.record("Expected targetIsLiveDockPlist, got \(String(describing: error))")
            return
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func readingAnAliasOfTheLivePlistIsAllowed() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let backend = DockutilBackend(
            dockutilURL: h.dockutil,
            target: .file(h.livePlist),
            runner: h.runner,
            reader: { DockState(apps: [Sample.notes]) },
            liveDockPlistURLs: { [h.livePlist] }
        )

        #expect(try await backend.read() == DockState(apps: [Sample.notes]))
    }
}
