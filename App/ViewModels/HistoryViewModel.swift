import Foundation
import Observation
import OhMyDockCore

/// State and actions for the snapshot history window. Its storage dependency is a protocol so
/// the view model can be tested without reading preferences or restarting the real Dock.
@MainActor
@Observable
final class HistoryViewModel {
    enum PendingAction: Equatable {
        case restore(Snapshot)
        case delete(Snapshot)
    }

    private(set) var snapshots: [Snapshot] = []
    private(set) var isBusy = false
    var pendingAction: PendingAction?
    var errorMessage: String?

    @ObservationIgnored private let history: any SnapshotHistoryManaging

    init(history: any SnapshotHistoryManaging) {
        self.history = history
    }

    func load() async {
        snapshots = await history.list()
    }

    func requestRestore(_ snapshot: Snapshot) {
        guard !isBusy else { return }
        errorMessage = nil
        pendingAction = .restore(snapshot)
    }

    func requestDelete(_ snapshot: Snapshot) {
        guard !isBusy else { return }
        errorMessage = nil
        pendingAction = .delete(snapshot)
    }

    func cancelPendingAction() {
        pendingAction = nil
    }

    func confirmPendingAction() {
        guard pendingAction != nil, !isBusy else { return }
        Task { await performPendingAction() }
    }

    func performPendingAction() async {
        guard let action = pendingAction, !isBusy else { return }
        pendingAction = nil
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            switch action {
            case let .restore(snapshot):
                try await history.restore(id: snapshot.id)
            case let .delete(snapshot):
                try await history.delete(id: snapshot.id)
            }
            await load()
        } catch {
            errorMessage = describe(error)
        }
    }

    func togglePin(_ snapshot: Snapshot) {
        guard !isBusy else { return }
        Task { await setPinned(!snapshot.pinned, for: snapshot) }
    }

    func setPinned(_ pinned: Bool, for snapshot: Snapshot) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            if pinned {
                try await history.pin(id: snapshot.id)
            } else {
                try await history.unpin(id: snapshot.id)
            }
            await load()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
