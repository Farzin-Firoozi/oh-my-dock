import Foundation
import OhMyDockCore
import Testing

/// The live adapters, wired to real core types over temp directories and fakes. Nothing here
/// touches the live Dock: the backend is `FakeDockBackend`, the domain is an in-memory plist and
/// the restarter only counts.
private actor FakeDomainIO: DockDomainIO {
    private(set) var imports: [Data] = []
    private let data: Data

    init() {
        data = try! PropertyListSerialization.data(
            fromPropertyList: ["persistent-apps": [Any](), "persistent-others": [Any]()],
            format: .binary,
            options: 0
        )
    }

    func exportDomain(to url: URL) async throws { try data.write(to: url) }
    func importDomain(from url: URL) async throws { imports.append(try Data(contentsOf: url)) }
}

private actor CountingRestarter: DockRestarting {
    private(set) var count = 0
    func restart() async throws { count += 1 }
}

/// A clock that moves forward 10 seconds per reading, so snapshot order is unambiguous.
private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSinceReferenceDate: 1_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(10)
        return date
    }
}

@MainActor
@Suite struct LiveServicesTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ohmydock-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func applyThenUndoRoundTripsThroughRealStores() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = FakeDomainIO()
        let restarter = CountingRestarter()
        let profiles = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let snapshots = SnapshotStore(rootDirectory: root.appendingPathComponent("snapshots"), domainIO: domain)
        let original = DockState(apps: [.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))])
        let dock = FakeDockBackend(state: original)
        let applier = ProfileApplier(backend: dock, snapshots: snapshots, restarter: restarter, resolvePath: { $0.path })
        let model = MenuBarViewModel(
            library: profiles,
            dock: dock,
            applier: applier,
            undoer: SnapshotUndoService(snapshots: snapshots, restarter: restarter)
        )

        // Save the current Dock, change the Dock, then switch back to the saved profile.
        #expect(await model.saveCurrentDock(as: "Browsing"))
        let saved = try #require(model.profiles.first)
        await dock.setState(DockState(apps: [.app(AppRef(bundleId: "com.apple.Notes", name: "Notes", path: "/Applications/Notes.app"))]))
        await model.refresh()
        #expect(model.activeProfileID == nil)
        #expect(model.canUndo == false)

        await model.performApply(saved)
        #expect(model.activeProfileID == saved.id)
        #expect(model.canUndo)

        // Undo restores the pre-apply snapshot and restarts the Dock (once for apply, once for undo).
        await model.performUndo()
        #expect(await domain.imports.count == 1)
        #expect(await restarter.count == 2)
        #expect(model.banner?.kind == .success)
        // Undo is spent until the next apply or restore.
        #expect(model.canUndo == false)
    }

    @Test func undoTargetIgnoresSnapshotsThatAreNotMutations() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SnapshotStore(rootDirectory: root, domainIO: FakeDomainIO(), now: TickingClock().now)
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: CountingRestarter())

        try await snapshots.save(reason: "First launch", pinned: true)
        #expect(await undo.undoTarget() == nil)

        let apply = try await snapshots.save(reason: "Before applying profile Work", profileName: "Work")
        #expect(await undo.undoTarget()?.id == apply.id)

        // A restore is a Dock mutation too: undo goes back to the Dock it replaced.
        try await snapshots.save(reason: "Before restoring today")
        let restore = try await snapshots.list().snapshots.first { $0.reason.hasPrefix("Before restoring") }
        #expect(await undo.undoTarget()?.id == restore?.id)
    }

    @Test func undoAfterAHistoryRestoreTargetsTheSnapshotBeforeThatRestore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let restarter = CountingRestarter()
        let snapshots = SnapshotStore(rootDirectory: root, domainIO: FakeDomainIO(), now: TickingClock().now)
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: restarter)
        let history = SnapshotHistoryService(snapshots: snapshots, restarter: restarter)

        try await snapshots.save(reason: "Before applying profile Work", profileName: "Work")
        let old = try await snapshots.save(reason: "Some older state")
        try await history.restore(id: old.id)

        // The newest snapshot is the safety copy the restore made, and it is newer than the apply.
        let target = try #require(await undo.undoTarget())
        #expect(target.summary.hasPrefix("Before restoring"))
    }

    @Test func undoIsDisabledAfterUseUntilANewMutation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let restarter = CountingRestarter()
        let snapshots = SnapshotStore(rootDirectory: root, domainIO: FakeDomainIO(), now: TickingClock().now)
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: restarter)

        try await snapshots.save(reason: "Before applying profile Work", profileName: "Work")
        let target = try #require(await undo.undoTarget())

        try await undo.undo(target)
        #expect(await undo.undoTarget() == nil)
        #expect(await restarter.count == 1)

        // The next apply (or restore) is a new mutation and re-enables Undo.
        let next = try await snapshots.save(reason: "Before applying profile Home", profileName: "Home")
        #expect(await undo.undoTarget()?.id == next.id)
    }
}
