import Foundation

/// Tells interested view models that something outside them changed the snapshot history (a
/// history restore or delete), so the menu bar can refresh its Undo availability. One instance is
/// shared by the menu bar and the history window.
@MainActor
final class DockChangeSignal {
    private var handlers: [@MainActor () -> Void] = []

    /// Handlers live as long as the signal; capture owners weakly.
    func observe(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    func notify() {
        for handler in handlers { handler() }
    }
}
