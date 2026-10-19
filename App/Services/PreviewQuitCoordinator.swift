import Foundation

/// What the quit path needs from the prefs panel: whether a preview is on the Dock, and a way to
/// take it off again (through `DockOperationGate`).
@MainActor
protocol PreviewReverting: AnyObject {
    var isPreviewing: Bool { get }
    func revert() async -> Bool
}

/// Decides what happens to an active Dock preferences preview when the app is asked to quit:
/// revert it first, but never wait for longer than `timeout`. The editor's panel registers itself
/// here; `AppDelegate.applicationShouldTerminate` is a thin caller of `revertForQuit()`.
@MainActor
final class PreviewQuitCoordinator {
    enum Outcome: Equatable {
        /// No preview was active.
        case nothingToRevert
        case reverted
        /// The revert ran and failed; the preview is still on the Dock.
        case failed
        /// The revert (or the operation ahead of it on the gate) took longer than `timeout`.
        case timedOut

        /// True when quitting leaves the Dock as the user had it.
        var leavesDockRestored: Bool { self == .nothingToRevert || self == .reverted }
    }

    private weak var reverter: (any PreviewReverting)?
    private let timeout: Duration

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// The panel that owns the preview. Weak: a closed editor window leaves nothing to revert.
    func register(_ reverter: any PreviewReverting) {
        self.reverter = reverter
    }

    var hasActivePreview: Bool { reverter?.isPreviewing == true }

    /// Reverts the active preview, waiting at most `timeout`. A revert that is still running when
    /// the timeout hits is left to finish on its own.
    func revertForQuit() async -> Outcome {
        guard let reverter, reverter.isPreviewing else { return .nothingToRevert }
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { @MainActor in
                race.finish(await reverter.revert() ? .reverted : .failed)
            }
            Task { @MainActor [timeout] in
                try? await Task.sleep(for: timeout)
                race.finish(.timedOut)
            }
        }
    }

    /// First answer wins; later ones are dropped.
    @MainActor
    private final class Race {
        var continuation: CheckedContinuation<Outcome, Never>?

        func finish(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}
