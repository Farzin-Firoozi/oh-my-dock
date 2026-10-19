import AppKit
import Foundation

// MARK: - Preview

/// An app tile of a profile that was left out of the target because it could not be found.
public struct SkippedItem: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The path resolver found neither an installed app for the bundle identifier nor an
        /// existing `AppRef.path`.
        case appNotFound
    }

    public let section: DockSection
    /// Index of the tile in the profile's section (not in the target).
    public let index: Int
    public let app: AppRef
    public let reason: Reason

    public init(section: DockSection, index: Int, app: AppRef, reason: Reason = .appNotFound) {
        self.section = section
        self.index = index
        self.app = app
        self.reason = reason
    }
}

/// What applying a profile would do, computed without writing anything.
public struct ApplyPreview: Hashable, Sendable {
    public let profileName: String
    /// The Dock when the preview was computed.
    public let current: DockState
    /// The profile's layout with resolved app paths and without `skipped` apps.
    public let target: DockState
    public let plan: DockPlan
    public let skipped: [SkippedItem]
    /// Sections the profile fills but the Dock would end up with none of, because every app in it
    /// was skipped. `apply` refuses these (`ApplyError.wouldEmptySection`).
    public let emptiedSections: [DockSection]
    /// True when writing the plan also clears the Dock's recent apps: the plan is a full rewrite,
    /// or the backend turns it into one (dockutil does when a tile cannot be addressed uniquely).
    /// Incremental edits leave them alone.
    public let clearsRecentApps: Bool

    public init(
        profileName: String,
        current: DockState,
        target: DockState,
        plan: DockPlan,
        skipped: [SkippedItem],
        emptiedSections: [DockSection] = [],
        clearsRecentApps: Bool = false
    ) {
        self.profileName = profileName
        self.current = current
        self.target = target
        self.plan = plan
        self.skipped = skipped
        self.emptiedSections = emptiedSections
        self.clearsRecentApps = clearsRecentApps || plan.requiresFullRewrite
    }
}

// MARK: - Result

/// A successful apply: the Dock was written, verified and restarted.
public struct ApplyReport: Hashable, Sendable {
    public let plan: DockPlan
    /// The snapshot taken just before writing; the way back to the previous Dock.
    public let snapshotID: UUID
    public let skipped: [SkippedItem]
    public let clearsRecentApps: Bool
    public let restarted: Bool
}

public enum ApplyResult: Hashable, Sendable {
    /// The Dock was changed.
    case applied(ApplyReport)
    /// The Dock already matches the profile. Nothing was snapshotted, written or restarted.
    case noChanges(ApplyPreview)
    /// The apply was declined by `confirm` or cancelled by a newer apply (or the caller).
    /// `rolledBack` is true when writing had started and the Dock was restored from the snapshot.
    /// Either way the Dock is in its previous state.
    case cancelled(rolledBack: Bool)
}

public enum ApplyError: Error, LocalizedError, Sendable {
    case invalidProfile(ProfileValidationError)
    /// The target cannot be produced. Nothing was written or snapshotted.
    case unsatisfiable(issues: [DockPlanIssue])
    /// The Dock changed after the plan was computed, so its indices may be stale. Nothing was
    /// written; apply again to plan against the current Dock.
    case dockChanged
    /// Apps of the profile are missing and would be left out, and no `confirm` was given to let
    /// the user accept that. Nothing was written.
    case confirmationRequired(skipped: [SkippedItem])
    /// Every tile the profile has in `section` is a missing app, so applying it would empty a
    /// section that has tiles now. Nothing was written.
    case wouldEmptySection(DockSection, skipped: [SkippedItem])
    /// The backend refused the plan before writing anything (e.g. dockutil cannot express it).
    /// Nothing was snapshotted, written, restored or restarted.
    case rejectedByBackend(original: any Error)
    /// Writing or restarting failed; the Dock was restored from the snapshot and restarted.
    case failedAndRolledBack(original: any Error)
    /// Writing or restarting failed, and so did the rollback. The Dock may be half-written;
    /// `snapshotID` is the backup to restore from.
    case rollbackFailed(original: any Error, rollback: any Error, snapshotID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .invalidProfile(error):
            "The profile is invalid: \(error)"
        case let .unsatisfiable(issues):
            "The profile cannot be applied: \(issues.map(\.message).joined(separator: "; "))"
        case .dockChanged:
            "The Dock changed while the profile was being prepared. Nothing was changed; try again."
        case let .confirmationRequired(skipped):
            "\(skipped.count) app(s) of the profile were not found and need confirmation to be left out: "
                + skipped.map { $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name }.joined(separator: ", ")
        case let .wouldEmptySection(section, _):
            "None of the apps the profile has in the \(section.rawValue) section were found; "
                + "applying it would empty that section."
        case let .rejectedByBackend(original):
            "The Dock cannot be changed this way; nothing was changed: \(original)"
        case let .failedAndRolledBack(original):
            "Applying the profile failed and the previous Dock was restored: \(original)"
        case let .rollbackFailed(original, rollback, snapshotID):
            "Applying the profile failed (\(original)) and restoring the previous Dock failed too (\(rollback)). "
                + "The Dock may be inconsistent; restore snapshot \(snapshotID.uuidString) from the backups."
        }
    }
}

