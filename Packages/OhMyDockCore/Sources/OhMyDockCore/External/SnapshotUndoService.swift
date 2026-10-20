import Foundation

public struct UndoTarget: Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let summary: String

    public init(id: UUID, createdAt: Date, summary: String) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
    }
}

public enum UndoError: Error, LocalizedError, Sendable {
    case nothingToUndo
    case targetChanged
    case restoredButRestartFailed(any Error)

    public var errorDescription: String? {
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

/// Undo backed by mutation snapshots in `SnapshotStore`.
public actor SnapshotUndoService {
    public static let applyReasonPrefix = "Before applying profile"
    public static let restoreReasonPrefix = "Before restoring"

    private let snapshots: SnapshotStore
    private let restarter: any DockRestarting
    private let record: any SpentUndoRecording
    private let prefsWriter: (any DockPrefsWriting)?
    private var spent: Set<UUID>

    public init(
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

    public func undoTarget() async -> UndoTarget? {
        guard let newest = await mutationSnapshots().first(where: { !spent.contains($0.id) }) else { return nil }
        return UndoTarget(id: newest.id, createdAt: newest.createdAt, summary: newest.reason)
    }

    public func undo(expecting id: UUID?, controlSource: ControlSource? = nil) async throws -> UUID {
        guard let target = await undoTarget() else { throw UndoError.nothingToUndo }
        if let id, id != target.id { throw UndoError.targetChanged }
        try await snapshots.restore(id: target.id, createSafetySnapshot: true, prefsWriter: prefsWriter, source: controlSource)
        let existing = Set(await snapshots.list().snapshots.map(\.id))
        let mutations = Set(await mutationSnapshots().map(\.id))
        spent = spent.union(mutations).intersection(existing)
        record.save(spent)
        do {
            try await restarter.restart()
        } catch {
            throw UndoError.restoredButRestartFailed(error)
        }
        return target.id
    }

    private func mutationSnapshots() async -> [Snapshot] {
        await snapshots.list().snapshots.filter {
            $0.reason.hasPrefix(Self.applyReasonPrefix) || $0.reason.hasPrefix(Self.restoreReasonPrefix)
        }
    }
}

/// `SnapshotStore.restore` plus one Dock restart.
public struct SnapshotRestorer: Sendable {
    public let snapshots: SnapshotStore
    public let restarter: any DockRestarting
    public var prefsWriter: (any DockPrefsWriting)?

    public init(
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        prefsWriter: (any DockPrefsWriting)? = nil
    ) {
        self.snapshots = snapshots
        self.restarter = restarter
        self.prefsWriter = prefsWriter
    }

    public func restore(id: UUID, source: ControlSource? = nil) async throws {
        try await snapshots.restore(id: id, prefsWriter: prefsWriter, source: source)
        try await restarter.restart()
    }
}
