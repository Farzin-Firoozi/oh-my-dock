import Foundation
import OhMyDockCore

/// Keeps global profile hotkeys in sync with on-disk profiles and applies through the menu bar model.
@MainActor
final class HotkeyService {
    private let registrar: any HotkeyRegistering
    private weak var menuBar: MenuBarViewModel?

    init(registrar: any HotkeyRegistering) {
        self.registrar = registrar
    }

    func attach(menuBar: MenuBarViewModel) {
        self.menuBar = menuBar
    }

    func sync(profiles: [Profile]) {
        let registrations = profiles.map { profile in
            let profileID = profile.id
            return ProfileHotkeyRegistration(profileID: profileID, hotkey: profile.hotkey) { [weak self] in
                // The model applies the latest stored profile, not the copy registered here.
                self?.menuBar?.applyFromHotkey(profileID: profileID)
            }
        }
        registrar.applyRegistrations(registrations)
    }

    func stop() {
        registrar.removeAll()
    }
}
