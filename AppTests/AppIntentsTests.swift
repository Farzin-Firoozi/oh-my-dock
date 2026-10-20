import AppIntents
import Foundation
import OhMyDockCore
import Testing

@MainActor
private final class FakeCommandCenter: ExternalCommandRunning {
    private(set) var requests: [ExternalRequest] = []
    var results: [ExternalResult] = []
    private var defaultResult: ExternalResult

    init(defaultResult: ExternalResult) {
        self.defaultResult = defaultResult
    }

    func run(_ request: ExternalRequest) async -> ExternalResult {
        requests.append(request)
        if !results.isEmpty { return results.removeFirst() }
        return defaultResult
    }
}

@MainActor
private final class FakeIntentConfirm: IntentApplyConfirming, @unchecked Sendable {
    var applyAnswers: [ApplyConfirmResult] = [.accepted]
    var saveAnswers: [Bool] = [true]
    private(set) var applyPreviews: [ApplyPreview] = []
    private(set) var saveCalls: [(name: String, overwriting: Bool)] = []

    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult {
        applyPreviews.append(preview)
        return applyAnswers.isEmpty ? .accepted : applyAnswers.removeFirst()
    }

    func confirmSave(name: String, overwriting: Bool) async -> Bool {
        saveCalls.append((name, overwriting))
        return saveAnswers.isEmpty ? true : saveAnswers.removeFirst()
    }
}

@MainActor
private final class FakePresenter: ConfirmationPresenting {
    private(set) var presented: [MenuBarViewModel.Confirmation] = []
    private(set) var dismissCount = 0
    private(set) var model: SwitchConfirmationViewModel?

    func present(_ confirmation: MenuBarViewModel.Confirmation, model: SwitchConfirmationViewModel) {
        presented.append(confirmation)
        self.model = model
    }

    func dismiss() { dismissCount += 1 }
    func presentNotice(_ banner: MenuBarViewModel.Banner) {}
    func presentOutcome(_ model: SwitchOutcomeViewModel) {}
    func dismissOutcome() {}

    func userAnswers(_ accepted: Bool) {
        if accepted { model?.switchAction() } else { model?.cancelAction() }
    }
}

private final class BoolBox: @unchecked Sendable {
    var value = false
}

private func makeApplyPreview(
    profileName: String = "Test",
    confirmationRequired: Bool = false
) -> ApplyPreview {
    let dummyState = DockState()
    let quitApps: [RunningAppInfo] = confirmationRequired
        ? [RunningAppInfo(processIdentifier: 1234, bundleId: "com.test.app", name: "TestApp")]
        : []
    return ApplyPreview(
        profileName: profileName,
        current: dummyState,
        target: dummyState,
        plan: DiffEngine.plan(from: dummyState, to: dummyState),
        skipped: [],
        switchPlan: SwitchPlan(
            scope: .previousProfileApps,
            willQuit: quitApps,
            willLaunch: []
        )
    )
}

extension ExternalPayload {
    fileprivate static func empty() -> ExternalPayload {
        try! JSONDecoder().decode(ExternalPayload.self, from: Data("{}".utf8))
    }
}

extension ExternalPayload.ListProfileEntry {
    fileprivate static func make(
        id: String,
        name: String,
        appCount: Int = 0,
        otherCount: Int = 0,
        hasPrefs: Bool = false,
        quitScope: String = "none"
    ) -> ExternalPayload.ListProfileEntry {
        let json = """
        {"id": "\(id)", "name": "\(name)", "appCount": \(appCount), "otherCount": \(otherCount), "hasPrefs": \(hasPrefs), "quitScope": "\(quitScope)"}
        """
        return try! JSONDecoder().decode(ExternalPayload.ListProfileEntry.self, from: Data(json.utf8))
    }
}

