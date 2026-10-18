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

public protocol DockBackend: Sendable {
    /// Current Dock contents.
    func read() async throws -> DockState
    /// Apply operations WITHOUT restarting the Dock. Implementations must verify the
    /// result by re-reading and throw `DockBackendError.verificationFailed` on mismatch.
    func apply(_ operations: [DockOperation]) async throws
}

public enum DockBackendError: Error, Equatable, Sendable {
    case indexOutOfRange(section: DockSection, index: Int)
    case invalidOperation(String)
    case verificationFailed(expected: DockState, actual: DockState)
    case commandFailed(String)
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
