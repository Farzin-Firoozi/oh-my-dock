import Foundation
@testable import OhMyDockCore

enum ExternalTestSupport {
    private actor ProcessEnvironmentGate {
        func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
            try await body()
        }
    }

    private static let environmentGate = ProcessEnvironmentGate()

    /// Serializes mutations to `OHMYDOCK_*` process environment (Swift Testing runs suites in parallel).
    static func withExclusiveEnvironment<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await environmentGate.run(body)
    }

    static func tempSupportRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-ext-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv(SupportPaths.supportDirEnvironmentKey, url.path, 1)
        return url
    }

    static func makeCenter(
        dock: any DockBackend = FakeDockBackend(),
        switcher: (any AppSwitching)? = nil,
        locks: OperationLock? = nil
    ) throws -> ExternalCommandCenter {
        _ = try SupportPaths.root()
        let profiles = ProfileStore(rootDirectory: try SupportPaths.profilesDirectory())
        let snapshots = SnapshotStore(rootDirectory: try SupportPaths.snapshotsDirectory())
        let restarter = NoOpDockRestarter()
        let applier = ProfileApplier(
            backend: dock,
            snapshots: snapshots,
            restarter: restarter,
            appSwitcher: switcher
        )
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: restarter)
        let restorer = SnapshotRestorer(snapshots: snapshots, restarter: restarter)
        let locks = try locks ?? OperationLock()
        return ExternalCommandCenter(
            profiles: profiles,
            snapshots: snapshots,
            applier: applier,
            undo: undo,
            restorer: restorer,
            dock: dock,
            locks: locks,
            activeRecord: InMemoryActiveProfileRecord()
        )
    }
}

struct NoOpDockRestarter: DockRestarting {
    func restart() async throws {}
}
