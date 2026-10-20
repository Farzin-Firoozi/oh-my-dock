import Foundation
import OhMyDockCore

/// Profile persistence as the menu bar needs it. `ProfileStore` is the live implementation.
protocol ProfileLibrary: Sendable {
    func profiles() async -> [Profile]
    func save(_ profile: Profile) async throws
    /// Read-modify-write of one stored profile in a single store call.
    @discardableResult
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) async throws -> Profile
    /// Sets or clears a profile's hotkey; refuses one another profile already uses.
    @discardableResult
    func setHotkey(id: UUID, to hotkey: Hotkey?) async throws -> Profile
}

extension ProfileStore: ProfileLibrary {
    func profiles() -> [Profile] { list().profiles }
}

/// Applies a profile to the Dock. `ProfileApplier` is the live implementation.
protocol ProfileApplying: Sendable {
    func preview(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger
    ) async throws -> ApplyPreview
    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult
    /// `source` is the profile being switched away from (it scopes which apps get quit);
    /// `trigger` tells a click from an automatic source such as a hotkey.
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        controlSource: ControlSource?,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult
    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        controlSource: ControlSource?,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult
}

extension ProfileApplying {
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult {
        try await apply(profile, from: source, trigger: trigger, controlSource: nil, confirm: confirm)
    }

    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        try await apply(profile, from: source, trigger: trigger, controlSource: nil, confirm: confirm)
    }
}

extension ProfileApplying {
    func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger,
        controlSource: ControlSource?,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult {
        let boolConfirm: (@Sendable (ApplyPreview) async -> Bool)? = confirm.map { c in
            { @Sendable (preview: ApplyPreview) async -> Bool in
                (await c(preview)).accepted
            }
        }
        return try await apply(profile, from: source, trigger: trigger, controlSource: controlSource, confirm: boolConfirm)
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

    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?
    ) async throws -> ApplyResult {
        try await apply(profile, confirm: confirm.map { c in { @Sendable (preview: ApplyPreview) async -> Bool in (await c(preview)).accepted } })
    }

    func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        try await apply(profile, confirm: confirm.map { c in { @Sendable (preview: ApplyPreview) async -> ApplyConfirmResult in ApplyConfirmResult(accepted: await c(preview)) } })
    }
}

extension ProfileApplier: ProfileApplying {}

/// Puts what a hotkey apply needs to say in front of the user outside the popover (floating
/// panels): its confirmation question, how it failed, and what the app switch left behind. A hotkey
/// apply usually runs with the menu closed, where the popover's banner and sheets can't be seen.
@MainActor
protocol ConfirmationPresenting: AnyObject {
    /// Shows `confirmation` through `model`, the one model every UI for this question shares (so a
    /// per-app exclusion made anywhere is honoured wherever the user accepts). Answers go through
    /// the model's `onConfirm`; there is no separate callback.
    func present(_ confirmation: MenuBarViewModel.Confirmation, model: SwitchConfirmationViewModel)
    /// Takes the panel down because the question was answered elsewhere or timed out.
    func dismiss()
    /// Tells the user a hotkey apply failed or was refused (`banner.kind == .failure`).
    func presentNotice(_ banner: MenuBarViewModel.Banner)
    /// Shows `model`, the app switch's outcome, when it needs the user: apps that would not quit
    /// or failed to open, with the force-quit choice. Its `onDismiss` ends in `dismissOutcome()`.
    func presentOutcome(_ model: SwitchOutcomeViewModel)
    func dismissOutcome()
}

/// Goes back to the Dock as it was before the last applied change.
protocol DockUndoing: Sendable {
    func undoTarget() async -> UndoTarget?
    func undo(expecting id: UUID?) async throws
}

extension SnapshotUndoService: DockUndoing {
    func undo(expecting id: UUID?) async throws {
        _ = try await undo(expecting: id, controlSource: nil)
    }
}

/// Snapshot persistence and Dock restart operations needed by the history window.
protocol SnapshotHistoryManaging: Sendable {
    func list() async -> [Snapshot]
    /// Restores a snapshot, then restarts the Dock so it reads the restored preferences.
    func restore(id: UUID) async throws
    func pin(id: UUID) async throws
    func unpin(id: UUID) async throws
    func delete(id: UUID) async throws
}

enum SnapshotHistoryError: Error, LocalizedError {
    /// The snapshot was restored but the Dock could not be restarted to load it.
    case restoredButRestartFailed(any Error)

    var errorDescription: String? {
        switch self {
        case let .restoredButRestartFailed(error):
            "The snapshot was restored but the Dock could not be restarted: \(error). "
                + "Log out and back in, or restart the Dock, to see it."
        }
    }
}

/// Live history service backed by `SnapshotStore`.
struct SnapshotHistoryService: SnapshotHistoryManaging {
    let snapshots: SnapshotStore
    let restarter: any DockRestarting
    var prefsWriter: (any DockPrefsWriting)?

    func list() async -> [Snapshot] {
        await snapshots.list().snapshots
    }

    func restore(id: UUID) async throws {
        try await snapshots.restore(id: id, prefsWriter: prefsWriter)
        do {
            try await restarter.restart()
        } catch {
            throw SnapshotHistoryError.restoredButRestartFailed(error)
        }
    }

    func pin(id: UUID) async throws {
        try await snapshots.pin(id: id)
    }

    func unpin(id: UUID) async throws {
        try await snapshots.unpin(id: id)
    }

    func delete(id: UUID) async throws {
        try await snapshots.delete(id: id)
    }
}
