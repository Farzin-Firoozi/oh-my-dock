import Foundation
import KeyboardShortcuts
import OhMyDockCore

struct ProfileHotkeyRegistration {
    let profileID: UUID
    let hotkey: Hotkey?
    let onTrigger: @MainActor () -> Void
}

/// Registers global hotkeys without tying tests to KeyboardShortcuts or Carbon.
@MainActor
protocol HotkeyRegistering: AnyObject {
    func applyRegistrations(_ registrations: [ProfileHotkeyRegistration])
    func removeAll()
}

@MainActor
final class KeyboardShortcutsRegistrar: HotkeyRegistering {
    private var listeners: [UUID: Task<Void, Never>] = [:]

    func applyRegistrations(_ registrations: [ProfileHotkeyRegistration]) {
        removeAll()
        var seen = Set<Hotkey>()
        for registration in registrations {
            guard let hotkey = registration.hotkey else { continue }
            guard seen.insert(hotkey).inserted else { continue }
            guard let shortcut = HotkeyBridge.shortcut(from: hotkey) else { continue }
            let handler = registration.onTrigger
            listeners[registration.profileID] = Task { @MainActor in
                for await _ in KeyboardShortcuts.events(.keyUp, for: shortcut) {
                    handler()
                }
            }
        }
    }

    func removeAll() {
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
    }
}
