import Foundation
import OhMyDockCore

/// A preview that is currently on the Dock: what to put back, and the snapshot taken before it.
struct PrefsPreviewSession: Hashable, Sendable {
    let snapshotID: UUID?
    let image: DockPrefsRollbackImage
    let changedKeys: [DockPrefs.Key]
}

/// Puts Dock preferences on the live Dock temporarily and takes them off again. Callers run these
/// inside `DockOperationGate`; the service itself does not serialise.
protocol DockPrefsPreviewing: Sendable {
    /// The Dock's current preferences, for “capture from current Dock”.
    func captureCurrent() throws -> DockPrefs
    /// Applies only `prefs` (snapshot, write, one Dock restart, verify). Nil when the Dock already
    /// holds every value, so there is nothing to revert.
    func begin(_ prefs: DockPrefs) async throws -> PrefsPreviewSession?
    /// Restores the values recorded before `begin`, restarts the Dock and verifies them.
    func revert(_ session: PrefsPreviewSession) async throws
}

enum PrefsPreviewError: Error, LocalizedError, Equatable {
    /// The preview could not be taken back out. `snapshotID` is the pre-preview snapshot in History.
    case rollbackFailed(snapshotID: UUID?, reason: String)

    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(snapshotID, reason):
            let hint = snapshotID == nil ? "" : " Restore the snapshot “Before previewing Dock preferences” from History."
            return "The Dock preferences could not be put back: \(reason).\(hint)"
        }
    }
}

/// Live preview: writer + snapshot store + restarter, the same pieces `ProfileApplier` uses.
struct LivePrefsPreviewer: DockPrefsPreviewing {
    static let snapshotReason = "Before previewing Dock preferences"

    let writer: any DockPrefsWriting
    let snapshots: SnapshotStore
    let restarter: any DockRestarting

    func captureCurrent() throws -> DockPrefs {
        try writer.captureCurrent().asDockPrefs()
    }

    func begin(_ prefs: DockPrefs) async throws -> PrefsPreviewSession? {
        let baseline = try writer.captureCurrent()
        let diff = try writer.diff(current: baseline, target: prefs)
        guard !diff.isEmpty else { return nil }
        let image = DockPrefsRollbackImage(restoring: diff, from: baseline)
        let snapshot = try await snapshots.save(reason: Self.snapshotReason, prefsPreImage: image)
        do {
            let result = try writer.apply(prefs, expecting: baseline)
            try await restarter.restart()
            let actual = try writer.captureCurrent()
            for (key, expected) in prefs.values where actual[key] != expected {
                throw DockPrefsWriterError.verificationFailed(key: key, expected: expected, actual: actual[key])
            }
            return PrefsPreviewSession(snapshotID: snapshot.id, image: image, changedKeys: result.changedKeys)
        } catch {
            if Self.wroteNothing(error) {
                try? await snapshots.delete(id: snapshot.id)
                throw error
            }
            try await takeBack(image, snapshotID: snapshot.id)
            throw error
        }
    }

    func revert(_ session: PrefsPreviewSession) async throws {
        try await takeBack(session.image, snapshotID: session.snapshotID)
    }

    private func takeBack(_ image: DockPrefsRollbackImage, snapshotID: UUID?) async throws {
        do {
            try writer.rollback(image)
            try await restarter.restart()
            guard try writer.holds(image) else {
                throw PrefsPreviewError.rollbackFailed(snapshotID: snapshotID, reason: "the values did not read back")
            }
        } catch let error as PrefsPreviewError {
            throw error
        } catch {
            throw PrefsPreviewError.rollbackFailed(snapshotID: snapshotID, reason: String(describing: error))
        }
        if let snapshotID { try? await snapshots.delete(id: snapshotID) }
    }

    /// Errors thrown before the writer changed any key.
    private static func wroteNothing(_ error: any Error) -> Bool {
        switch error as? DockPrefsWriterError {
        case .prefsChanged, .validation: true
        default: false
        }
    }
}
