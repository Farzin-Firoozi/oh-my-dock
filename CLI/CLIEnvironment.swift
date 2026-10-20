import Foundation
import OhMyDockCore

enum CLIEnvironment {
    static func makeCenter() throws -> ExternalCommandCenter {
        _ = try SupportPaths.ensureRootExists()
        let profiles = ProfileStore(rootDirectory: ProfileStore.defaultDirectory())
        let snapshots = SnapshotStore()
        let dockutil = resolveDockutilURL()
        let backend = try makeBackend(dockutil: dockutil)
        let restarter: any DockRestarting = plistOverrideActive ? NoOpDockRestarter() : LiveDockRestarter()
        let prefsWriter = DockPrefsWriter()
        let switcher = AppSwitcher(
            provider: LiveRunningApps(),
            launcher: LiveAppLauncher(),
            neverQuit: .live()
        )
        let applier = ProfileApplier(
            backend: backend,
            snapshots: snapshots,
            restarter: restarter,
            prefsWriter: prefsWriter,
            appSwitcher: switcher
        )
        let spentRecord: any SpentUndoRecording = (try? FileSpentUndoRecord()) ?? InMemorySpentUndoRecord()
        let undo = SnapshotUndoService(
            snapshots: snapshots,
            restarter: restarter,
            record: spentRecord,
            prefsWriter: prefsWriter
        )
        let restorer = SnapshotRestorer(snapshots: snapshots, restarter: restarter, prefsWriter: prefsWriter)
        let locks = try OperationLock()
        let activeRecord: any ActiveProfileRecording = (try? FileActiveProfileRecord()) ?? InMemoryActiveProfileRecord()
        return ExternalCommandCenter(
            profiles: profiles,
            snapshots: snapshots,
            applier: applier,
            undo: undo,
            restorer: restorer,
            dock: backend,
            prefsWriter: prefsWriter,
            locks: locks,
            activeRecord: activeRecord,
            dockutilURL: dockutil
        )
    }

    private static var plistOverrideActive: Bool {
        let raw = ProcessInfo.processInfo.environment[DockPlistEnvironment.overrideKey]
        return raw != nil && !(raw?.isEmpty ?? true)
    }

    private static func makeBackend(dockutil: URL?) throws -> any DockBackend {
        if let override = try DockPlistEnvironment.resolvedOverridePlist() {
            guard let dockutil else { return MissingDockutilBackend() }
            return DockutilBackend(dockutilURL: dockutil, target: .file(override))
        }
        guard let dockutil else { return MissingDockutilBackend() }
        return DockutilBackend(dockutilURL: dockutil, target: .live)
    }

    static func resolveDockutilURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("dockutil")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let bundled = BundledTools.dockutilURL(in: Bundle.main) {
            return bundled
        }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if directory.pathExtension == "app" {
                return BundledTools.dockutilURL(inBundleAt: directory)
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("dockutil")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

private struct NoOpDockRestarter: DockRestarting {
    func restart() async throws {}
}

private struct MissingDockutilBackend: DockBackend {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "dockutil is not available; build it with make dockutil and ensure it is on PATH or next to ohmydock."
        }
    }

    func read() async throws -> DockState {
        if let override = try DockPlistEnvironment.resolvedOverridePlist() {
            return try DockPlistReader(.file(override)).read()
        }
        return try DockPlistReader(.live).read()
    }

    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight { throw Unavailable() }
    func apply(_ operations: [DockOperation]) async throws { throw Unavailable() }
}
