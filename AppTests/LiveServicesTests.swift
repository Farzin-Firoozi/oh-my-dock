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
    }

    @Test func undoTargetIgnoresSnapshotsThatAreNotApplies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SnapshotStore(rootDirectory: root, domainIO: FakeDomainIO())
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: CountingRestarter())

        try await snapshots.save(reason: "First launch", pinned: true)
        #expect(await undo.undoTarget() == nil)

        let apply = try await snapshots.save(reason: "Before applying profile Work", profileName: "Work")
        try await snapshots.save(reason: "Before restoring today")

        #expect(await undo.undoTarget()?.id == apply.id)
    }
}
