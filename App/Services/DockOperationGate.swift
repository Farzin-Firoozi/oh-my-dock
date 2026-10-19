import Foundation
import Observation

/// Serial async mutex for every operation that mutates the live Dock (apply, hotkey apply, undo,
/// history restore and delete). One instance is shared by the menu bar and the history window, so
/// only one runs at a time and both can show the same busy state.
///
/// Waiters are served in arrival order. A waiter that is cancelled still waits its turn; the
/// operation it runs then sees the cancellation itself.
@MainActor
@Observable
final class DockOperationGate {
    /// Thrown by `requireNoPreview()`; its description is the message shown to the user.
    struct PreviewActiveError: Error, LocalizedError, Equatable {
        var errorDescription: String? { DockOperationGate.previewActiveMessage }
    }

    nonisolated static let previewActiveMessage = "Revert or keep the Dock preferences preview first."

    /// Description of the operation holding the gate, e.g. "Restoring a snapshot".
    private(set) var current: String?

    var isBusy: Bool { current != nil }

    /// True while a Dock preferences preview is on the Dock. Set by the prefs panel. Apply, undo
    /// and history restore refuse to start meanwhile, because their pre-images and verification
    /// would treat the previewed values as the Dock's real state and a later revert would undo them.
    var isPreviewActive = false

    /// Throws `PreviewActiveError` while a preview is active. Call at the start of an operation
    /// and again inside `run` (a preview can begin while the operation waits for its turn).
    func requireNoPreview() throws {
        if isPreviewActive { throw PreviewActiveError() }
    }

    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `operation` once every earlier operation has finished. `label` is shown as the busy state.
    func run<T>(_ label: String, _ operation: () async throws -> T) async rethrows -> T {
        await acquire(label)
        defer { release() }
        return try await operation()
    }

    private func acquire(_ label: String) async {
        if current == nil {
            current = label
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // `release()` handed the gate over without clearing it; claim it for this operation.
        current = label
    }

    private func release() {
        if waiters.isEmpty {
            current = nil
        } else {
            waiters.removeFirst().resume()
        }
    }
}
