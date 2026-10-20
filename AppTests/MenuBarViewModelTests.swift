import Foundation
import OhMyDockCore
import Testing

// MARK: - Fakes (no live Dock, no real stores)

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

private actor FakeLibrary: ProfileLibrary {
    private(set) var stored: [Profile]
    private var failSave = false

    init(_ profiles: [Profile] = []) { stored = profiles }

    func profiles() -> [Profile] { stored }

    func save(_ profile: Profile) throws {
        if failSave { throw Boom() }
        stored.append(profile)
    }

    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound(id) }
        try transform(&stored[index])
        return stored[index]
    }

    func setHotkey(id: UUID, to hotkey: Hotkey?) throws -> Profile {
        try update(id: id) { $0.hotkey = hotkey }
    }

    func failSaves() { failSave = true }
}

/// Scripted applier: records what it was asked and plays back `script`.
private actor FakeApplier: ProfileApplying {
    typealias Script = @Sendable (Profile, (@Sendable (ApplyPreview) async -> Bool)?) async throws -> ApplyResult

    private(set) var applied: [Profile] = []
    private(set) var triggers: [ApplyTrigger] = []
    private(set) var sources: [String?] = []
    /// What the user's answer was, exclusions included, for every question asked.
    private(set) var answers: [ApplyConfirmResult] = []
    private var script: Script

    init(_ script: @escaping Script) { self.script = script }

    func record(trigger: ApplyTrigger, source: String?) {
        triggers.append(trigger)
        sources.append(source)
    }

    func record(answer: ApplyConfirmResult) { answers.append(answer) }

    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        applied.append(profile)
        return try await script(profile, confirm)
    }
}

extension FakeApplier {
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        record(trigger: trigger, source: source?.name)
        return try await apply(profile, confirm: confirm)
    }

    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult {
        record(trigger: trigger, source: source?.name)
        let boolConfirm: (@Sendable (ApplyPreview) async -> Bool)?
        if let confirm {
            boolConfirm = { (preview: ApplyPreview) async -> Bool in
                let res = await confirm(preview)
                await self.record(answer: res)
                return res.accepted
            }
        } else {
            boolConfirm = nil
        }
        return try await apply(profile, confirm: boolConfirm)
    }
}

private actor FakeUndoer: DockUndoing {
    private var target: UndoTarget?
    private(set) var undone: [UUID?] = []
    private var failure: (any Error)?

    init(target: UndoTarget? = nil) { self.target = target }

    func undoTarget() -> UndoTarget? { target }

    func undo(expecting id: UUID?) throws {
        if let failure { throw failure }
        guard let target else { throw UndoError.nothingToUndo }
        if let id, id != target.id { throw UndoError.targetChanged }
        undone.append(target.id)
        self.target = nil
    }

    func setTarget(_ target: UndoTarget?) { self.target = target }

    func fail(with error: any Error) { failure = error }
}

/// A library whose first `profiles()` call waits until `releaseFirst()` and then returns the
/// stale (empty) list; later calls return `fresh` immediately.
private actor SlowFirstLibrary: ProfileLibrary {
    private let fresh: [Profile]
    private(set) var calls = 0
    private var firstCall: CheckedContinuation<Void, Never>?
    private var released = false

    init(fresh: [Profile]) { self.fresh = fresh }

    func profiles() async -> [Profile] {
        calls += 1
        guard calls == 1 else { return fresh }
        if !released { await withCheckedContinuation { firstCall = $0 } }
        return []
    }

    func releaseFirst() {
        released = true
        firstCall?.resume()
        firstCall = nil
    }

    func save(_ profile: Profile) throws {}
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        throw ProfileStoreError.profileNotFound(id)
    }
    func setHotkey(id: UUID, to hotkey: Hotkey?) throws -> Profile {
        throw ProfileStoreError.profileNotFound(id)
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

    /// The user clicks Switch (`true`) or Cancel in the panel.
    func userAnswers(_ accepted: Bool) {
        if accepted { model?.switchAction() } else { model?.cancelAction() }
    }
}

// MARK: - Helpers

private func app(_ id: String, _ name: String) -> DockItem {
    .app(AppRef(bundleId: id, name: name, path: "/Applications/\(name).app"))
}

private let safari = app("com.apple.Safari", "Safari")
private let notes = app("com.apple.Notes", "Notes")

