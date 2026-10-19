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

    func apply(_ profile: Profile, confirm: (@Sendable (ApplyPreview) async -> Bool)?) async throws -> ApplyResult {
        await probe.work()
        return .cancelled(rolledBack: false)
    }
}

private struct SlowUndoer: DockUndoing {
    let probe: Probe

    func undoTarget() async -> UndoTarget? {
        UndoTarget(id: UUID(), createdAt: Date(), summary: "Before applying profile X")
    }

    func undo(_ target: UndoTarget) async throws { await probe.work() }
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
@Suite struct DockOperationGateTests {
    @Test func gateRunsOperationsOneAtATimeInArrivalOrder() async {
        let gate = DockOperationGate()
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
        let gate = DockOperationGate()
        await #expect(throws: Failure.self) { try await gate.run("fails") { throw Failure() } }
        #expect(gate.isBusy == false)
        #expect(await gate.run("next") { 7 } == 7)
    }

    @Test func applyUndoAndHistoryRestoreNeverOverlapOnTheSharedGate() async {
        let gate = DockOperationGate()
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
            Task { @MainActor in await menuBar.performApply(profile) },
            Task { @MainActor in await gate.run("history restore") { try? await history.restore(id: UUID()) } },
            Task { @MainActor in await gate.run("history delete") { try? await history.delete(id: UUID()) } },
            Task { @MainActor in await menuBar.performUndo() },
        ]
        for task in tasks { await task.value }

        #expect(await probe.maxRunning == 1)
        #expect(await probe.finished >= 3)
        #expect(gate.isBusy == false)
    }

    @Test func busyStateIsVisibleInBothViewModels() async {
        let gate = DockOperationGate()
        let probe = Probe()
        let menuBar = MenuBarViewModel(
            library: StaticLibrary(), dock: FakeDockBackend(),
            applier: SlowApplier(probe: probe), undoer: SlowUndoer(probe: probe), gate: gate
        )
        let history = HistoryViewModel(history: SlowHistory(probe: probe), gate: gate)

        let restore = Task { await history.perform(.restore(snapshot())) }
        for _ in 0..<200 where !gate.isBusy { await Task.yield() }

        #expect(menuBar.isBusy)
        #expect(menuBar.externalActivity == "Restoring a snapshot")
        #expect(history.isBusy)
        menuBar.apply(Profile(name: "Work"))
        #expect(menuBar.banner?.kind == .failure)

        await restore.value
        #expect(menuBar.isBusy == false)
        #expect(history.isBusy == false)
    }
}