// MARK: - Applier

/// Applies a profile to the Dock and always leaves the Dock in a known state: the profile's, or
/// (after any failure or cancellation once writing started) the snapshot taken just before.
///
/// Flow of `apply`:
/// 1. Validate the profile, resolve app paths, read the Dock and plan the change.
/// 2. Apps that cannot be found are left out of the target, but only when `confirm` is given and
///    accepts; without it `ApplyError.confirmationRequired`. If that would empty a section the
///    profile fills, `ApplyError.wouldEmptySection`, confirmed or not. Unsatisfiable plan, or one the backend refuses up front (`preflight`): throw. Nothing was
///    written, so nothing is restored or restarted. Empty plan: `.noChanges`. No snapshot, no restart.
/// 3. `confirm` declines: `.cancelled`.
/// 4. Snapshot the Dock, then re-read it. When it no longer equals the state the plan was
///    computed from (someone edited the Dock meanwhile), throw `ApplyError.dockChanged`: the
///    plan's indices would be stale, and the user confirmed a different plan.
/// 5. `backend.apply`, then one `restarter.restart()`.
/// 6. Any error from 5, or a cancellation seen after the backend finished: restore the snapshot,
///    restart once, then throw `ApplyError.failedAndRolledBack` (or `.cancelled`). If the
///    restore or the restart fails: `ApplyError.rollbackFailed` with the snapshot id.
///
/// The `confirm` closure is raced against cancellation: a dialog that stays open (or ignores
/// cancellation) cannot hold up the cancelled apply, so it cannot hold up the next one either. Its
/// late answer is dropped.
///
/// Applies are serialized. A new `apply` cancels the one in flight and runs after it has settled.
/// Cancellation is checked between steps. Before the backend runs it yields `.cancelled` with no
/// writes; once the backend has run the rollback always completes first (it is shielded from the
/// cancellation). After a successful restart the apply is complete and is reported as applied.
///
/// Not covered here (v0.2): quitting/launching apps and writing Dock preferences.
public actor ProfileApplier {
    public typealias AppPathResolver = @Sendable (AppRef) -> String?
    typealias Planner = @Sendable (DockState, DockState) -> DockPlan

    /// The installed app for the bundle identifier, else `AppRef.path` when it exists on disk.
    public static let defaultPathResolver: AppPathResolver = { app in
        if !app.bundleId.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId)
        {
            return url.path(percentEncoded: false)
        }
        if let path = app.path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private struct InFlight {
        let id: UUID
        let task: Task<ApplyResult, any Error>
    }

    private let backend: any DockBackend
    private let snapshots: SnapshotStore
    private let restarter: any DockRestarting
    private let resolvePath: AppPathResolver
    private let planner: Planner
    private var inFlight: InFlight?

    public init(
        backend: any DockBackend,
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        resolvePath: @escaping AppPathResolver = ProfileApplier.defaultPathResolver
    ) {
        self.init(
            backend: backend,
            snapshots: snapshots,
            restarter: restarter,
            resolvePath: resolvePath,
            planner: DiffEngine.plan(from:to:)
        )
    }

    /// Lets tests substitute the planner, e.g. to produce an unsatisfiable plan (which a valid
    /// profile cannot).
    init(
        backend: any DockBackend,
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        resolvePath: @escaping AppPathResolver,
        planner: @escaping Planner
    ) {
        self.backend = backend
        self.snapshots = snapshots
        self.restarter = restarter
        self.resolvePath = resolvePath
        self.planner = planner
    }

    // MARK: Preview

    /// Validates the profile and computes what applying it would do. Writes nothing and takes no
    /// snapshot. An unsatisfiable plan is returned (see `ApplyPreview.plan.issues`), not thrown.
    public func preview(_ profile: Profile) async throws -> ApplyPreview {
        try validate(profile)
        let resolved = resolve(profile)
        return try await makePreview(profile: profile, resolved: resolved, current: try await backend.read())
    }

    // MARK: Apply

    public func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)? = nil
    ) async throws -> ApplyResult {
        let previous = inFlight
        previous?.task.cancel()

        let id = UUID()
        let task = Task<ApplyResult, any Error> {
            // Wait for the cancelled predecessor to settle (including its rollback).
            _ = await previous?.task.result
            return try await self.run(profile, confirm: confirm)
        }
        inFlight = InFlight(id: id, task: task)

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if inFlight?.id == id { inFlight = nil }
        return try result.get()
    }

    private func run(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        if Task.isCancelled { return .cancelled(rolledBack: false) }

        // Everything up to and including the snapshot is read-only for the Dock.
        let preview: ApplyPreview
        let snapshot: Snapshot
        let plan: DockPlan
        let skipped: [SkippedItem]
        do {
            try validate(profile)
            let resolved = resolve(profile)
            let first = try await makePreview(profile: profile, resolved: resolved, current: try await backend.read())

            if first.plan.unsatisfiable { throw ApplyError.unsatisfiable(issues: first.plan.issues) }
            if let section = first.emptiedSections.first {
                throw ApplyError.wouldEmptySection(section, skipped: first.skipped.filter { $0.section == section })
            }
            if first.plan.isEmpty { return .noChanges(first) }
            // Leaving apps out is only allowed with the user's say-so.
            if confirm == nil, !first.skipped.isEmpty {
                throw ApplyError.confirmationRequired(skipped: first.skipped)
            }
            if Task.isCancelled { return .cancelled(rolledBack: false) }

            if let confirm {
                let accepted = await Self.confirmation(confirm, for: first)
                if !accepted || Task.isCancelled { return .cancelled(rolledBack: false) }
            }

            // Cheap early exit that also avoids a pointless snapshot.
            if try await backend.read() != first.current { throw ApplyError.dockChanged }

            snapshot = try await snapshots.save(
                reason: "Before applying profile \(profile.name)",
                profileName: profile.name
            )
            if Task.isCancelled { return .cancelled(rolledBack: false) }

            // The plan's indices are only valid for the Dock it was computed from.
            if try await backend.read() != first.current { throw ApplyError.dockChanged }
            preview = first

            plan = preview.plan
            skipped = preview.skipped
        } catch is CancellationError {
            return .cancelled(rolledBack: false)
        }

        // Point of no return: from here every exit leaves the Dock restored or fully applied.
        var failure: (any Error)?
        do {
            try await backend.apply(plan.operations)
            if !Task.isCancelled {
                try await restarter.restart()
            }
        } catch {
            failure = error
        }

        if failure == nil && !Task.isCancelled {
            return .applied(ApplyReport(
                plan: plan,
                snapshotID: snapshot.id,
                skipped: skipped,
                clearsRecentApps: preview.clearsRecentApps,
                restarted: true
            ))
        }

        let original = failure ?? CancellationError()
        if let rollbackError = await rollBack(to: snapshot) {
            throw ApplyError.rollbackFailed(original: original, rollback: rollbackError, snapshotID: snapshot.id)
        }
        if original is CancellationError {
            return .cancelled(rolledBack: true)
        }
        throw ApplyError.failedAndRolledBack(original: original)
    }

    // MARK: Confirmation

    /// The answer of `confirm`, or false as soon as the surrounding task is cancelled, whether or
    /// not `confirm` ever returns. `confirm` runs in its own task, which is cancelled on a cancel
    /// and whose answer is ignored once this has returned.
    private static func confirmation(
        _ confirm: @escaping @Sendable (ApplyPreview) async -> Bool,
        for preview: ApplyPreview
    ) async -> Bool {
        let race = ConfirmationRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                race.start(continuation) {
                    Task {
                        let answer = await confirm(preview)
                        race.resolve(answer)
                    }
                }
            }
        } onCancel: {
            race.resolve(false)
        }
    }

    // MARK: Rollback

    /// Restores the snapshot, then restarts the Dock once. Returns the error if either failed;
    /// the restart is skipped when the restore failed (a restart would load the half-written
    /// preferences). Runs detached so the cancellation that may have triggered the rollback
    /// cannot cut it short.
    private func rollBack(to snapshot: Snapshot) async -> (any Error)? {
        let snapshots = snapshots
        let restarter = restarter
        let id = snapshot.id
        return await Task.detached {
            do {
                try await snapshots.restore(id: id, createSafetySnapshot: false)
                try await restarter.restart()
                return nil
            } catch {
                return error
            }
        }.value
    }

    // MARK: Planning

    private func validate(_ profile: Profile) throws {
        do {
            try profile.validate()
        } catch {
            throw ApplyError.invalidProfile(error)
        }
    }

    private struct Resolved {
        var target: DockState
        var skipped: [SkippedItem]
        /// Sections in which every tile of the profile is a skipped app.
        var emptiedByResolution: Set<DockSection>
    }

    /// The profile's layout with app paths resolved; apps that cannot be found are dropped.
    private func resolve(_ profile: Profile) -> Resolved {
        var target = DockState()
        var skipped: [SkippedItem] = []
        for section in DockSection.allCases {
            for (index, item) in profile.items(in: section).enumerated() {
                guard case .app(var app) = item else {
                    target[section].append(item)
                    continue
                }
                guard let path = resolvePath(app) else {
                    skipped.append(SkippedItem(section: section, index: index, app: app))
                    continue
                }
                app.path = path
                target[section].append(.app(app))
            }
        }
        let emptied = Set(DockSection.allCases.filter { section in
            !profile.items(in: section).isEmpty && target[section].isEmpty
        })
        return Resolved(target: target, skipped: skipped, emptiedByResolution: emptied)
    }

    private func makePreview(
        profile: Profile,
        resolved: Resolved,
        current: DockState
    ) async throws -> ApplyPreview {
        let target = Self.canonicalized(resolved.target, against: current)
        let plan = planner(current, target)
        // Only a plan that will be written has side effects to report.
        var clearsRecentApps = false
        if !plan.unsatisfiable, !plan.isEmpty {
            do {
                clearsRecentApps = try await backend.preflight(plan.operations).clearsRecentApps
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Raised before the first write: there is nothing to restore or restart.
                throw ApplyError.rejectedByBackend(original: error)
            }
        }
        return ApplyPreview(
            profileName: profile.name,
            current: current,
            target: target,
            plan: plan,
            skipped: resolved.skipped,
            emptiedSections: DockSection.allCases.filter {
                resolved.target[$0].isEmpty && resolved.emptiedByResolution.contains($0) && !current[$0].isEmpty
            },
            clearsRecentApps: clearsRecentApps
        )
    }

    /// Replaces target tiles by the equivalent tile already in the Dock. The Dock cannot store
    /// profile-only fields (`launchOnSwitch`, `brewCask`, an app `name`, ...), and the diff
    /// compares tiles field by field, so without this every app would look changed on every apply.
    /// "Equivalent" is `DockItem.matchesWithoutPathChange`: the rule the backend verifies writes
    /// with, minus its tolerance for an app that moved (same bundle identifier, other path).
    /// That tolerance suits verification, but here it would keep a stale path in the Dock when
    /// the profile resolves the app somewhere else.
    static func canonicalized(_ target: DockState, against current: DockState) -> DockState {
        var result = target
        for section in DockSection.allCases {
            let wanted = target[section]
            let existing = current[section]
            var used = [Bool](repeating: false, count: existing.count)
            var matched = [Bool](repeating: false, count: wanted.count)

            // Exact matches claim their tile first so a loose match cannot steal it.
            for (i, item) in wanted.enumerated() {
                if let j = existing.indices.first(where: { !used[$0] && existing[$0] == item }) {
                    used[j] = true
                    matched[i] = true
                }
            }
            for (i, item) in wanted.enumerated() where !matched[i] {
                if let j = existing.indices.first(where: { !used[$0] && item.matchesWithoutPathChange(existing[$0]) }) {
                    used[j] = true
                    result[section][i] = existing[j]
                }
            }
        }
        return result
    }
}

/// Resolves exactly once, with the first of "the user answered" and "the apply was cancelled".
private final class ConfirmationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?
    private var answer: Bool?

    /// Hands over the continuation and starts the confirmation, unless it was resolved already.
    func start(_ continuation: CheckedContinuation<Bool, Never>, _ makeTask: () -> Task<Void, Never>) {
        lock.lock()
        if let answer {
            lock.unlock()
            continuation.resume(returning: answer)
            return
        }
        self.continuation = continuation
        task = makeTask()
        lock.unlock()
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard answer == nil else {
            lock.unlock()
            return
        }
        answer = value
        let continuation = continuation
        let task = task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        continuation?.resume(returning: value)
        task?.cancel()
    }
}
