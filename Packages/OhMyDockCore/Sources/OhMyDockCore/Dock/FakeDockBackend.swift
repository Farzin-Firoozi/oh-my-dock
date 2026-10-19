import Foundation

public actor FakeDockBackend: DockBackend {
    public private(set) var state: DockState
    public private(set) var appliedBatches: [[DockOperation]] = []
    public private(set) var readCount: Int = 0

    private var nextApplyError: (any Error & Sendable)?
    private var shouldCorruptNextWrite: Bool = false
    private var corruptNextWriteState: DockState?

    public init(state: DockState = DockState()) {
        self.state = state
    }

    public func read() async throws -> DockState {
        readCount += 1
        return state
    }

    public func apply(_ operations: [DockOperation]) async throws {
        appliedBatches.append(operations)

        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }

        let expected = try state.applying(operations)

        if shouldCorruptNextWrite {
            shouldCorruptNextWrite = false
            let actual: DockState
            if let custom = corruptNextWriteState {
                actual = custom
                corruptNextWriteState = nil
            } else {
                var corrupted = expected
                let canary = DockItem.spacer(.small)
                if corrupted.apps.last == canary {
                    corrupted.apps.append(.spacer(.normal))
                } else {
                    corrupted.apps.append(canary)
                }
                actual = corrupted
            }
            state = actual
        } else {
            state = expected
        }

        if state != expected {
            throw DockBackendError.verificationFailed(expected: expected, actual: state)
        }
    }

    /// Replaces the state without recording an apply, as if the Dock reloaded other preferences.
    public func setState(_ newState: DockState) {
        state = newState
    }

    public func failNextApply(with error: any Error & Sendable) {
        nextApplyError = error
    }

    public func corruptNextWrite(to corruptedState: DockState? = nil) {
        shouldCorruptNextWrite = true
        corruptNextWriteState = corruptedState
    }

    public func corruptNextWrite(_ corruptedState: DockState) {
        corruptNextWrite(to: corruptedState)
    }
}
