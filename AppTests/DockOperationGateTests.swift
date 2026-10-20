import Foundation
import OhMyDockCore
import Testing

/// Counts how many fake Dock operations overlap.
private actor Probe {
    private(set) var running = 0
    private(set) var maxRunning = 0
    private(set) var finished = 0

    func begin() { running += 1; maxRunning = max(maxRunning, running) }
    func end() { running -= 1; finished += 1 }

    func work() async {
        begin()
        try? await Task.sleep(for: .milliseconds(40))
        end()
    }
}

private struct SlowApplier: ProfileApplying {
    let probe: Probe

    func preview(_ profile: Profile, from source: Profile?, trigger: ApplyTrigger) async throws -> ApplyPreview {
        ApplyPreview(
            profileName: profile.name,
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: []
        )
    }

    func apply(_ profile: Profile, confirm: (@Sendable (ApplyPreview) async -> Bool)?) async throws -> ApplyResult {
        await probe.work()
        return .cancelled(rolledBack: false)
    }

    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        controlSource: ControlSource?,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        try await apply(profile, confirm: confirm)
    }
}

private struct SlowUndoer: DockUndoing {
    let probe: Probe

    func undoTarget() async -> UndoTarget? {
        UndoTarget(id: UUID(), createdAt: Date(), summary: "Before applying profile X")
    }

    func undo(expecting id: UUID?) async throws { await probe.work() }
}

private struct SlowHistory: SnapshotHistoryManaging {
    let probe: Probe

    func list() async -> [Snapshot] { [] }
    func restore(id: UUID) async throws { await probe.work() }
    func pin(id: UUID) async throws {}
    func unpin(id: UUID) async throws {}
    func delete(id: UUID) async throws { await probe.work() }
}

private actor StaticLibrary: ProfileLibrary {
    func profiles() -> [Profile] { [] }
    func save(_ profile: Profile) throws {}
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        throw ProfileStoreError.profileNotFound(id)
    }
    func setHotkey(id: UUID, to hotkey: Hotkey?) throws -> Profile {
        throw ProfileStoreError.profileNotFound(id)
    }
}

private func snapshot() -> Snapshot {
    Snapshot(id: UUID(), createdAt: Date(), reason: "r", byteSize: 1, sha256: "x", pinned: false)
}

