import Foundation
import OhMyDockCore
import Testing

private actor NullDomain: DockDomainIO {
    private let data = try! PropertyListSerialization.data(
        fromPropertyList: ["persistent-apps": [Any](), "persistent-others": [Any]()], format: .binary, options: 0
    )
    func exportDomain(to url: URL) async throws { try data.write(to: url) }
    func importDomain(from url: URL) async throws {}
}

private actor CountingRestarter: DockRestarting {
    private(set) var count = 0
    var fail = false
    func restart() async throws {
        count += 1
        if fail { throw Failure() }
    }
    func setFail(_ value: Bool) { fail = value }
    struct Failure: Error {}
}

/// The live previewer over an in-memory preferences domain, a temp snapshot store and a counting
/// restarter. Nothing here reads or writes the real Dock.
@Suite struct LivePrefsPreviewerTests {
    private func rig(initial: [String: Any]) throws -> (LivePrefsPreviewer, InMemoryDockPrefsDomainIO, CountingRestarter, SnapshotStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ohmydock-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = InMemoryDockPrefsDomainIO(initial: initial)
        let restarter = CountingRestarter()
        let snapshots = SnapshotStore(rootDirectory: root, domainIO: NullDomain())
        let previewer = LivePrefsPreviewer(writer: DockPrefsWriter(domainIO: domain), snapshots: snapshots, restarter: restarter)
        return (previewer, domain, restarter, snapshots, root)
    }

    @Test func beginWritesVerifiesRestartsOnceAndRevertRestores() async throws {
        let (previewer, domain, restarter, snapshots, root) = try rig(initial: ["tilesize": 48.0, "autohide": false])
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try #require(try await previewer.begin(DockPrefs(tileSize: 80, autohide: true)))
        #expect(domain.value(forKey: "tilesize") as? Double == 80)
        #expect(domain.value(forKey: "autohide") as? Bool == true)
        #expect(await restarter.count == 1)
        #expect(await snapshots.list().snapshots.count == 1)
        #expect(await snapshots.list().snapshots.first?.reason == LivePrefsPreviewer.snapshotReason)

        try await previewer.revert(session)
        #expect(domain.value(forKey: "tilesize") as? Double == 48)
        #expect(domain.value(forKey: "autohide") as? Bool == false)
        #expect(await restarter.count == 2)
        // The temporary snapshot is gone once the Dock is back.
        #expect(await snapshots.list().snapshots.isEmpty)
    }

    @Test func revertRemovesKeysThatWereAbsent() async throws {
        let (previewer, domain, _, _, root) = try rig(initial: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try #require(try await previewer.begin(DockPrefs(magnification: true)))
        #expect(domain.value(forKey: "magnification") as? Bool == true)
        try await previewer.revert(session)
        #expect(domain.value(forKey: "magnification") == nil)
    }

    @Test func resetPreviewRemovesKeysAndRevertPutsThemBack() async throws {
        let (previewer, domain, restarter, _, root) = try rig(initial: ["tilesize": 80.0, "autohide": true])
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try #require(try await previewer.begin(DockPrefs(resetKeys: [.tileSize, .largeSize])))
        #expect(domain.value(forKey: "tilesize") == nil)
        #expect(domain.value(forKey: "autohide") as? Bool == true)
        #expect(session.changedKeys == [.tileSize])
        #expect(await restarter.count == 1)
        try await previewer.revert(session)
        #expect(domain.value(forKey: "tilesize") as? Double == 80)
    }

    @Test func nothingToChangeReturnsNilWithoutSnapshotOrRestart() async throws {
        let (previewer, _, restarter, snapshots, root) = try rig(initial: ["tilesize": 48.0])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await previewer.begin(DockPrefs(tileSize: 48)) == nil)
        #expect(await restarter.count == 0)
        #expect(await snapshots.list().snapshots.isEmpty)
    }

    @Test func invalidPrefsAreRejectedBeforeAnySnapshot() async throws {
        let (previewer, domain, _, snapshots, root) = try rig(initial: ["tilesize": 48.0])
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: DockPrefsWriterError.self) { try await previewer.begin(DockPrefs(tileSize: 999)) }
        #expect(domain.value(forKey: "tilesize") as? Double == 48)
        #expect(await snapshots.list().snapshots.isEmpty)
    }

    @Test func restartFailureRollsTheValuesBack() async throws {
        let (previewer, domain, restarter, _, root) = try rig(initial: ["tilesize": 48.0])
        defer { try? FileManager.default.removeItem(at: root) }
        await restarter.setFail(true)
        await #expect(throws: (any Error).self) { try await previewer.begin(DockPrefs(tileSize: 80)) }
        // The values were rolled back even though the restart that follows also failed.
        #expect(domain.value(forKey: "tilesize") as? Double == 48)
    }

    @Test func revertFailureIsReportedWithTheSnapshot() async throws {
        let (previewer, _, restarter, snapshots, root) = try rig(initial: ["tilesize": 48.0])
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try #require(try await previewer.begin(DockPrefs(tileSize: 80)))
        await restarter.setFail(true)
        await #expect(throws: PrefsPreviewError.self) { try await previewer.revert(session) }
        // Kept so History can restore it.
        #expect(await snapshots.list().snapshots.count == 1)
    }
}
