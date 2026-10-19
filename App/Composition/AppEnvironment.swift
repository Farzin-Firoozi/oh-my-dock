import Foundation
import OhMyDockCore

/// The one place real services are constructed. Everything else takes protocols.
@MainActor
enum AppEnvironment {
    /// The live view model: real profile and snapshot stores, the live Dock, `killall Dock`.
    static func makeMenuBarViewModel() -> MenuBarViewModel {
        let profiles = ProfileStore(rootDirectory: ProfileStore.defaultDirectory())
        let snapshots = SnapshotStore()
        let restarter = LiveDockRestarter()
        let backend = makeLiveBackend()
        let applier = ProfileApplier(backend: backend, snapshots: snapshots, restarter: restarter)
        let bootstrapper = FirstLaunchBootstrapper(profileStore: profiles, snapshotStore: snapshots)

        return MenuBarViewModel(
            library: profiles,
            dock: backend,
            applier: applier,
            undoer: SnapshotUndoService(snapshots: snapshots, restarter: restarter),
            bootstrap: { _ = try await bootstrapper.runIfNeeded() }
        )
    }

    private static func makeLiveBackend() -> any DockBackend {
        guard let dockutil = BundledTools.dockutilURL() else { return MissingDockutilBackend() }
        return DockutilBackend(dockutilURL: dockutil, target: .live)
    }
}

/// Stands in when the bundled dockutil is missing (a build without `make dockutil`): the Dock can
/// still be read, so profiles can be saved and listed, but nothing can be written.
struct MissingDockutilBackend: DockBackend {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "dockutil is not bundled with this build; run make dockutil and rebuild." }
    }

    func read() async throws -> DockState { try DockPlistReader(.live).read() }
    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight { throw Unavailable() }
    func apply(_ operations: [DockOperation]) async throws { throw Unavailable() }
}