@MainActor
private func drainScheduledMenuBarWork(_ menuBar: MenuBarViewModel) async {
    menuBar.cancelOperation()
    for _ in 0..<300 {
        if !menuBar.isBusy { return }
        await Task.yield()
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// One-shot latch for holding a fake confirmation open.
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

@MainActor
@Suite(.serialized) struct DockOperationGateTests {
    @Test func gateRunsOperationsOneAtATimeInArrivalOrder() async {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        let probe = Probe()
        var order: [Int] = []

        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            tasks.append(Task { @MainActor in
                await gate.run("op \(index)") {
                    order.append(index)
                    await probe.work()
                }
            })
            // Let each task reach the gate before the next one starts.
            for _ in 0..<5 { await Task.yield() }
        }
        for task in tasks { await task.value }

        #expect(await probe.maxRunning == 1)
        #expect(await probe.finished == 5)
        #expect(order == [0, 1, 2, 3, 4])
        #expect(gate.isBusy == false)
    }

    @Test func gateReleasesAfterAThrowingOperation() async throws {
        struct Failure: Error {}
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        await #expect(throws: Failure.self) { try await gate.run("fails") { throw Failure() } }
        #expect(gate.isBusy == false)
        #expect(await gate.run("next") { 7 } == 7)
    }

    @Test func applyUndoAndHistoryRestoreNeverOverlapOnTheSharedGate() async {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        let probe = Probe()
        let menuBar = MenuBarViewModel(
            library: StaticLibrary(),
            dock: FakeDockBackend(),
            applier: SlowApplier(probe: probe),
            undoer: SlowUndoer(probe: probe),
            gate: gate
        )
        await menuBar.refresh()
        let profile = Profile(name: "Work")

        // Each model guards on its own isBusy first, so drive the operations that bypass it:
        // whatever order they arrive in, the gate must keep them from overlapping.
        let history = SlowHistory(probe: probe)
        let tasks: [Task<Void, Never>] = [
            Task { @MainActor in try? await gate.runExclusiveMutation("apply") { await probe.work() } },
            Task { @MainActor in try? await gate.runExclusiveMutation("history restore") { await probe.work() } },
            Task { @MainActor in await gate.run("history delete") { await probe.work() } },
            Task { @MainActor in try? await gate.runExclusiveMutation("undo") { await probe.work() } },
        ]
        for task in tasks { await task.value }

        #expect(await probe.maxRunning == 1)
        #expect(await probe.finished == 4)
        #expect(gate.isBusy == false)
    }

    @Test func busyStateIsVisibleInBothViewModels() async {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        let probe = Probe()
        let menuBar = MenuBarViewModel(
            library: StaticLibrary(), dock: FakeDockBackend(),
            applier: SlowApplier(probe: probe), undoer: SlowUndoer(probe: probe), gate: gate
        )
        let history = HistoryViewModel(history: SlowHistory(probe: probe), gate: gate)

        let restore = Task { @MainActor in await history.perform(.restore(snapshot())) }
        #expect(await eventually { gate.current == "Restoring a snapshot" || history.isBusy })

        #expect(menuBar.isBusy)
        #expect(menuBar.externalActivity == "Restoring a snapshot")
        #expect(history.isBusy)
        menuBar.apply(Profile(name: "Work"))
        #expect(menuBar.banner?.kind == .failure)

        await restore.value
        #expect(menuBar.isBusy == false)
        #expect(history.isBusy == false)
    }

    // MARK: - Preview guard

    @Test func applyUndoAndHotkeyAreRefusedWhileAPreviewIsActive() async {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        let probe = Probe()
        let menuBar = MenuBarViewModel(
            library: StaticLibrary(), dock: FakeDockBackend(),
            applier: SlowApplier(probe: probe), undoer: SlowUndoer(probe: probe), gate: gate
        )
        await menuBar.refresh()
        gate.isPreviewActive = true

        menuBar.apply(Profile(name: "Work"))
        #expect(menuBar.banner == .init(kind: .failure, message: DockOperationGate.previewActiveMessage))
        menuBar.dismissBanner()
        menuBar.applyFromHotkey(profileID: UUID())
        #expect(menuBar.banner?.message == "Revert or keep the Dock preferences preview first.")
        menuBar.dismissBanner()
        menuBar.undoLastChange()
        #expect(menuBar.banner?.kind == .failure)
        menuBar.dismissBanner()
        await menuBar.performApply(Profile(name: "Work"))
        await menuBar.performUndo()
        await drainScheduledMenuBarWork(menuBar)

        #expect(await probe.finished == 0)
        #expect(menuBar.activity == nil)
        #expect(gate.isBusy == false)

        await drainScheduledMenuBarWork(menuBar)
        gate.isPreviewActive = false
        await menuBar.performApply(Profile(name: "Work"))
        #expect(await probe.finished == 1)
    }

    @Test func historyRestoreAndDeleteAreRefusedWhileAPreviewIsActive() async {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        let probe = Probe()
        let history = HistoryViewModel(history: SlowHistory(probe: probe), gate: gate)
        gate.isPreviewActive = true

        history.requestRestore(snapshot())
        #expect(history.pendingAction == nil)
        #expect(history.errorMessage == DockOperationGate.previewActiveMessage)
        history.errorMessage = nil
        history.requestDelete(snapshot())
        #expect(history.pendingAction == nil)
        history.errorMessage = nil
        await history.perform(.restore(snapshot()))
        #expect(history.errorMessage == DockOperationGate.previewActiveMessage)
        #expect(history.confirm(.delete(snapshot())) == nil)

        #expect(await probe.finished == 0)
        gate.isPreviewActive = false
        history.errorMessage = nil
        for _ in 0..<50 { await Task.yield() }
        await history.perform(.restore(snapshot()))
        #expect(history.errorMessage == nil)
        #expect(await probe.finished == 1)
    }

    @Test func confirmationWaitsWithoutHoldingFileLocks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-confirm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locks = try OperationLock(supportRoot: root)
        let gate = DockOperationGate(fileLocks: locks)
        let releaseConfirm = AsyncGate()
        let preview = ApplyPreview(
            profileName: "Work",
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: [SkippedItem(section: .apps, index: 0, app: AppRef(bundleId: "x", name: "Gone"))],
            switchPlan: nil
        )
        let task = Task { @MainActor in
            try await gate.runMutationAfterConfirmation(
                "apply",
                preview: { preview },
                confirm: { _ in
                    await releaseConfirm.wait()
                    return .accepted
                },
                mutate: { _, _ in true }
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!locks.isOperationHeld())
        #expect(!locks.isPreviewHeld())
        await releaseConfirm.open()
        #expect(try await task.value)
    }

    @Test func requireNoPreviewThrowsOnlyWhileAPreviewIsActive() {
        let gate = DockOperationGate(fileLocks: try! OperationLock(supportRoot: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")))
        #expect(throws: Never.self) { try gate.requireNoPreview() }
        gate.isPreviewActive = true
        #expect(throws: DockOperationGate.PreviewActiveError()) { try gate.requireNoPreview() }
        #expect(DockOperationGate.PreviewActiveError().errorDescription == "Revert or keep the Dock preferences preview first.")
    }
}