private func profile(_ name: String, apps: [DockItem] = []) -> Profile {
    Profile(name: name, apps: apps)
}

private func preview(
    _ name: String,
    skipped: [SkippedItem] = [],
    clearsRecentApps: Bool = false
) -> ApplyPreview {
    ApplyPreview(
        profileName: name,
        current: DockState(),
        target: DockState(),
        plan: DockPlan(operations: [], summary: ""),
        skipped: skipped,
        clearsRecentApps: clearsRecentApps
    )
}

private func report() -> ApplyReport {
    ApplyReport(plan: DockPlan(operations: [], summary: ""), snapshotID: UUID(), skipped: [], clearsRecentApps: false, restarted: true)
}

private let noApply = FakeApplier { _, _ in .cancelled(rolledBack: false) }

@MainActor
private func makeModel(
    library: FakeLibrary = FakeLibrary(),
    dock: FakeDockBackend = FakeDockBackend(),
    applier: FakeApplier = noApply,
    undoer: FakeUndoer = FakeUndoer(),
    bootstrap: (@Sendable () async throws -> Void)? = nil,
    activeRecord: any ActiveProfileRecording = InMemoryActiveProfileRecord()
) -> MenuBarViewModel {
    MenuBarViewModel(
        library: library, dock: dock, applier: applier, undoer: undoer,
        bootstrap: bootstrap, activeRecord: activeRecord
    )
}

/// Waits (bounded) for `condition` to hold on the main actor.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - Tests

@MainActor
@Suite struct MenuBarViewModelTests {
    // MARK: Profile list & active profile

    @Test func refreshLoadsProfilesAndMarksTheMatchingOneActive() async {
        let work = profile("Work", apps: [safari])
        let home = profile("Home", apps: [notes])
        let model = makeModel(
            library: FakeLibrary([work, home]),
            dock: FakeDockBackend(state: DockState(apps: [notes]))
        )

        await model.refresh()

        #expect(model.profiles == [work, home])
        #expect(model.activeProfileID == home.id)
    }

    @Test func noProfileIsActiveWhenNoneMatchesTheDock() async {
        let model = makeModel(
            library: FakeLibrary([profile("Work", apps: [safari])]),
            dock: FakeDockBackend(state: DockState(apps: [notes]))
        )
        await model.refresh()
        #expect(model.activeProfileID == nil)
    }

    private func link(_ label: String?) -> DockItem {
        .url(URLItem(url: URL(string: "https://example.com")!, label: label))
    }

    @Test func persistedActiveProfileWinsAfterRelaunchWhenTheDockStillMatches() async {
        // Both describe the same Dock; plain sorts first and would win a fuzzy match.
        let plain = profile("A plain", apps: [])
        var plainProfile = plain
        plainProfile.others = [link(nil)]
        var labelled = profile("B labelled")
        labelled.others = [link("Example")]
        let dock = FakeDockBackend(state: DockState(others: [link("Example")]))
        let record = InMemoryActiveProfileRecord(plainProfile.id)
        let model = makeModel(library: FakeLibrary([plainProfile, labelled]), dock: dock, activeRecord: record)

        await model.refresh()

        #expect(model.activeProfileID == plainProfile.id)
    }

    @Test func persistedActiveProfileIsIgnoredWhenTheDockNoLongerMatchesIt() async {
        let work = profile("Work", apps: [safari])
        let home = profile("Home", apps: [notes])
        let model = makeModel(
            library: FakeLibrary([work, home]),
            dock: FakeDockBackend(state: DockState(apps: [notes])),
            activeRecord: InMemoryActiveProfileRecord(work.id)
        )

        await model.refresh()

        #expect(model.activeProfileID == home.id)
    }

    @Test func exactMatchBeatsALooseOneWhenNothingWasRecorded() async {
        var loose = profile("A loose")
        loose.others = [link(nil)]
        var exact = profile("B exact")
        exact.others = [link("Example")]
        let model = makeModel(
            library: FakeLibrary([loose, exact]),
            dock: FakeDockBackend(state: DockState(others: [link("Example")]))
        )

        await model.refresh()

        #expect(model.activeProfileID == exact.id)
    }

