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
        let updates: UpdateViewModel
        /// The one profile store; the editor and settings share it with the menu bar.
        let profiles: ProfileStore
        /// Serialises every live-Dock mutation across the menu bar and history.
        let gate: DockOperationGate
        /// Previews Dock preferences from the editor; always called through `gate`.
        let prefsPreviewer: any DockPrefsPreviewing
    }

    /// Builds the one set of services (profile store, snapshot store, restarter, gate) the whole
    /// app shares. Nothing else constructs these.
    static func makeShell() -> Shell {
        let gate = DockOperationGate()
        let changes = DockChangeSignal()
        let profiles = ProfileStore(rootDirectory: ProfileStore.defaultDirectory())
        let snapshots = SnapshotStore()
        let restarter = LiveDockRestarter()
        let backend = makeLiveBackend()
        let prefsWriter = DockPrefsWriter()
        // Apps are quit and launched only through this switcher, after the Dock change is verified.
        let appSwitcher = AppSwitcher(
            provider: LiveRunningApps(),
            launcher: LiveAppLauncher(),
            neverQuit: .live()
        )
        let applier = ProfileApplier(
            backend: backend,
            snapshots: snapshots,
            restarter: restarter,
            prefsWriter: prefsWriter,
            appSwitcher: appSwitcher
        )
        let bootstrapper = FirstLaunchBootstrapper(profileStore: profiles, snapshotStore: snapshots)
        let hotkeys = HotkeyService(registrar: KeyboardShortcutsRegistrar())
        let menuBar = MenuBarViewModel(
            library: profiles,
            dock: backend,
            applier: applier,
            undoer: SnapshotUndoService(
                snapshots: snapshots,
                restarter: restarter,
                record: FileSpentUndoRecord(),
                prefsWriter: prefsWriter
            ),
            bootstrap: { _ = try await bootstrapper.runIfNeeded() },
            gate: gate,
            activeRecord: FileActiveProfileRecord(),
            confirmationPresenter: AlertConfirmationPresenter(),
            changes: changes
        )
        hotkeys.attach(menuBar: menuBar)
        let settings = SettingsViewModel(
            library: profiles,
            launchAtLogin: LiveLaunchAtLoginService(),
            hotkeys: hotkeys
        )
        let history = HistoryViewModel(
            history: SnapshotHistoryService(snapshots: snapshots, restarter: restarter, prefsWriter: prefsWriter),
            gate: gate,
            changes: changes
        )
        let updates = UpdateViewModel(
            checker: UpdateChecker(fetcher: URLSessionFetcher()),
            currentVersion: AppVersion.current,
            opener: WorkspaceReleasePageOpener()
        )
        return Shell(menuBar: menuBar, hotkeys: hotkeys, settings: settings, history: history, updates: updates, profiles: profiles, gate: gate,
                     prefsPreviewer: LivePrefsPreviewer(writer: prefsWriter, snapshots: snapshots, restarter: restarter))
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
