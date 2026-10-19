import Foundation
import OhMyDockCore

/// The one place real services are constructed. Everything else takes protocols.
@MainActor
enum AppEnvironment {
    struct Shell {
        let menuBar: MenuBarViewModel
        let hotkeys: HotkeyService
        let settings: SettingsViewModel
        let history: HistoryViewModel
        /// The one profile store; the editor and settings share it with the menu bar.
        let profiles: ProfileStore
        /// Serialises every live-Dock mutation across the menu bar and history.
        let gate: DockOperationGate
    }

    /// Builds the one set of services (profile store, snapshot store, restarter, gate) the whole
    /// app shares. Nothing else constructs these.
    static func makeShell() -> Shell {
        let gate = DockOperationGate()
        let profiles = ProfileStore(rootDirectory: ProfileStore.defaultDirectory())
        let snapshots = SnapshotStore()
        let restarter = LiveDockRestarter()
        let backend = makeLiveBackend()
        let applier = ProfileApplier(backend: backend, snapshots: snapshots, restarter: restarter)
        let bootstrapper = FirstLaunchBootstrapper(profileStore: profiles, snapshotStore: snapshots)
        let hotkeys = HotkeyService(registrar: KeyboardShortcutsRegistrar())
        let menuBar = MenuBarViewModel(
            library: profiles,
            dock: backend,
            applier: applier,
            undoer: SnapshotUndoService(snapshots: snapshots, restarter: restarter),
            bootstrap: { _ = try await bootstrapper.runIfNeeded() },
            gate: gate
        )
        hotkeys.attach(menuBar: menuBar)
        let settings = SettingsViewModel(
            library: profiles,
            launchAtLogin: LiveLaunchAtLoginService(),
            hotkeys: hotkeys
        )
        let history = HistoryViewModel(
            history: SnapshotHistoryService(snapshots: snapshots, restarter: restarter),
            gate: gate
        )
        return Shell(menuBar: menuBar, hotkeys: hotkeys, settings: settings, history: history, profiles: profiles, gate: gate)
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
