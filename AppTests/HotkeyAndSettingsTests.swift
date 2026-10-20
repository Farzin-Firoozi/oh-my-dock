import Foundation
import OhMyDockCore
import Testing

@MainActor
private final class FakeHotkeyRegistrar: HotkeyRegistering {
    private(set) var registrations: [(UUID, Hotkey?)] = []
    private(set) var removeAllCount = 0
    var handlers: [UUID: @MainActor () -> Void] = [:]

    func applyRegistrations(_ registrations: [ProfileHotkeyRegistration]) {
        self.registrations = registrations.map { ($0.profileID, $0.hotkey) }
        var seen = Set<Hotkey>()
        var handlers: [UUID: @MainActor () -> Void] = [:]
        for registration in registrations {
            guard let hotkey = registration.hotkey else { continue }
            guard seen.insert(hotkey).inserted else { continue }
            handlers[registration.profileID] = registration.onTrigger
        }
        self.handlers = handlers
    }

    func removeAll() {
        removeAllCount += 1
        registrations = []
        handlers = [:]
    }
}

private struct LaunchError: Error, LocalizedError {
    var errorDescription: String? { "launch failed" }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginManaging, @unchecked Sendable {
    var registered = false
    private(set) var calls: [Bool] = []
    var failure: (any Error)?

    func isRegistered() -> Bool { registered }

    func setRegistered(_ registered: Bool) throws {
        calls.append(registered)
        if let failure { throw failure }
        self.registered = registered
    }
}

private actor FakeSettingsLibrary: ProfileLibrary {
    var stored: [Profile]

    init(_ profiles: [Profile] = []) { stored = profiles }

    func profiles() -> [Profile] { stored }

    func save(_ profile: Profile) throws {
        if let index = stored.firstIndex(where: { $0.id == profile.id }) {
            stored[index] = profile
        } else {
            stored.append(profile)
        }
    }

    private(set) var failSetHotkey: (any Error)?

    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound(id) }
        try transform(&stored[index])
        return stored[index]
    }

    func setHotkey(id: UUID, to hotkey: Hotkey?) throws -> Profile {
        if let failSetHotkey { throw failSetHotkey }
        if let hotkey, let other = stored.first(where: { $0.id != id && $0.hotkey == hotkey }) {
            throw ProfileStoreError.hotkeyInUse(profileName: other.name)
        }
        return try update(id: id) { $0.hotkey = hotkey }
    }

    func failHotkeySaves(with error: any Error) { failSetHotkey = error }

    /// Another writer (the editor) renames a profile behind the settings window's back.
    func rename(_ id: UUID, to name: String) {
        if let index = stored.firstIndex(where: { $0.id == id }) { stored[index].name = name }
    }
}

private actor RecordingApplier: ProfileApplying {
    private(set) var applied: [Profile] = []

    func preview(_ profile: Profile, from source: Profile?, trigger: ApplyTrigger) async throws -> ApplyPreview {
        ApplyPreview(
            profileName: profile.name,
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: []
        )
    }

    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        applied.append(profile)
        return .noChanges(
            ApplyPreview(
                profileName: profile.name,
                current: DockState(),
                target: DockState(),
                plan: DockPlan(operations: [], summary: ""),
                skipped: []
            )
        )
    }
}

@MainActor
@Suite struct HotkeyBridgeTests {
    @Test func roundTripsCarbonShortcut() throws {
        let hotkey = Hotkey(keyCode: 18, modifiers: [.command, .option])
        let shortcut = try #require(HotkeyBridge.shortcut(from: hotkey))
        #expect(HotkeyBridge.hotkey(from: shortcut) == hotkey)
    }

    @Test func nilShortcutMapsToNilHotkey() {
        #expect(HotkeyBridge.shortcut(from: nil) == nil)
        #expect(HotkeyBridge.hotkey(from: nil) == nil)
    }
}

@MainActor
@Suite struct HotkeyServiceTests {
    @Test func syncRegistersOneHotkeyPerProfile() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        let work = Profile(name: "Work", hotkey: Hotkey(keyCode: 18, modifiers: [.command]))
        let play = Profile(name: "Play")

        service.sync(profiles: [work, play])

        #expect(registrar.registrations.count == 2)
        #expect(registrar.registrations.contains { $0.0 == work.id && $0.1 == work.hotkey })
        #expect(registrar.registrations.contains { $0.0 == play.id && $0.1 == nil })
    }

    @Test func hotkeyTriggerStartsApply() async throws {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        let applier = RecordingApplier()
        let profile = Profile(name: "Work", hotkey: Hotkey(keyCode: 18, modifiers: [.command]))
        let model = MenuBarViewModel(
            library: FakeSettingsLibrary([profile]),
            dock: FakeDockBackend(state: .init()),
            applier: applier,
            undoer: EmptyUndoer()
        )
        service.attach(menuBar: model)
        service.sync(profiles: [profile])

        registrar.handlers[profile.id]?()
        for _ in 0..<100 {
            if await applier.applied.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(await applier.applied.map(\.id) == [profile.id])
    }

    @Test func hotkeyAppliesTheLatestStoredProfileNotTheRegisteredCopy() async throws {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        let applier = RecordingApplier()
        let registered = Profile(name: "Work", hotkey: Hotkey(keyCode: 18, modifiers: [.command]))
        let library = FakeSettingsLibrary([registered])
        let model = MenuBarViewModel(
            library: library, dock: FakeDockBackend(state: .init()), applier: applier, undoer: EmptyUndoer()
        )
        service.attach(menuBar: model)
        service.sync(profiles: [registered])

        // The editor renames the profile after the hotkey was registered.
        await library.rename(registered.id, to: "Work v2")
        registrar.handlers[registered.id]?()
        for _ in 0..<100 {
            if await applier.applied.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(await applier.applied.map(\.name) == ["Work v2"])
    }

    @Test func duplicateHotkeysRegisterFirstProfileOnly() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        let hotkey = Hotkey(keyCode: 18, modifiers: [.command])
        let first = Profile(name: "Work", hotkey: hotkey)
        let second = Profile(name: "Play", hotkey: hotkey)

        service.sync(profiles: [first, second])

        #expect(registrar.handlers.count == 1)
        #expect(registrar.handlers[first.id] != nil)
        #expect(registrar.handlers[second.id] == nil)
    }
}