@MainActor
private func makeDependencies(
    center: FakeCommandCenter,
    confirm: FakeIntentConfirm = FakeIntentConfirm(),
    gate: DockOperationGate = DockOperationGate(),
    profiles: [Profile] = []
) -> IntentDependencies {
    IntentDependencies(
        commandCenter: center,
        gate: gate,
        confirm: confirm,
        profileNameExists: { name in
            profiles.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        },
        fetchProfiles: { profiles }
    )
}

@Suite(.serialized)
@MainActor
struct AppIntentsTests {

    // MARK: - ProfileEntity & EntityQuery

    @Test func profileEntityInitializesCorrectly() {
        let id = UUID()
        let entity = ProfileEntity(id: id, name: "Coding")
        #expect(entity.id == id.uuidString)
        #expect(entity.name == "Coding")
    }

    @Test func profileEntityQueryFindsById() async throws {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "show", ok: true)))
        let id = UUID()
        let profile = Profile(id: id, name: "Alpha")
        let deps = makeDependencies(center: center, profiles: [profile])
        let query = ProfileEntityQuery(dependencies: deps)

        let found = try await query.entities(for: [id.uuidString])
        #expect(found.count == 1)
        #expect(found.first?.name == "Alpha")
    }

    @Test func profileEntityQuerySuggestsAllSortedByNameThenId() async throws {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "list", ok: true)))
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let p1 = Profile(id: id1, name: "Zeta")
        let p2 = Profile(id: id2, name: "alpha")
        let p3 = Profile(id: id3, name: "Beta")
        let deps = makeDependencies(center: center, profiles: [p1, p2, p3])
        let query = ProfileEntityQuery(dependencies: deps)

        let suggested = try await query.suggestedEntities()
        #expect(suggested.map(\.name) == ["alpha", "Beta", "Zeta"])
    }

    @Test func profileEntityQueryMatchesCaseInsensitiveSubstring() async throws {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "list", ok: true)))
        let p1 = Profile(id: UUID(), name: "Coding Work")
        let p2 = Profile(id: UUID(), name: "Personal Workout")
        let p3 = Profile(id: UUID(), name: "Gaming")
        let deps = makeDependencies(center: center, profiles: [p1, p2, p3])
        let query = ProfileEntityQuery(dependencies: deps)

        let matches = try await query.entities(matching: "work")
        #expect(matches.count == 2)
        #expect(matches.map(\.name).sorted() == ["Coding Work", "Personal Workout"])
    }

    // MARK: - ApplyProfileIntent

    @Test func applyProfileIntentAppliesWithSourceIntent() async throws {
        let profileId = UUID()
        let entity = ProfileEntity(id: profileId, name: "Design")

        var payload = ExternalPayload.empty()
        payload.status = "applied"
        let successResult = ExternalResult(
            exitCode: 0,
            message: "Applied “Design”.",
            envelope: ExternalEnvelope(command: "apply", ok: true, result: payload)
        )
        let center = FakeCommandCenter(defaultResult: successResult)
        let confirm = FakeIntentConfirm()
        let deps = makeDependencies(center: center, confirm: confirm)

        let intent = ApplyProfileIntent(profile: entity, dependencies: deps)
        let result = try await intent.perform()

        #expect(result.value?.id == profileId.uuidString)
        #expect(center.requests.count == 1)
        let request = center.requests[0]
        #expect(request.source == ControlSource.intent)
        if case let .apply(profileArg, dryRun, quitScope, keepRunning) = request.command {
            #expect(profileArg == profileId.uuidString)
            #expect(!dryRun)
            #expect(quitScope == nil)
            #expect(keepRunning.isEmpty)
        } else {
            Issue.record("Expected apply command")
        }
    }

    @Test func applyProfileIntentHandlesAlreadyOnDock() async throws {
        let entity = ProfileEntity(id: UUID(), name: "Work")
        var payload = ExternalPayload.empty()
        payload.status = "noChanges"
        let result = ExternalResult(
            exitCode: 0,
            message: "“Work” is already on the Dock.",
            envelope: ExternalEnvelope(command: "apply", ok: true, result: payload)
        )
        let center = FakeCommandCenter(defaultResult: result)
        let deps = makeDependencies(center: center)

        let intent = ApplyProfileIntent(profile: entity, dependencies: deps)
        let performResult = try await intent.perform()

        #expect(performResult.value?.name == "Work")
    }

    @Test func applyProfileIntentHandlesCancelledInSheet() async throws {
        let entity = ProfileEntity(id: UUID(), name: "Work")
        var payload = ExternalPayload.empty()
        payload.status = "cancelled"
        let result = ExternalResult(
            exitCode: 0,
            message: "Cancelled.",
            envelope: ExternalEnvelope(command: "apply", ok: true, result: payload)
        )
        let center = FakeCommandCenter(defaultResult: result)
        let deps = makeDependencies(center: center)

        let intent = ApplyProfileIntent(profile: entity, dependencies: deps)
        let performResult = try await intent.perform()

        #expect(performResult.value?.name == "Work")
    }

    @Test func applyProfileIntentRefusesWhenPreviewActive() async {
        let entity = ProfileEntity(id: UUID(), name: "Work")
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "apply", ok: true)))
        let gate = DockOperationGate()
        gate.isPreviewActive = true
        let deps = makeDependencies(center: center, gate: gate)

        let intent = ApplyProfileIntent(profile: entity, dependencies: deps)
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
        #expect(center.requests.isEmpty)
    }

    @Test func applyProfileIntentFailsWhenCommandCenterReturnsLocked() async {
        let entity = ProfileEntity(id: UUID(), name: "Work")
        let errorResult = ExternalResult(
            exitCode: 7,
            message: "Another oh-my-dock operation is in progress.",
            envelope: ExternalEnvelope(
                command: "apply",
                ok: false,
                error: ExternalErrorInfo(code: "locked", exitCode: 7, message: "locked", reason: "operationLock")
            )
        )
        let center = FakeCommandCenter(defaultResult: errorResult)
        let deps = makeDependencies(center: center)

        let intent = ApplyProfileIntent(profile: entity, dependencies: deps)
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
    }

    // MARK: - SaveCurrentDockIntent

    @Test func saveCurrentDockIntentNewNameSavesWithoutConfirmationSheet() async throws {
        let saveResult = ExternalResult(
            exitCode: 0,
            message: "Saved “Dev”.",
            envelope: ExternalEnvelope(command: "save", ok: true)
        )
        let center = FakeCommandCenter(defaultResult: saveResult)
        let confirm = FakeIntentConfirm()
        let deps = makeDependencies(center: center, confirm: confirm, profiles: [])

        let intent = SaveCurrentDockIntent(name: "Dev", overwrite: false, dependencies: deps)
        _ = try await intent.perform()

        #expect(confirm.saveCalls.isEmpty)
        #expect(center.requests.count == 1)
        let req = center.requests[0]
        #expect(req.source == ControlSource.intent)
        if case let .save(name, force, includePrefs) = req.command {
            #expect(name == "Dev")
            #expect(!force)
            #expect(!includePrefs)
        } else {
            Issue.record("Expected save command")
        }
    }

    @Test func saveCurrentDockIntentExistingNameWithoutOverwriteFailsConflict() async {
        let existing = Profile(id: UUID(), name: "Dev")
        let conflictResult = ExternalResult(
            exitCode: 6,
            message: "A profile named “Dev” already exists.",
            envelope: ExternalEnvelope(
                command: "save",
                ok: false,
                error: ExternalErrorInfo(code: "conflict", exitCode: 6, message: "exists", reason: "nameInUse")
            )
        )
        let center = FakeCommandCenter(defaultResult: conflictResult)
        let confirm = FakeIntentConfirm()
        let deps = makeDependencies(center: center, confirm: confirm, profiles: [existing])

        let intent = SaveCurrentDockIntent(name: "Dev", overwrite: false, dependencies: deps)
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
        #expect(confirm.saveCalls.isEmpty)
    }

    @Test func saveCurrentDockIntentExistingNameWithOverwriteShowsConfirmation() async throws {
        let existing = Profile(id: UUID(), name: "Dev")
        let saveResult = ExternalResult(
            exitCode: 0,
            message: "Saved “Dev”.",
            envelope: ExternalEnvelope(command: "save", ok: true)
        )
        let center = FakeCommandCenter(defaultResult: saveResult)
        let confirm = FakeIntentConfirm()
        confirm.saveAnswers = [true]
        let deps = makeDependencies(center: center, confirm: confirm, profiles: [existing])

        let intent = SaveCurrentDockIntent(name: "Dev", overwrite: true, dependencies: deps)
        _ = try await intent.perform()

        #expect(confirm.saveCalls.count == 1)
        #expect(confirm.saveCalls[0].name == "Dev")
        #expect(confirm.saveCalls[0].overwriting == true)
        #expect(center.requests.count == 1)
        if case let .save(name, force, includePrefs) = center.requests[0].command {
            #expect(name == "Dev")
            #expect(force == true)
            #expect(!includePrefs)
        } else {
            Issue.record("Expected force save command")
        }
    }

    @Test func saveCurrentDockIntentExistingNameCancelledInConfirmation() async throws {
        let existing = Profile(id: UUID(), name: "Dev")
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "save", ok: true)))
        let confirm = FakeIntentConfirm()
        confirm.saveAnswers = [false]
        let deps = makeDependencies(center: center, confirm: confirm, profiles: [existing])

        let intent = SaveCurrentDockIntent(name: "Dev", overwrite: true, dependencies: deps)
        _ = try await intent.perform()

        #expect(confirm.saveCalls.count == 1)
        #expect(center.requests.isEmpty)
    }

    @Test func saveCurrentDockIntentRefusesEmptyName() async {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "save", ok: true)))
        let deps = makeDependencies(center: center)

        let intent = SaveCurrentDockIntent(name: "   ", dependencies: deps)
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
        #expect(center.requests.isEmpty)
    }

    @Test func saveCurrentDockIntentRefusesPreviewActive() async {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "save", ok: true)))
        let gate = DockOperationGate()
        gate.isPreviewActive = true
        let deps = makeDependencies(center: center, gate: gate)

        let intent = SaveCurrentDockIntent(name: "Dev", dependencies: deps)
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
        #expect(center.requests.isEmpty)
    }

    // MARK: - ListProfilesIntent

    @Test func listProfilesIntentReturnsEntitiesAndCountDialog() async throws {
        let id1 = UUID()
        let id2 = UUID()
        var payload = ExternalPayload.empty()
        payload.profiles = [
            ExternalPayload.ListProfileEntry.make(id: id1.uuidString, name: "Alpha", appCount: 5),
            ExternalPayload.ListProfileEntry.make(id: id2.uuidString, name: "Beta", appCount: 8)
        ]
        let listResult = ExternalResult(
            exitCode: 0,
            message: "Listed 2 profile(s).",
            envelope: ExternalEnvelope(command: "list", ok: true, result: payload)
        )
        let center = FakeCommandCenter(defaultResult: listResult)
        let deps = makeDependencies(center: center)

        let intent = ListProfilesIntent(dependencies: deps)
        let result = try await intent.perform()

        #expect(result.value?.count == 2)
        #expect(result.value?[0].name == "Alpha")
        #expect(result.value?[1].name == "Beta")
        #expect(center.requests.count == 1)
        #expect(center.requests[0].source == ControlSource.intent)
    }

    // MARK: - UndoLastChangeIntent

    @Test func undoLastChangeIntentCallsConfirmationAndPerformsUndo() async throws {
        let undoResult = ExternalResult(
            exitCode: 0,
            message: "Undo complete.",
            envelope: ExternalEnvelope(command: "undo", ok: true)
        )
        let center = FakeCommandCenter(defaultResult: undoResult)
        let deps = makeDependencies(center: center)

        let confirmedPrompt = BoolBox()
        let intent = UndoLastChangeIntent(
            dependencies: deps,
            confirmUndoAction: {
                confirmedPrompt.value = true
            }
        )
        _ = try await intent.perform()

        #expect(confirmedPrompt.value)
        #expect(center.requests.count == 1)
        let req = center.requests[0]
        #expect(req.source == ControlSource.intent)
        if case .undo = req.command {
            // Success
        } else {
            Issue.record("Expected undo command")
        }
    }

    @Test func undoLastChangeIntentAbortsWhenConfirmationCancelled() async {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "undo", ok: true)))
        let deps = makeDependencies(center: center)

        let intent = UndoLastChangeIntent(
            dependencies: deps,
            confirmUndoAction: {
                throw CancellationError()
            }
        )
        await #expect(throws: CancellationError.self) {
            try await intent.perform()
        }
        #expect(center.requests.isEmpty)
    }

    @Test func undoLastChangeIntentNothingToUndoFails() async {
        let nothingResult = ExternalResult(
            exitCode: 3,
            message: "There is nothing to undo.",
            envelope: ExternalEnvelope(
                command: "undo",
                ok: false,
                error: ExternalErrorInfo(code: "nothingToUndo", exitCode: 3, message: "There is nothing to undo.")
            )
        )
        let center = FakeCommandCenter(defaultResult: nothingResult)
        let deps = makeDependencies(center: center)

        let intent = UndoLastChangeIntent(
            dependencies: deps,
            confirmUndoAction: {}
        )
        await #expect(throws: IntentError.nothingToUndo) {
            try await intent.perform()
        }
    }

    @Test func undoLastChangeIntentRefusesPreviewActive() async {
        let center = FakeCommandCenter(defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "undo", ok: true)))
        let gate = DockOperationGate()
        gate.isPreviewActive = true
        let deps = makeDependencies(center: center, gate: gate)

        let intent = UndoLastChangeIntent(
            dependencies: deps,
            confirmUndoAction: {}
        )
        await #expect(throws: IntentError.self) {
            try await intent.perform()
        }
        #expect(center.requests.isEmpty)
    }

    // MARK: - Confirmation Policy & Service

    @Test func confirmationServiceShowsSheetOnlyWhenConfirmationRequired() async {
        let presenter = FakePresenter()
        let service = IntentApplyConfirmationService(presenter: presenter)

        let noConfirmPreview = makeApplyPreview(confirmationRequired: false)
        let result1 = await service.confirmApply(preview: noConfirmPreview)
        #expect(result1.accepted)
        #expect(presenter.presented.isEmpty)

        let confirmPreview = makeApplyPreview(confirmationRequired: true)
        Task { @MainActor in
            for _ in 0..<100 {
                if !presenter.presented.isEmpty {
                    presenter.userAnswers(true)
                    return
                }
                await Task.yield()
            }
        }
        let result2 = await service.confirmApply(preview: confirmPreview)
        #expect(result2.accepted)
        #expect(presenter.presented.count == 1)
        #expect(presenter.dismissCount == 1)
    }

    // MARK: - External Control Setting

    @Test func intentsAreNotGatedByExternalControlSetting() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: ExternalControlMode.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: ExternalControlMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ExternalControlMode.defaultsKey)
            }
        }

        ExternalControlMode.write(.denied, to: defaults)
        #expect(ExternalControlMode.read(from: defaults) == .denied)

        let center = FakeCommandCenter(
            defaultResult: ExternalResult(exitCode: 0, message: "OK", envelope: ExternalEnvelope(command: "list", ok: true))
        )
        let deps = makeDependencies(center: center)
        let intent = ListProfilesIntent(dependencies: deps)
        let result = try await intent.perform()
        #expect(result.value?.isEmpty == true)
        #expect(center.requests.count == 1)
        #expect(center.requests[0].source == ControlSource.intent)
    }

    // MARK: - Shortcuts Provider

    @Test func shortcutsProviderRegistersPhrases() {
        let shortcuts = OhMyDockShortcuts.appShortcuts
        #expect(shortcuts.count == 3)
    }
}
