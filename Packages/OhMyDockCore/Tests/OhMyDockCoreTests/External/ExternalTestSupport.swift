import Foundation
@testable import OhMyDockCore

enum ExternalTestSupport {
    /// Runs `body` with a replacement process environment (no `setenv`; safe under parallel tests).
    static func withEnvironment<T: Sendable>(
        _ values: [String: String],
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await OhMyDockProcessEnvironment.$override.withValue(values, operation: body)
    }

    /// Serializes legacy tests that still mutate the real process environment.
    static func withExclusiveEnvironment<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await body()
    }

    static func tempSupportRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-ext-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func withSupportRoot<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async rethrows -> T {
        let root = tempSupportRoot()
        return try await withEnvironment([SupportPaths.supportDirEnvironmentKey: root.path]) {
            try await body(root)
        }
    }

    static func makeCenter(
        dock: any DockBackend = FakeDockBackend(),
        switcher: (any AppSwitching)? = nil,
        locks: OperationLock? = nil,
        supportRoot: URL? = nil
    ) throws -> ExternalCommandCenter {
        let root: URL
        if let supportRoot {
            root = supportRoot
        } else {
            root = try SupportPaths.root()
        }
        let profilesDir = root.appendingPathComponent("profiles", isDirectory: true)
        let snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let profiles = ProfileStore(rootDirectory: profilesDir)
        let snapshots = SnapshotStore(rootDirectory: snapshotsDir)
        let restarter = NoOpDockRestarter()
        let applier = ProfileApplier(
            backend: dock,
            snapshots: snapshots,
            restarter: restarter,
            appSwitcher: switcher
        )
        let undo = SnapshotUndoService(snapshots: snapshots, restarter: restarter)
        let restorer = SnapshotRestorer(snapshots: snapshots, restarter: restarter)
        let locks = try locks ?? OperationLock(supportRoot: root)
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
