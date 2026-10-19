import Foundation

/// One edit to the Dock. Operations apply in order; every index refers to the
/// state produced by the previous operation.
public enum DockOperation: Hashable, Sendable {
    /// Insert `item` so that it ends up at `index` in `section` (0 = first; index == count appends).
    case insert(DockItem, section: DockSection, index: Int)
    /// Remove the item at `index` in `section`.
    case remove(section: DockSection, index: Int)
    /// Move the item at `from` so it ends up at `to` in the same section.
    case move(section: DockSection, from: Int, to: Int)
    /// Replace the whole Dock (used when spacers must be removed; see technical-notes write rules).
    case replaceAll(DockState)
}

/// What a backend knows about a batch before writing it.
public struct DockWritePreflight: Hashable, Sendable {
    /// True when writing the batch also clears the Dock's recent-apps list, which is not part of
    /// `DockState`. dockutil does this whenever it has to rewrite the whole Dock.
    public var clearsRecentApps: Bool

    public init(clearsRecentApps: Bool = false) {
        self.clearsRecentApps = clearsRecentApps
    }
}

public protocol DockBackend: Sendable {
    /// Current Dock contents.
    func read() async throws -> DockState
    /// Checks that `apply(operations)` can run and reports side effects, writing nothing.
    /// Throws what `apply` would throw before its first write.
    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight
    /// Like `preflight(_:)`, but plans against `base` (the Dock the operations were computed
    /// from) instead of reading the Dock again, so the answer describes exactly that plan.
    func preflight(_ operations: [DockOperation], from base: DockState) async throws -> DockWritePreflight
    /// Apply operations WITHOUT restarting the Dock. Implementations must verify the
    /// result by re-reading and throw `DockBackendError.verificationFailed` on mismatch.
    func apply(_ operations: [DockOperation]) async throws
    /// Apply operations that were computed from `base`. The backend reads the Dock itself,
    /// right before writing, and throws `DockBackendError.dockChanged` without writing anything
    /// when it differs from `base`: the check and the write cannot be separated by an edit of
    /// the Dock. Throws `CancellationError`, also without writing, when the task was cancelled
    /// by the time that read is done. Once it writes, it never throws `CancellationError`.
    func apply(_ operations: [DockOperation], expecting base: DockState) async throws
}

public extension DockBackend {
    /// Assumes the backend can run any batch that applies cleanly and only clears recent apps
    /// when it replaces the whole Dock.
    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight {
        let replacesAll = operations.contains { if case .replaceAll = $0 { true } else { false } }
        return DockWritePreflight(clearsRecentApps: replacesAll)
    }

    func preflight(_ operations: [DockOperation], from base: DockState) async throws -> DockWritePreflight {
        try await preflight(operations)
    }

    /// Reads, compares and writes in separate steps, so a backend that can do better (read inside
    /// its own write) should implement this itself.
    func apply(_ operations: [DockOperation], expecting base: DockState) async throws {
        guard try await read() == base else { throw DockBackendError.dockChanged }
        try Task.checkCancellation()
        try await apply(operations)
    }
}

public enum DockBackendError: Error, Equatable, Sendable {
    case indexOutOfRange(section: DockSection, index: Int)
    case invalidOperation(String)
    case verificationFailed(expected: DockState, actual: DockState)
    case commandFailed(String)
    /// The Dock is not the state the operations were computed from. Nothing was written.
    case dockChanged
}

public extension DockState {
    func applying(_ ops: [DockOperation]) throws -> DockState {
        var state = self
        for op in ops {
            switch op {
            case let .insert(item, section, index):
                if case .unknown = item {
                    throw DockBackendError.invalidOperation("Unknown dock items cannot be inserted")
                }
                guard index >= 0 && index <= state[section].count else {
                    throw DockBackendError.indexOutOfRange(section: section, index: index)
                }
                state[section].insert(item, at: index)

            case let .remove(section, index):
                guard index >= 0 && index < state[section].count else {
                    throw DockBackendError.indexOutOfRange(section: section, index: index)
                }
                state[section].remove(at: index)

            case let .move(section, from, to):
                let count = state[section].count
                guard from >= 0 && from < count else {
                    throw DockBackendError.indexOutOfRange(section: section, index: from)
                }
                guard to >= 0 && to < count else {
                    throw DockBackendError.indexOutOfRange(section: section, index: to)
                }
                if from != to {
                    let item = state[section].remove(at: from)
                    state[section].insert(item, at: to)
                }

            case let .replaceAll(newState):
                state = newState
            }
        }
        return state
    }
}
