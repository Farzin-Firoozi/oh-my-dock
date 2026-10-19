import Foundation
import Observation
import OhMyDockCore

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var profiles: [Profile] = []
    var launchAtLogin = false
    private(set) var launchAtLoginError: String?

    @ObservationIgnored private let library: any ProfileLibrary
    @ObservationIgnored private let launchAtLoginService: any LaunchAtLoginManaging
    @ObservationIgnored private let hotkeys: HotkeyService

    init(
        library: any ProfileLibrary,
        launchAtLogin: any LaunchAtLoginManaging,
        hotkeys: HotkeyService
    ) {
        self.library = library
        launchAtLoginService = launchAtLogin
        self.hotkeys = hotkeys
    }

    func load() async {
        profiles = await library.profiles()
        launchAtLogin = launchAtLoginService.isRegistered()
        hotkeys.sync(profiles: profiles)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setRegistered(enabled)
            launchAtLogin = launchAtLoginService.isRegistered()
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func setHotkey(for profileID: UUID, to hotkey: Hotkey?) async {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
        profile.hotkey = hotkey
        do {
            try await library.save(profile)
            profiles = await library.profiles()
            hotkeys.sync(profiles: profiles)
        } catch {
            // Leave the recorder binding; the user can try again after fixing validation issues.
        }
    }
}
