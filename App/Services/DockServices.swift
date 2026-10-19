import Foundation
import OhMyDockCore

/// Profile persistence as the menu bar needs it. `ProfileStore` is the live implementation.
protocol ProfileLibrary: Sendable {
    func profiles() async -> [Profile]
    func save(_ profile: Profile) async throws
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
}

extension ProfileApplier: ProfileApplying {}

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
    /// Restores the Dock to `target` and restarts it.
    func undo(_ target: UndoTarget) async throws
}

enum UndoError: Error, LocalizedError {
    /// The snapshot was restored but the Dock could not be restarted to load it.
    case restoredButRestartFailed(any Error)

    var errorDescription: String? {
        switch self {
        case let .restoredButRestartFailed(error):
            "The previous Dock was restored but the Dock could not be restarted: \(error). "
                + "Log out and back in, or restart the Dock, to see it."
        }
    }
}

/// Undo backed by the apply snapshots in a `SnapshotStore`.
///
/// The target is the newest snapshot taken by an apply. Other snapshots (the pinned first-launch
/// one, the safety copy a restore makes of the Dock it replaces) are not "the last change", so an
/// undo never lands on them.
struct SnapshotUndoService: DockUndoing {
    static let applyReasonPrefix = "Before applying profile"

    let snapshots: SnapshotStore
    let restarter: any DockRestarting

    func undoTarget() async -> UndoTarget? {
        await snapshots.list().snapshots
            .first { $0.reason.hasPrefix(Self.applyReasonPrefix) }
            .map { UndoTarget(id: $0.id, createdAt: $0.createdAt, summary: $0.reason) }
    }

    func undo(_ target: UndoTarget) async throws {
        try await snapshots.restore(id: target.id)
        do {
            try await restarter.restart()
        } catch {
            throw UndoError.restoredButRestartFailed(error)
        }
    }
}
