import Foundation
import OhMyDockCore

/// Profile persistence as the menu bar needs it. `ProfileStore` is the live implementation.
protocol ProfileLibrary: Sendable {
    func profiles() async -> [Profile]
    func save(_ profile: Profile) async throws
    /// Read-modify-write of one stored profile in a single store call.
    @discardableResult
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) async throws -> Profile
    /// Sets or clears a profile's hotkey; refuses one another profile already uses.
    @discardableResult
    func setHotkey(id: UUID, to hotkey: Hotkey?) async throws -> Profile
}

extension ProfileStore: ProfileLibrary {
    func profiles() -> [Profile] { list().profiles }
}

/// Applies a profile to the Dock. `ProfileApplier` is the live implementation.
protocol ProfileApplying: Sendable {
    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult
    /// `source` is the profile being switched away from (it scopes which apps get quit);
    /// `trigger` tells a click from an automatic source such as a hotkey.
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult
}

extension ProfileApplying {
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        try await apply(profile, confirm: confirm)
    }
}

extension ProfileApplier: ProfileApplying {}

/// Puts a pending confirmation in front of the user outside the popover (an alert), for applies
/// started by a hotkey while the menu is closed.
@MainActor
protocol ConfirmationPresenting: AnyObject {
    /// Shows `confirmation`; calls `answer` when the user picks. Calls after `dismiss()` are ignored.
    func present(_ confirmation: MenuBarViewModel.Confirmation, answer: @escaping @MainActor (Bool) -> Void)
    /// Takes the alert down because the question was answered elsewhere or timed out.
    func dismiss()
}

/// The snapshot an undo would go back to.
struct UndoTarget: Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    /// What the snapshot was taken before, e.g. "Before applying profile Work".
    let summary: String
}

/// Goes back to the Dock as it was before the last applied change.
protocol DockUndoing: Sendable {
    func undoTarget() async -> UndoTarget?
    /// Restores the Dock to the current undo target, resolved now rather than when the caller last
    /// looked, and restarts it. If `expecting` is given and is no longer the target (the history
    /// changed underneath the caller), throws `UndoError.targetChanged` and restores nothing.
    func undo(expecting id: UUID?) async throws
}

/// Snapshot persistence and Dock restart operations needed by the history window.
protocol SnapshotHistoryManaging: Sendable {
    func list() async -> [Snapshot]
    /// Restores a snapshot, then restarts the Dock so it reads the restored preferences.
    func restore(id: UUID) async throws
    func pin(id: UUID) async throws
    func unpin(id: UUID) async throws
    func delete(id: UUID) async throws
}

enum UndoError: Error, LocalizedError {
    /// There is no unspent snapshot to go back to.
    case nothingToUndo
    /// The target the caller showed is not the target any more; nothing was restored.
    case targetChanged
    /// The snapshot was restored but the Dock could not be restarted to load it.
    case restoredButRestartFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .nothingToUndo:
            "There is nothing to undo."
        case .targetChanged:
            "The snapshot history changed, so Undo was not run. Check what it would restore and try again."
        case let .restoredButRestartFailed(error):
            "The previous Dock was restored but the Dock could not be restarted: \(error). "
                + "Log out and back in, or restart the Dock, to see it."
        }
    }
}

