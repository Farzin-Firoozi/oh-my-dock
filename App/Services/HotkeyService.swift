import Foundation
import OhMyDockCore

/// Keeps global profile hotkeys in sync with on-disk profiles and applies through the menu bar model.
@MainActor
final class HotkeyService {
    private let registrar: any HotkeyRegistering
    private weak var menuBar: MenuBarViewModel?
    private var profilesByID: [UUID: Profile] = [:]

    init(registrar: any HotkeyRegistering) {
        self.registrar = registrar
    }

    func attach(menuBar: MenuBarViewModel) {
        self.menuBar = menuBar
    }

    func sync(profiles: [Profile]) {
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let registrations = profiles.map { profile in
            let profileID = profile.id
            return ProfileHotkeyRegistration(profileID: profileID, hotkey: profile.hotkey) { [weak self] in
                guard let self, let profile = self.profilesByID[profileID] else { return }
                self.menuBar?.apply(profile)
            }
        }
        registrar.applyRegistrations(registrations)
    }

    func stop() {
        registrar.removeAll()
        profilesByID = [:]
    }
}
