import Foundation
import Observation
import OhMyDockCore

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var profiles: [Profile] = []
    var launchAtLogin = false
    private(set) var launchAtLoginError: String?
    /// Why the last shortcut change was refused (a duplicate, a failed save), if it was.
    private(set) var hotkeyError: String?
    /// Bumped when a recorder's shortcut was rejected so its row resets to the stored value.
    private(set) var hotkeyResetToken = 0
    var externalControl: ExternalControlMode = .ask

    @ObservationIgnored private let library: any ProfileLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launchAtLoginService: any LaunchAtLoginManaging
    @ObservationIgnored private let hotkeys: HotkeyService

    init(
        library: any ProfileLibrary,
        launchAtLogin: any LaunchAtLoginManaging,
        hotkeys: HotkeyService,
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        launchAtLoginService = launchAtLogin
        self.hotkeys = hotkeys
        self.defaults = defaults
    }

    func load() async {
        profiles = await library.profiles()
        launchAtLogin = launchAtLoginService.isRegistered()
        externalControl = ExternalControlMode.read(from: defaults)
        hotkeys.sync(profiles: profiles)
    }

    func setExternalControl(_ mode: ExternalControlMode) {
        externalControl = mode
        ExternalControlMode.write(mode, to: defaults)
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

    /// Saves `hotkey` for a profile. The store updates the latest stored profile, so this never
    /// overwrites edits made elsewhere, and refuses a shortcut another profile already uses.
    func setHotkey(for profileID: UUID, to hotkey: Hotkey?) async {
        do {
            try await library.setHotkey(id: profileID, to: hotkey)
            hotkeyError = nil
        } catch {
            hotkeyError = (error as? LocalizedError)?.errorDescription ?? "Could not save the shortcut: \(error)"
            hotkeyResetToken += 1
        }
        profiles = await library.profiles()
        hotkeys.sync(profiles: profiles)
    }
}