/// Undo backed by the snapshots a `SnapshotStore` takes right before Dock mutations.
///
/// The target is the newest snapshot taken immediately before the most recent Dock mutation of
/// any kind: an apply ("Before applying profile …") or a restore, whether from the history window
/// or an undo ("Before restoring …", the safety copy `SnapshotStore.restore` makes of the Dock it
/// replaces). Other snapshots, such as the pinned first-launch one, are not "the last change", so
/// an undo never lands on them.
///
/// An undo is itself a restore, so it leaves a fresh safety snapshot behind that would otherwise
/// be offered as the next target and turn Undo into a redo toggle. After an undo this service
/// marks every mutation snapshot that exists as spent and offers only unspent ones, so Undo stays
/// disabled after use until the next apply or restore creates a new snapshot. (Tracking ids, not
/// "the newest", keeps this right when snapshots share a timestamp.) The spent set is persisted
/// through `SpentUndoRecording`, so a relaunch does not re-arm Undo on the last undo's safety copy.
///
/// The target is resolved inside `undo`, from a fresh snapshot listing, never from a value the
/// caller cached.
actor SnapshotUndoService: DockUndoing {
    static let applyReasonPrefix = "Before applying profile"
    static let restoreReasonPrefix = "Before restoring"

    private let snapshots: SnapshotStore
    private let restarter: any DockRestarting
    private let record: any SpentUndoRecording
    private let prefsWriter: (any DockPrefsWriting)?
    private var spent: Set<UUID>

    /// `prefsWriter` puts the Dock preferences a snapshot recorded back along with the tiles.
    /// Undo never reopens apps that a switch quit.
    init(
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        record: any SpentUndoRecording = InMemorySpentUndoRecord(),
        prefsWriter: (any DockPrefsWriting)? = nil
    ) {
        self.snapshots = snapshots
        self.restarter = restarter
        self.record = record
        self.prefsWriter = prefsWriter
        spent = record.load()
    }

    func undoTarget() async -> UndoTarget? {
        guard let newest = await mutationSnapshots().first(where: { !spent.contains($0.id) }) else { return nil }
        return UndoTarget(id: newest.id, createdAt: newest.createdAt, summary: newest.reason)
    }

    func undo(expecting id: UUID?) async throws {
        guard let target = await undoTarget() else { throw UndoError.nothingToUndo }
        if let id, id != target.id { throw UndoError.targetChanged }
        try await snapshots.restore(id: target.id, prefsWriter: prefsWriter)
        // The Dock now holds the restored state; whatever happens next, this undo is used up.
        // Ids of snapshots that no longer exist are dropped so the file doesn't grow forever.
        let existing = Set(await snapshots.list().snapshots.map(\.id))
        let mutations = Set(await mutationSnapshots().map(\.id))
        spent = spent.union(mutations).intersection(existing)
        record.save(spent)
        do {
            try await restarter.restart()
        } catch {
            throw UndoError.restoredButRestartFailed(error)
        }
    }

    /// Newest first.
    private func mutationSnapshots() async -> [Snapshot] {
        await snapshots.list().snapshots.filter {
            $0.reason.hasPrefix(Self.applyReasonPrefix) || $0.reason.hasPrefix(Self.restoreReasonPrefix)
        }
    }
}

enum SnapshotHistoryError: Error, LocalizedError {
    /// The snapshot was restored but the Dock could not be restarted to load it.
    case restoredButRestartFailed(any Error)

    var errorDescription: String? {
        switch self {
        case let .restoredButRestartFailed(error):
            "The snapshot was restored but the Dock could not be restarted: \(error). "
                + "Log out and back in, or restart the Dock, to see it."
        }
    }
}

/// Live history service backed by `SnapshotStore`.
struct SnapshotHistoryService: SnapshotHistoryManaging {
    let snapshots: SnapshotStore
    let restarter: any DockRestarting
    var prefsWriter: (any DockPrefsWriting)?

    func list() async -> [Snapshot] {
        await snapshots.list().snapshots
    }

    func restore(id: UUID) async throws {
        try await snapshots.restore(id: id, prefsWriter: prefsWriter)
        do {
            try await restarter.restart()
        } catch {
            throw SnapshotHistoryError.restoredButRestartFailed(error)
        }
    }

    func pin(id: UUID) async throws {
        try await snapshots.pin(id: id)
    }

    func unpin(id: UUID) async throws {
        try await snapshots.unpin(id: id)
    }

    func delete(id: UUID) async throws {
        try await snapshots.delete(id: id)
    }
}