@MainActor
@Suite struct SettingsViewModelTests {
    @Test func loadSyncsHotkeysAndLaunchStatus() async {
        let registrar = FakeHotkeyRegistrar()
        let hotkeys = HotkeyService(registrar: registrar)
        let library = FakeSettingsLibrary([Profile(name: "Work", hotkey: Hotkey(keyCode: 1, modifiers: [.shift]))])
        let launch = FakeLaunchAtLoginService()
        launch.registered = true
        let model = SettingsViewModel(library: library, launchAtLogin: launch, hotkeys: hotkeys)

        await model.load()

        #expect(model.launchAtLogin)
        #expect(model.profiles.count == 1)
        #expect(registrar.registrations.count == 1)
    }

    @Test func setHotkeyPersistsAndResyncs() async {
        let registrar = FakeHotkeyRegistrar()
        let hotkeys = HotkeyService(registrar: registrar)
        let profile = Profile(name: "Work")
        let library = FakeSettingsLibrary([profile])
        let model = SettingsViewModel(library: library, launchAtLogin: FakeLaunchAtLoginService(), hotkeys: hotkeys)
        await model.load()

        let hotkey = Hotkey(keyCode: 2, modifiers: [.control])
        await model.setHotkey(for: profile.id, to: hotkey)

        let saved = await library.profiles().first
        #expect(saved?.hotkey == hotkey)
        #expect(registrar.registrations.first?.1 == hotkey)
    }

    @Test func setHotkeyKeepsEditsAnotherWriterMadeSinceLoad() async {
        let hotkeys = HotkeyService(registrar: FakeHotkeyRegistrar())
        let profile = Profile(name: "Work")
        let library = FakeSettingsLibrary([profile])
        let model = SettingsViewModel(library: library, launchAtLogin: FakeLaunchAtLoginService(), hotkeys: hotkeys)
        await model.load()

        await library.rename(profile.id, to: "Renamed in editor")
        await model.setHotkey(for: profile.id, to: Hotkey(keyCode: 2, modifiers: [.control]))

        let saved = await library.profiles().first
        #expect(saved?.name == "Renamed in editor")
        #expect(saved?.hotkey == Hotkey(keyCode: 2, modifiers: [.control]))
        #expect(model.profiles.first?.name == "Renamed in editor")
    }

    @Test func duplicateShortcutIsRejectedAndSurfaced() async {
        let registrar = FakeHotkeyRegistrar()
        let hotkey = Hotkey(keyCode: 2, modifiers: [.control])
        let work = Profile(name: "Work", hotkey: hotkey)
        let play = Profile(name: "Play")
        let library = FakeSettingsLibrary([work, play])
        let model = SettingsViewModel(
            library: library, launchAtLogin: FakeLaunchAtLoginService(), hotkeys: HotkeyService(registrar: registrar)
        )
        await model.load()
        let token = model.hotkeyResetToken

        await model.setHotkey(for: play.id, to: hotkey)

        #expect(model.hotkeyError?.contains("Work") == true)
        #expect(model.hotkeyResetToken == token + 1)
        #expect(await library.profiles().first { $0.id == play.id }?.hotkey == nil)

        await model.setHotkey(for: play.id, to: Hotkey(keyCode: 3, modifiers: [.control]))
        #expect(model.hotkeyError == nil)
    }

    @Test func failedHotkeySaveIsSurfaced() async {
        let profile = Profile(name: "Work")
        let library = FakeSettingsLibrary([profile])
        await library.failHotkeySaves(with: LaunchError())
        let model = SettingsViewModel(
            library: library, launchAtLogin: FakeLaunchAtLoginService(),
            hotkeys: HotkeyService(registrar: FakeHotkeyRegistrar())
        )
        await model.load()

        await model.setHotkey(for: profile.id, to: Hotkey(keyCode: 2, modifiers: [.control]))

        #expect(model.hotkeyError == "launch failed")
    }

    @Test func launchAtLoginToggleUsesService() {
        let launch = FakeLaunchAtLoginService()
        let model = SettingsViewModel(
            library: FakeSettingsLibrary([]),
            launchAtLogin: launch,
            hotkeys: HotkeyService(registrar: FakeHotkeyRegistrar())
        )

        model.setLaunchAtLogin(true)
        #expect(launch.calls == [true])
        #expect(model.launchAtLogin)

        model.setLaunchAtLogin(false)
        #expect(launch.calls == [true, false])
    }

    @Test func launchAtLoginSurfacesErrors() {
        let launch = FakeLaunchAtLoginService()
        launch.failure = LaunchError()
        let model = SettingsViewModel(
            library: FakeSettingsLibrary([]),
            launchAtLogin: launch,
            hotkeys: HotkeyService(registrar: FakeHotkeyRegistrar())
        )

        model.setLaunchAtLogin(true)
        #expect(model.launchAtLoginError == "launch failed")
    }
}

private actor EmptyUndoer: DockUndoing {
    func undoTarget() -> UndoTarget? { nil }
    func undo(expecting id: UUID?) async throws {}
}
