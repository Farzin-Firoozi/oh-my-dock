import Foundation
import Observation
import OhMyDockCore

/// State and actions for the snapshot history window. Its storage dependency is a protocol so
/// the view model can be tested without reading preferences or restarting the real Dock.
@MainActor
@Observable
final class HistoryViewModel {
    enum PendingAction: Equatable, Identifiable {
        case restore(Snapshot)
        case delete(Snapshot)

        /// Kind plus snapshot id, so restoring and deleting the same snapshot are different alerts.
        var id: String {
            switch self {
            case let .restore(snapshot): "restore-\(snapshot.id.uuidString)"
            case let .delete(snapshot): "delete-\(snapshot.id.uuidString)"
            }
        }
    }

    private(set) var snapshots: [Snapshot] = []
    private(set) var isWorking = false
    var pendingAction: PendingAction?
    var errorMessage: String?

    /// True while this window or any other Dock operation (the menu bar's) is running.
    var isBusy: Bool { isWorking || gate.isBusy }
    /// What the Dock is busy with, for display.
    var busyDescription: String? { isBusy ? (gate.current ?? "Working…") : nil }

    /// True while toolbar actions must stay disabled: an operation runs or an alert is up.
    var isInteractionLocked: Bool { isBusy || pendingAction != nil || errorMessage != nil }

    @ObservationIgnored private let history: any SnapshotHistoryManaging
    @ObservationIgnored private let gate: DockOperationGate
    @ObservationIgnored private let changes: DockChangeSignal

    init(
        history: any SnapshotHistoryManaging,
        gate: DockOperationGate = DockOperationGate(),
        changes: DockChangeSignal = DockChangeSignal()
    ) {
        self.history = history
        self.gate = gate
        self.changes = changes
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

    /// Confirms the action the user was asked about. The alert passes the value it was showing
    /// (captured at click time) because SwiftUI clears `pendingAction` when it dismisses the alert,
    /// which can happen before the button's closure runs.
    @discardableResult
    func confirm(_ action: PendingAction) -> Task<Void, Never>? {
        pendingAction = nil
        guard !isBusy else {
            errorMessage = "Another Dock change is running. Try again when it finishes."
            return nil
        }
        return Task { await perform(action) }
    }

    /// Confirms whatever is currently pending. Prefer `confirm(_:)` from views.
    @discardableResult
    func confirmPendingAction() -> Task<Void, Never>? {
        guard let action = pendingAction else { return nil }
        return confirm(action)
    }

    func performPendingAction() async {
        guard let action = pendingAction else { return }
        pendingAction = nil
        await perform(action)
    }

    func perform(_ action: PendingAction) async {
        guard !isBusy else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            // Even a failed restore may have changed the snapshots (its safety copy), so always signal.
            changes.notify()
        }

        do {
            switch action {
            case let .restore(snapshot):
                try await gate.run("Restoring a snapshot") { try await history.restore(id: snapshot.id) }
            case let .delete(snapshot):
                try await gate.run("Deleting a snapshot") { try await history.delete(id: snapshot.id) }
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
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

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
