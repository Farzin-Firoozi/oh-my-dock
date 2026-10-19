import Foundation

/// Runs switches one at a time so two never run the quit phase concurrently.
///
/// A newer switch supersedes earlier ones by default: they are cancelled (cooperatively, see `AppSwitcher`)
/// and the new one starts once they have stopped. A superseded operation that hadn't started yet still
/// runs, already cancelled, so it must check `Task.isCancelled` first (`AppSwitcher.execute` does) and
/// return its "cancelled" result.
public actor SwitchQueue {
    private var tail: Task<Void, Never>?
    private var cancellers: [UInt64: @Sendable () -> Void] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    public func run<T: Sendable>(
        supersedingEarlier: Bool = true,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        if supersedingEarlier {
            for cancel in cancellers.values { cancel() }
        }
        let id = nextID
        nextID += 1
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        cancellers[id] = { task.cancel() }
        tail = Task { _ = await task.value }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        cancellers[id] = nil
        return result
    }
}