    @Test func applyingAProfileRecordsItAndUndoForgetsIt() async {
        let work = profile("Work", apps: [safari])
        let record = InMemoryActiveProfileRecord()
        let target = UndoTarget(id: UUID(), createdAt: Date(), summary: "Before applying profile Work")
        let applier = FakeApplier { _, _ in .applied(report()) }
        let model = makeModel(
            library: FakeLibrary([work]), applier: applier, undoer: FakeUndoer(target: target), activeRecord: record
        )
        await model.refresh()

        await model.performApply(work)
        #expect(record.load() == work.id)

        await model.performUndo()
        #expect(record.load() == nil)
    }

    @Test func fileRecordRoundTripsTheProfileID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-active-\(UUID().uuidString)/active-profile.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = FileActiveProfileRecord(url: url)
        #expect(record.load() == nil)

        let id = UUID()
        record.save(id)
        #expect(FileActiveProfileRecord(url: url).load() == id)

        record.save(nil)
        #expect(record.load() == nil)
    }

    @Test func anOlderRefreshCannotOverwriteANewerOne() async {
        let work = profile("Work", apps: [safari])
        let library = SlowFirstLibrary(fresh: [work])
        let model = MenuBarViewModel(
            library: library, dock: FakeDockBackend(state: DockState(apps: [safari])),
            applier: noApply, undoer: FakeUndoer()
        )

        let older = Task { await model.refresh() }
        while await library.calls < 1 { await Task.yield() }

        await model.refresh() // the newer refresh finishes first
        #expect(model.profiles == [work])

        await library.releaseFirst()
        await older.value
        #expect(model.profiles == [work])
        #expect(model.activeProfileID == work.id)
    }

    @Test func lastAppliedProfileWinsWhenSeveralMatch() async {
        let first = profile("A", apps: [safari])
        let second = profile("B", apps: [safari])
        let applier = FakeApplier { _, _ in .noChanges(preview("B")) }
        let model = makeModel(
            library: FakeLibrary([first, second]),
            dock: FakeDockBackend(state: DockState(apps: [safari])),
            applier: applier
        )

        await model.performApply(second)

        #expect(model.activeProfileID == second.id)
    }

    @Test func startRunsTheBootstrapBeforeLoadingProfiles() async {
        let library = FakeLibrary()
        let model = makeModel(library: library, bootstrap: {
            try await library.save(profile("Default"))
        })

        await model.start()

        #expect(model.profiles.map(\.name) == ["Default"])
    }

    @Test func aFailingBootstrapIsShownAndTheListStillLoads() async {
        let model = makeModel(library: FakeLibrary([profile("Work")]), bootstrap: { throw Boom() })

        await model.start()

        #expect(model.banner?.kind == .failure)
        #expect(model.banner?.message.contains("boom") == true)
        #expect(model.profiles.count == 1)
    }

    // MARK: Apply

    @Test func applyingReportsSuccessAndRefreshesTheActiveProfile() async {
        let work = profile("Work", apps: [safari])
        let dock = FakeDockBackend()
        let applier = FakeApplier { profile, _ in
            await dock.setState(profile.dockState)
            return .applied(report())
        }
        let model = makeModel(library: FakeLibrary([work]), dock: dock, applier: applier)

        await model.performApply(work)

        #expect(model.banner == .init(kind: .success, message: "Applied “Work”."))
        #expect(model.activeProfileID == work.id)
        #expect(model.activity == nil)
    }

    @Test func applyingAnAlreadyActiveProfileSaysSo() async {
        let work = profile("Work")
        let model = makeModel(applier: FakeApplier { _, _ in .noChanges(preview("Work")) })

        await model.performApply(work)

        #expect(model.banner?.kind == .success)
        #expect(model.banner?.message == "“Work” is already on the Dock.")
    }

    @Test func applyErrorsAreShown() async {
        let applier = FakeApplier { _, _ in throw ApplyError.dockChanged }
        let model = makeModel(applier: applier)

        await model.performApply(profile("Work"))

        #expect(model.banner?.kind == .failure)
        #expect(model.banner?.message == ApplyError.dockChanged.errorDescription)
        #expect(model.activity == nil)
    }

    @Test func applyIsRefusedWhileAnotherOperationRuns() async {
        let gate = AsyncGate()
        let applier = FakeApplier { _, _ in
            await gate.wait()
            return .applied(report())
        }
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.activity == .applying(profileName: "Work") })
        model.apply(profile("Other"))
        await gate.open()
        #expect(await eventually { model.activity == nil })

        #expect(await applier.applied.map(\.name) == ["Work"])
    }

    // MARK: Confirmation & cancel

    private static let missing = SkippedItem(
        section: .apps,
        index: 0,
        app: AppRef(bundleId: "com.gone.App", name: "Gone")
    )

    @Test func missingAppsAskForConfirmationAndApplyOnceAccepted() async {
        let work = profile("Work")
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(preview("Work", skipped: [Self.missing], clearsRecentApps: true)) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
        let model = makeModel(applier: applier)

        model.apply(work)
        #expect(await eventually { model.confirmation != nil })
        #expect(model.confirmation == .init(profileName: "Work", skippedApps: ["Gone"], clearsRecentApps: true))

        model.resolveConfirmation(.accepted)
        #expect(await eventually { model.activity == nil })

        #expect(model.confirmation == nil)
        #expect(model.banner?.message.hasPrefix("Applied “Work”") == true)
    }

    private static func quittingPreview(_ name: String) -> ApplyPreview {
        let slack = RunningAppInfo(processIdentifier: 7, bundleId: "com.example.slack", name: "Slack")
        return ApplyPreview(
            profileName: name,
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: [],
            switchPlan: SwitchPlan(
                scope: .previousProfileApps,
                willQuit: [slack],
                willLaunch: [LaunchRequest(bundleId: "com.example.figma", name: "Figma")]
            )
        )
    }

    @Test func aSwitchThatQuitsAppsAsksForConfirmationAndReportsWhatHappened() async {
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(Self.quittingPreview("Work")) ?? false
            guard accepted else { return .cancelled(rolledBack: false) }
            let slack = RunningAppInfo(processIdentifier: 7, bundleId: "com.example.slack", name: "Slack")
            return .applied(ApplyReport(
                plan: DockPlan(operations: [], summary: ""), snapshotID: UUID(), skipped: [],
                clearsRecentApps: false, restarted: true,
                switchOutcome: SwitchOutcome(quits: [QuitResult(app: slack, status: .quit)])
            ))
        }
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })
        #expect(model.confirmation?.quitApps == ["Slack"])
        #expect(model.confirmation?.launchApps == ["Figma"])

        model.resolveConfirmation(.accepted)
        #expect(await eventually { model.activity == nil })
        let message = model.banner?.message ?? ""
        #expect(message.hasPrefix("Applied “Work”."))
        #expect(message.contains("Quit 1"))
        #expect(message.contains("quit apps are not reopened"))
    }

    /// Slack and Figma would both be quit; the user keeps Slack running somewhere in the UI.
    private static func twoAppQuittingPreview(_ name: String) -> ApplyPreview {
        ApplyPreview(
            profileName: name,
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: [],
            switchPlan: SwitchPlan(
                scope: .previousProfileApps,
                willQuit: [
                    RunningAppInfo(processIdentifier: 7, bundleId: "com.example.slack", name: "Slack"),
                    RunningAppInfo(processIdentifier: 8, bundleId: "com.example.figma", name: "Figma"),
                ]
            )
        )
    }

    /// A fresh applier per test: it records the answers it was given.
    private static func quittingApplier() -> FakeApplier {
        FakeApplier { _, confirm in
            let accepted = await confirm?(Self.twoAppQuittingPreview("Work")) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
    }

    @Test func excludingAnAppInThePanelHoldsWhenAcceptedFromThePopoverCard() async {
        let work = profile("Work")
        let presenter = FakePresenter()
        let applier = Self.quittingApplier()
        let model = MenuBarViewModel(
            library: FakeLibrary([work]), dock: FakeDockBackend(), applier: applier,
            undoer: FakeUndoer(), confirmationPresenter: presenter
        )

        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { model.confirmationModel != nil })
        // One model per question, shared by the panel and the popover.
        #expect(presenter.model === model.confirmationModel)

        // The panel's checkbox keeps Slack running; the popover card's Apply then accepts.
        presenter.model?.setAppChecked(false, for: "com.example.slack")
        model.confirmationModel?.switchAction()

        #expect(await eventually { model.activity == nil })
        #expect(await applier.answers == [ApplyConfirmResult(accepted: true, excludedBundleIDs: ["com.example.slack"])])
        #expect(model.confirmationModel == nil)
    }

    @Test func excludingAnAppInThePopoverHoldsWhenAcceptedFromThePanel() async {
        let work = profile("Work")
        let presenter = FakePresenter()
        let applier = Self.quittingApplier()
        let model = MenuBarViewModel(
            library: FakeLibrary([work]), dock: FakeDockBackend(), applier: applier,
            undoer: FakeUndoer(), confirmationPresenter: presenter
        )

        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { model.confirmationModel != nil })
        model.confirmationModel?.setAppChecked(false, for: "com.example.figma")
        presenter.userAnswers(true)

        #expect(await eventually { model.activity == nil })
        #expect(await applier.answers == [ApplyConfirmResult(accepted: true, excludedBundleIDs: ["com.example.figma"])])
    }

    @Test func theDiffSheetEditsTheSameExclusionsAsTheQuestion() async {
        let applier = Self.quittingApplier()
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation?.preview != nil })
        let preview = model.confirmation!.preview!

        // The sheet is built on the question's model, so its checkbox is the question's checkbox.
        let sheet = DiffSheetViewModel(preview: preview, switchConfirmation: model.confirmationModel)
        #expect(sheet.switchConfirmationViewModel === model.confirmationModel)
        sheet.switchConfirmationViewModel?.setAppChecked(false, for: "com.example.slack")
        #expect(model.confirmationModel?.excludedBundleIDs == ["com.example.slack"])

        // Applying from the sheet, or from anything else that answers, keeps Slack running.
        model.resolveConfirmation(sheet.confirmResult)
        #expect(await eventually { model.activity == nil })
        #expect(await applier.answers.map(\.excludedBundleIDs) == [["com.example.slack"]])
    }

    @Test func aBareAcceptStillCarriesTheExclusions() async {
        let applier = Self.quittingApplier()
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmationModel != nil })
        model.confirmationModel?.setAppChecked(false, for: "com.example.slack")
        model.resolveConfirmation(.accepted)

        #expect(await eventually { model.activity == nil })
        #expect(await applier.answers.map(\.excludedBundleIDs) == [["com.example.slack"]])
    }

    @Test func eachQuestionGetsAFreshModelWithNothingExcluded() async {
        let applier = Self.quittingApplier()
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmationModel != nil })
        model.confirmationModel?.setAppChecked(false, for: "com.example.slack")
        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })
        #expect(model.confirmationModel == nil)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmationModel != nil })
        #expect(model.confirmationModel?.excludedBundleIDs.isEmpty == true)
        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })
    }

    @Test func aHotkeyApplyIsAnAutomaticTriggerAndAPopoverApplyIsNot() async {
        let work = profile("Work")
        let applier = FakeApplier { _, _ in .applied(report()) }
        let model = makeModel(library: FakeLibrary([work]), applier: applier)

        model.apply(work)
        #expect(await eventually { model.banner != nil })
        model.dismissBanner()
        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { model.banner != nil })
        #expect(await applier.triggers == [.user, .automatic])
    }

    private static let askingApplier = FakeApplier { _, confirm in
        let accepted = await confirm?(preview("Work", skipped: [Self.missing])) ?? false
        return accepted ? .applied(report()) : .cancelled(rolledBack: false)
    }

    @Test func aHotkeyApplyThatNeedsConfirmationIsPresentedOutsideThePopover() async {
        let work = profile("Work")
        let presenter = FakePresenter()
        let model = MenuBarViewModel(
            library: FakeLibrary([work]), dock: FakeDockBackend(), applier: Self.askingApplier,
            undoer: FakeUndoer(), confirmationPresenter: presenter
        )

        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { model.confirmation != nil })
        #expect(presenter.presented.map(\.profileName) == ["Work"])

        presenter.userAnswers(true)
        #expect(await eventually { model.activity == nil })
        #expect(model.confirmation == nil)
        #expect(model.banner?.message.hasPrefix("Applied “Work”") == true)
    }

    @Test func aPopoverApplyDoesNotOpenAnAlert() async {
        let presenter = FakePresenter()
        let model = MenuBarViewModel(
            library: FakeLibrary(), dock: FakeDockBackend(), applier: Self.askingApplier,
            undoer: FakeUndoer(), confirmationPresenter: presenter
        )

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })
        #expect(presenter.presented.isEmpty)

        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })
        // Answering on the card also takes down any alert.
        #expect(presenter.dismissCount == 1)
    }

    @Test func anUnansweredConfirmationTimesOutAndReleasesBusy() async {
        let work = profile("Work")
        let presenter = FakePresenter()
        let model = MenuBarViewModel(
            library: FakeLibrary([work]), dock: FakeDockBackend(), applier: Self.askingApplier,
            undoer: FakeUndoer(), confirmationPresenter: presenter, confirmationTimeout: .milliseconds(30)
        )

        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { model.confirmation != nil })
        #expect(await eventually { model.activity == nil })

        #expect(model.isBusy == false)
        #expect(model.confirmation == nil)
        #expect(model.banner?.kind == .failure)
        #expect(model.banner?.message.hasPrefix("Timed out waiting for confirmation") == true)
        #expect(presenter.dismissCount == 1)
    }

    @Test func timeoutDismissesThePendingPresentationAndReleasesTheGate() async {
        let work = profile("Work")
        let presenter = FakePresenter()
        let gate = DockOperationGate()
        let model = MenuBarViewModel(
            library: FakeLibrary([work]), dock: FakeDockBackend(), applier: Self.askingApplier,
            undoer: FakeUndoer(), gate: gate, confirmationPresenter: presenter,
            confirmationTimeout: .milliseconds(30)
        )

        model.applyFromHotkey(profileID: work.id)
        #expect(await eventually { presenter.presented.count == 1 })
        #expect(gate.isBusy)

        // Nobody answers: the timeout alone must take the alert down and free the gate.
        #expect(await eventually { !gate.isBusy })
        #expect(presenter.dismissCount == 1)

        // A late click on the dismissed alert is ignored.
        presenter.userAnswers(true)
        #expect(model.banner?.message.hasPrefix("Timed out waiting for confirmation") == true)
        let ran = await gate.run("next") { true }
        #expect(ran)
    }

    @Test func aLateAnswerFromAnOldAlertCannotResolveANewerQuestion() async {
        let model = makeModel(applier: Self.askingApplier)
        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })

        model.resolveConfirmation(.accepted, token: -1)
        #expect(model.confirmation != nil)

        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })
    }

    @Test func cancellingTheDiffSheetReturnsToTheConfirmationCardWithoutDeclining() async {
        let model = makeModel(applier: Self.askingApplier)
        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })

        model.showsDiffSheet = true
        model.cancelDiffSheet()

        #expect(model.showsDiffSheet == false)
        #expect(model.confirmation != nil)
        #expect(model.isBusy)

        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })
    }

    @Test func decliningTheConfirmationLeavesTheDockAlone() async {
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(preview("Work", skipped: [Self.missing])) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })
        model.resolveConfirmation(.cancelled)
        #expect(await eventually { model.activity == nil })

        #expect(model.banner?.message == "Cancelled. The Dock was not changed.")
    }

    @Test func profilesThatLoseNothingApplyWithoutAsking() async {
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(preview("Work")) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
        let model = makeModel(applier: applier)

        await model.performApply(profile("Work"))

        #expect(model.banner == .init(kind: .success, message: "Applied “Work”."))
    }

    @Test func cancelDeclinesAnOpenQuestionAndStopsTheApply() async {
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(preview("Work", skipped: [Self.missing])) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })
        model.cancelOperation()
        #expect(await eventually { model.activity == nil })

        #expect(model.confirmation == nil)
        #expect(model.banner?.message == "Cancelled. The Dock was not changed.")
    }

    @Test func cancelledAfterWritingSaysTheDockWasRestored() async {
        let applier = FakeApplier { _, _ in .cancelled(rolledBack: true) }
        let model = makeModel(applier: applier)

        await model.performApply(profile("Work"))

        #expect(model.banner?.message == "Cancelled. The previous Dock was restored.")
    }

    // MARK: Save current Dock

    @Test func savingCapturesTheCurrentDockIntoANewProfile() async throws {
        let library = FakeLibrary()
        let state = DockState(apps: [safari, .spacer(.small)], others: [.file(FileItem(path: "/tmp/a.txt"))])
        let model = makeModel(library: library, dock: FakeDockBackend(state: state))
        model.beginSavingCurrentDock()
        #expect(model.isNamingProfile)

        let saved = await model.saveCurrentDock(as: "  Focus  ")

        #expect(saved)
        let stored = try #require(await library.stored.first)
        #expect(stored.name == "Focus")
        #expect(stored.dockState == state)
        #expect(model.profiles.map(\.name) == ["Focus"])
        #expect(model.activeProfileID == stored.id)
        #expect(model.isNamingProfile == false)
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: Profile.maxNameLength + 1)])
    func invalidNamesAreRejected(name: String) async {
        let library = FakeLibrary()
        let model = makeModel(library: library)

        let saved = await model.saveCurrentDock(as: name)

        #expect(saved == false)
        #expect(await library.stored.isEmpty)
        #expect(model.banner?.kind == .failure)
    }

    @Test func duplicateNamesAreRejectedIgnoringCase() async {
        let library = FakeLibrary([profile("Work")])
        let model = makeModel(library: library)

        let saved = await model.saveCurrentDock(as: "work")

        #expect(saved == false)
        #expect(await library.stored.count == 1)
        #expect(model.banner?.message == "A profile named “work” already exists.")
    }

    @Test func aFailedSaveKeepsThePromptOpenAndShowsTheError() async {
        let library = FakeLibrary()
        await library.failSaves()
        let model = makeModel(library: library)
        model.beginSavingCurrentDock()

        let saved = await model.saveCurrentDock(as: "Focus")

        #expect(saved == false)
        #expect(model.isNamingProfile)
        #expect(model.banner?.message.contains("boom") == true)
    }

    @Test func cancellingThePromptClearsIt() {
        let model = makeModel()
        model.beginSavingCurrentDock()
        model.newProfileName = "x"
        model.cancelSavingCurrentDock()
        #expect(model.isNamingProfile == false)
        #expect(model.newProfileName.isEmpty)
    }

    // MARK: Undo

    private static let target = UndoTarget(id: UUID(), createdAt: Date(), summary: "Before applying profile Work")

    @Test func undoIsOnlyAvailableWithATarget() async {
        let model = makeModel()
        await model.refresh()
        #expect(model.canUndo == false)

        let withTarget = makeModel(undoer: FakeUndoer(target: Self.target))
        await withTarget.refresh()
        #expect(withTarget.canUndo)
    }

    @Test func undoRestoresTheTargetAndRefreshes() async {
        let undoer = FakeUndoer(target: Self.target)
        let model = makeModel(undoer: undoer)
        await model.refresh()

        await model.performUndo()

        #expect(await undoer.undone == [Self.target.id])
        #expect(model.banner?.kind == .success)
        #expect(model.undoTarget == nil)
        #expect(model.canUndo == false)
    }

    @Test func undoErrorsAreShown() async {
        let undoer = FakeUndoer(target: Self.target)
        await undoer.fail(with: Boom())
        let model = makeModel(undoer: undoer)
        await model.refresh()

        await model.performUndo()

        #expect(model.banner == .init(kind: .failure, message: "boom"))
        #expect(model.undoTarget == Self.target)
    }

    @Test func aStaleUndoTargetIsRefusedAndRefreshed() async {
        let fresh = UndoTarget(id: UUID(), createdAt: Date(), summary: "Before restoring a snapshot")
        let undoer = FakeUndoer(target: Self.target)
        let model = makeModel(undoer: undoer)
        await model.refresh()

        // The history changed behind the menu bar's back; its cached target is now stale.
        await undoer.setTarget(fresh)
        await model.performUndo()

        #expect(await undoer.undone.isEmpty)
        #expect(model.banner?.kind == .failure)
        #expect(model.undoTarget == fresh)
    }

    @Test func aHistoryChangeSignalRefreshesUndoAvailability() async {
        let undoer = FakeUndoer(target: Self.target)
        let changes = DockChangeSignal()
        let model = MenuBarViewModel(
            library: FakeLibrary(), dock: FakeDockBackend(), applier: noApply, undoer: undoer, changes: changes
        )
        await model.refresh()
        #expect(model.undoTarget == Self.target)

        await undoer.setTarget(nil)
        changes.notify()
        #expect(await eventually { model.undoTarget == nil })
    }
}

/// One-shot latch for holding a fake operation open.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
