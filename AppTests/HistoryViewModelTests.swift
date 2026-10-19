import Foundation
import OhMyDockCore
import Testing

private struct HistoryBoom: Error, LocalizedError {
    var errorDescription: String? { "history boom" }
}

private actor FakeHistory: SnapshotHistoryManaging {
    private(set) var snapshots: [Snapshot]
    private(set) var restored: [UUID] = []
    private(set) var pinned: [UUID] = []
    private(set) var unpinned: [UUID] = []
    private(set) var deleted: [UUID] = []
    private var failure: (any Error)?

    init(_ snapshots: [Snapshot] = []) {
        self.snapshots = snapshots
    }

    func list() -> [Snapshot] { snapshots }

    func restore(id: UUID) throws {
        if let failure { throw failure }
        restored.append(id)
    }

    func pin(id: UUID) throws {
        if let failure { throw failure }
        pinned.append(id)
        updatePinned(id, to: true)
    }

    func unpin(id: UUID) throws {
        if let failure { throw failure }
        unpinned.append(id)
        updatePinned(id, to: false)
    }

    func delete(id: UUID) throws {
        if let failure { throw failure }
        deleted.append(id)
        snapshots.removeAll { $0.id == id }
    }

    func fail(with error: any Error) {
        failure = error
    }

    private func updatePinned(_ id: UUID, to pinned: Bool) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[index].pinned = pinned
    }
}

private func snapshot(pinned: Bool = false) -> Snapshot {
    Snapshot(
        id: UUID(),
        createdAt: Date(timeIntervalSinceReferenceDate: 100),
        reason: "Before applying profile Work",
        byteSize: 42,
        sha256: "checksum",
        pinned: pinned
    )
}

@MainActor
@Suite struct HistoryViewModelTests {
    @Test func loadListsSnapshots() async {
        let first = snapshot()
        let second = snapshot(pinned: true)
        let model = HistoryViewModel(history: FakeHistory([first, second]))

        await model.load()

        #expect(model.snapshots == [first, second])
    }

    @Test func restoringRequiresConfirmationThenRestoresAndReloads() async {
        let item = snapshot()
        let history = FakeHistory([item])
        let model = HistoryViewModel(history: history)

        model.requestRestore(item)
        #expect(model.pendingAction == .restore(item))
        await model.performPendingAction()

        #expect(await history.restored == [item.id])
        #expect(model.pendingAction == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func deletingRequiresConfirmationThenRemovesSnapshot() async {
        let item = snapshot()
        let history = FakeHistory([item])
        let model = HistoryViewModel(history: history)
        await model.load()

        model.requestDelete(item)
        #expect(model.pendingAction == .delete(item))
        await model.performPendingAction()

        #expect(await history.deleted == [item.id])
        #expect(model.snapshots.isEmpty)
    }

    @Test func togglingPinUpdatesTheSnapshot() async {
        let item = snapshot()
        let history = FakeHistory([item])
        let model = HistoryViewModel(history: history)
        await model.load()

        await model.setPinned(true, for: item)
        #expect(await history.pinned == [item.id])
        #expect(model.snapshots == [Snapshot(
            id: item.id,
            createdAt: item.createdAt,
            reason: item.reason,
            byteSize: item.byteSize,
            sha256: item.sha256,
            pinned: true
        )])

        await model.setPinned(false, for: model.snapshots[0])
        #expect(await history.unpinned == [item.id])
        #expect(model.snapshots[0].pinned == false)
    }

    @Test func operationFailuresArePresentedAndKeepTheSnapshot() async {
        let item = snapshot()
        let history = FakeHistory([item])
        await history.fail(with: HistoryBoom())
        let model = HistoryViewModel(history: history)

        model.requestRestore(item)
        await model.performPendingAction()

        #expect(model.errorMessage == "history boom")
        #expect(model.isBusy == false)
    }

    @Test func confirmingAfterTheAlertClearedPendingActionStillPerformsTheCapturedAction() async throws {
        let item = snapshot()
        let history = FakeHistory([item])
        let model = HistoryViewModel(history: history)
        await model.load()

        model.requestRestore(item)
        let captured = try #require(model.pendingAction)
        // SwiftUI clears the alert's item before it runs the button closure.
        model.pendingAction = nil
        await model.confirm(captured)?.value

        #expect(await history.restored == [item.id])
        #expect(model.errorMessage == nil)
    }

    @Test func confirmPendingActionPerformsThroughTheRealConfirmPath() async {
        let item = snapshot()
        let history = FakeHistory([item])
        let model = HistoryViewModel(history: history)
        await model.load()

        model.requestDelete(item)
        await model.confirmPendingAction()?.value

        #expect(await history.deleted == [item.id])
        #expect(model.pendingAction == nil)
        #expect(model.snapshots.isEmpty)
    }

    @Test func pendingActionIdentityIncludesKindAndSnapshot() {
        let item = snapshot()
        #expect(HistoryViewModel.PendingAction.restore(item).id != HistoryViewModel.PendingAction.delete(item).id)
        #expect(HistoryViewModel.PendingAction.restore(item).id != HistoryViewModel.PendingAction.restore(snapshot()).id)
    }

    @Test func interactionIsLockedWhileAnAlertIsUp() {
        let item = snapshot()
        let model = HistoryViewModel(history: FakeHistory([item]))
        #expect(model.isInteractionLocked == false)
        model.requestRestore(item)
        #expect(model.isInteractionLocked)
        model.cancelPendingAction()
        #expect(model.isInteractionLocked == false)
        model.errorMessage = "x"
        #expect(model.isInteractionLocked)
    }
}
