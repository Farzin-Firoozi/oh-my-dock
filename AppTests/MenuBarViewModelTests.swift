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
    private var script: Script

    init(_ script: @escaping Script) { self.script = script }

    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        applied.append(profile)
        return try await script(profile, confirm)
    }
}

private actor FakeUndoer: DockUndoing {
    private var target: UndoTarget?
    private(set) var undone: [UndoTarget] = []
    private var failure: (any Error)?

    init(target: UndoTarget? = nil) { self.target = target }

    func undoTarget() -> UndoTarget? { target }

    func undo(_ target: UndoTarget) throws {
        if let failure { throw failure }
        undone.append(target)
        self.target = nil
    }

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

        model.resolveConfirmation(true)
        #expect(await eventually { model.activity == nil })

        #expect(model.confirmation == nil)
        #expect(model.banner?.message.hasPrefix("Applied “Work”") == true)
    }

    @Test func decliningTheConfirmationLeavesTheDockAlone() async {
        let applier = FakeApplier { _, confirm in
            let accepted = await confirm?(preview("Work", skipped: [Self.missing])) ?? false
            return accepted ? .applied(report()) : .cancelled(rolledBack: false)
        }
        let model = makeModel(applier: applier)

        model.apply(profile("Work"))
        #expect(await eventually { model.confirmation != nil })
        model.resolveConfirmation(false)
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

        #expect(await undoer.undone == [Self.target])
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
