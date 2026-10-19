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
    /// Dock preference changes the profile would make. `nil` when the profile has no preferences
    /// (they are left untouched); empty when it has some and the Dock already matches them.
    public let prefsDiff: PrefsDiff?
    /// The preference values the diff was computed from; the apply refuses if they change.
    public let prefsBaseline: DockPrefsCapture?
    /// Apps the switch would quit, keep and launch, from the apps running when the preview was
    /// computed. `nil` when no `AppSwitching` is configured.
    public let switchPlan: SwitchPlan?
    /// The switch may quit apps without a confirmation: an automatic trigger on a profile that
    /// opted in (`SwitchingOptions.quitOnAutomaticSwitch`).
    public let quitsAuthorized: Bool

    public init(
        profileName: String,
        current: DockState,
        target: DockState,
        plan: DockPlan,
        skipped: [SkippedItem],
        emptiedSections: [DockSection] = [],
        clearsRecentApps: Bool = false,
        prefsDiff: PrefsDiff? = nil,
        prefsBaseline: DockPrefsCapture? = nil,
        switchPlan: SwitchPlan? = nil,
        quitsAuthorized: Bool = false
    ) {
        self.profileName = profileName
        self.current = current
        self.target = target
        self.plan = plan
        self.skipped = skipped
        self.emptiedSections = emptiedSections
        self.clearsRecentApps = clearsRecentApps || plan.requiresFullRewrite
        self.prefsDiff = prefsDiff
        self.prefsBaseline = prefsBaseline
        self.switchPlan = switchPlan
        self.quitsAuthorized = quitsAuthorized
    }

    public var hasPrefsChanges: Bool { !(prefsDiff?.isEmpty ?? true) }
    /// Tiles or preferences would be written (and the Dock restarted).
    public var hasDockChanges: Bool { !plan.isEmpty || hasPrefsChanges }
    /// Running apps the switch would ask to quit.
    public var willQuitApps: [RunningAppInfo] { switchPlan?.willQuit ?? [] }
    /// Nothing to write, quit or launch.
    public var isNoOp: Bool { !hasDockChanges && (switchPlan?.isEmpty ?? true) }

    /// Applying needs an explicit yes: apps would be left out, or running apps would be quit
    /// (unless an automatic trigger was explicitly allowed to).
    public var confirmationRequired: Bool {
        !skipped.isEmpty || (!willQuitApps.isEmpty && !quitsAuthorized)
    }
}

/// Where an apply came from. A user-initiated apply (a click) differs from an automatic one (hotkey,
/// schedule, Focus, ...) only in whether the profile's `quitOnAutomaticSwitch` opt-in counts.
public enum ApplyTrigger: Hashable, Sendable {
    case user
    case automatic
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
    /// Preference keys that were written.
    public let prefsChangedKeys: [DockPrefs.Key]
    /// What the quit/launch phase did, after the Dock change was written and verified. `nil` when
    /// there was nothing to quit or launch (or no switcher). A cancelled or partial phase does not
    /// undo the Dock change: it was already committed.
    public let switchOutcome: SwitchOutcome?

    public init(
        plan: DockPlan,
        snapshotID: UUID,
        skipped: [SkippedItem],
        clearsRecentApps: Bool,
        restarted: Bool,
        prefsChangedKeys: [DockPrefs.Key] = [],
        switchOutcome: SwitchOutcome? = nil
    ) {
        self.plan = plan
        self.snapshotID = snapshotID
        self.skipped = skipped
        self.clearsRecentApps = clearsRecentApps
        self.restarted = restarted
        self.prefsChangedKeys = prefsChangedKeys
        self.switchOutcome = switchOutcome
    }
}

public enum ApplyResult: Hashable, Sendable {
    /// The Dock was changed.
    case applied(ApplyReport)
    /// The Dock already matches the profile. Nothing was snapshotted, written or restarted.
    case noChanges(ApplyPreview)
    /// The Dock (tiles and preferences) already matched, but apps had to be quit or launched. No
    /// snapshot was taken and nothing was written. Quits are never undone.
    case appsOnly(SwitchOutcome)
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
    /// The switch would quit running apps and nobody confirmed it (no `confirm`, and the profile did
    /// not opt in for automatic triggers). Nothing was written or quit.
    case quitConfirmationRequired(apps: [RunningAppInfo])
    /// The profile sets Dock preferences and this applier has no writer for them. Nothing was written.
    case prefsUnavailable
    /// The Dock preferences could not be read or the profile's values were refused. Nothing was written.
    case prefsRejected(original: any Error)
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
        case let .quitConfirmationRequired(apps):
            "Switching would quit \(apps.count) app(s) and needs confirmation: "
                + apps.map(\.name).joined(separator: ", ")
        case .prefsUnavailable:
            "The profile sets Dock preferences, which this build cannot write. Nothing was changed."
        case let .prefsRejected(original):
            "The Dock preferences cannot be changed; nothing was changed: \(original)"
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
/// 1. Validate the profile, resolve app paths, read the Dock and plan the change. A profile with
///    `prefs` also reads the Dock preferences and diffs them (`ApplyPreview.prefsDiff`); `prefs ==
///    nil` leaves them untouched. With an `AppSwitching`, the quit/keep/launch plan is computed
///    from the apps running now (`ApplyPreview.switchPlan`).
/// 2. Apps that cannot be found are left out of the target, but only when `confirm` is given and
///    accepts; without it `ApplyError.confirmationRequired`. Likewise a plan that would quit running
///    apps needs `confirm` (or an automatic trigger on a profile with `quitOnAutomaticSwitch`),
///    else `ApplyError.quitConfirmationRequired`. If that would empty a section the
///    profile fills, `ApplyError.wouldEmptySection`, confirmed or not. Unsatisfiable plan, or one the backend refuses up front (`preflight`): throw. Nothing was
///    written, so nothing is restored or restarted. Nothing at all to do: `.noChanges`. No snapshot, no restart.
///    Apps left out still need `confirm`: without it, even an empty plan throws `confirmationRequired`.
/// 3. `confirm` declines: `.cancelled`. Tiles and preferences already match but apps must be
///    quit or launched: no snapshot, no write; the app phase runs and the result is `.appsOnly`.
/// 4. Snapshot the Dock domain (with the pre-image of the preference keys the apply will change),
///    then re-read the tiles and the preferences. When either no longer equals the state the plan
///    was computed from (someone edited the Dock meanwhile), throw `ApplyError.dockChanged`: the
///    plan's indices would be stale, and the user confirmed a different plan.
/// 5. `backend.apply(_:expecting:)` (tiles, `--no-restart`), which reads the Dock again itself and refuses with
///    `ApplyError.dockChanged` (nothing written, no restore or restart, snapshot discarded) when it
///    is not the state the plan was computed from. Then `DockPrefsWriter.apply(_:expecting:)`
///    (also not restarting). Then one `restarter.restart()`, only when tiles changed or the writer
///    says the Dock must reload, then a re-read of both: the restarted Dock must still hold the
///    tiles that were written (it loads the preferences and may rewrite them) and every changed
///    preference key must read back its target value.
/// 6. Any error from 5 (including those re-reads not matching), or a cancellation seen after the
///    backend finished: restore the snapshot (the whole domain, then the recorded preference
///    values explicitly), restart once and re-read: the tiles must equal the pre-apply Dock and the
///    preferences their pre-image. Then throw `ApplyError.failedAndRolledBack` (or `.cancelled`).
///    If the restore, the restart or that re-read check fails: `ApplyError.rollbackFailed` with
///    the snapshot id.
/// 7. Only after 5 succeeded and was verified: the app phase (`AppSwitching.execute`: quit, then
///    launch), its `SwitchOutcome` in `ApplyReport.switchOutcome`. A switch that was rolled back
///    never quits an app. Cancellation during the app phase stops before the next app is asked to
///    quit; the Dock change stays (it is committed) and quits that happened are not undone.
///
/// The `confirm` closure is raced against cancellation: a dialog that stays open (or ignores
/// cancellation) cannot hold up the cancelled apply, so it cannot hold up the next one either. Its
/// late answer is dropped.
///
/// Applies are serialized. A new `apply` cancels the one in flight and runs after it has settled.
/// Cancellation is checked between steps. Before the backend runs it yields `.cancelled` with no
/// writes; once the backend has run the rollback always completes first (it is shielded from the
/// cancellation). After a verified restart the Dock change is complete and is reported as applied.
public actor ProfileApplier {
    public typealias AppPathResolver = @Sendable (AppRef) -> String?
    typealias Planner = @Sendable (DockState, DockState) -> DockPlan

    /// The installed app for the bundle identifier, else `AppRef.path` when it exists on disk and
    /// is that app (see `resolvePath(_:installedURL:bundleIdentifier:)`).
    public static let defaultPathResolver: AppPathResolver = { app in
        resolvePath(
            app,
            installedURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            bundleIdentifier: DockPlistParser.bundleIdentifier(at:)
        )
    }

    /// The path hint is only a fallback for an app the system does not know by bundle identifier.
    /// It must exist, and when the profile names a bundle identifier, the bundle at the path must
    /// carry that identifier: a different app (or a stale file) sitting at the old path must not
    /// stand in for the one the profile asks for.
    static func resolvePath(
        _ app: AppRef,
        installedURL: (String) -> URL?,
        bundleIdentifier: (URL) -> String?
    ) -> String? {
        if !app.bundleId.isEmpty, let url = installedURL(app.bundleId) {
            return url.path(percentEncoded: false)
        }
        guard let path = app.path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        if !app.bundleId.isEmpty, bundleIdentifier(URL(fileURLWithPath: path)) != app.bundleId {
            return nil
        }
        return path
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
    private let prefsWriter: (any DockPrefsWriting)?
    private let appSwitcher: (any AppSwitching)?
    private var inFlight: InFlight?

    /// `prefsWriter` nil: a profile that sets Dock preferences is refused (`prefsUnavailable`)
    /// instead of having them silently dropped. `appSwitcher` nil: apps are neither quit nor
    /// launched.
    public init(
        backend: any DockBackend,
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        resolvePath: @escaping AppPathResolver = ProfileApplier.defaultPathResolver,
        prefsWriter: (any DockPrefsWriting)? = nil,
        appSwitcher: (any AppSwitching)? = nil
    ) {
        self.init(
            backend: backend,
            snapshots: snapshots,
            restarter: restarter,
            resolvePath: resolvePath,
            planner: DiffEngine.plan(from:to:),
            prefsWriter: prefsWriter,
            appSwitcher: appSwitcher
        )
    }

    /// Lets tests substitute the planner, e.g. to produce an unsatisfiable plan (which a valid
    /// profile cannot).
    init(
        backend: any DockBackend,
        snapshots: SnapshotStore,
        restarter: any DockRestarting,
        resolvePath: @escaping AppPathResolver,
        planner: @escaping Planner,
        prefsWriter: (any DockPrefsWriting)? = nil,
        appSwitcher: (any AppSwitching)? = nil
    ) {
        self.backend = backend
        self.snapshots = snapshots
        self.restarter = restarter
        self.resolvePath = resolvePath
        self.planner = planner
        self.prefsWriter = prefsWriter
        self.appSwitcher = appSwitcher
    }

    // MARK: Preview

    /// Validates the profile and computes what applying it would do. Writes nothing and takes no
    /// snapshot. An unsatisfiable plan is returned (see `ApplyPreview.plan.issues`), not thrown.
    /// `source` is the profile being switched away from (for the quit plan); nil quits nothing
    /// under the default scope.
    public func preview(
        _ profile: Profile,
        from source: Profile? = nil,
        trigger: ApplyTrigger = .user
    ) async throws -> ApplyPreview {
        try validate(profile)
        let resolved = resolve(profile)
        return try await makePreview(
            profile: profile,
            source: source,
            trigger: trigger,
            resolved: resolved,
            current: try await backend.read()
        )
    }

    // MARK: Apply

    public func apply(
        _ profile: Profile,
        confirm: (@Sendable (ApplyPreview) async -> Bool)? = nil
    ) async throws -> ApplyResult {
        try await apply(profile, from: nil, trigger: .user, confirm: confirm)
    }

    public func apply(
        _ profile: Profile,
        from source: Profile?,
        trigger: ApplyTrigger = .user,
        confirm: (@Sendable (ApplyPreview) async -> Bool)? = nil
    ) async throws -> ApplyResult {
        let previous = inFlight
        previous?.task.cancel()

        let id = UUID()
        let task = Task<ApplyResult, any Error> {
            // Wait for the cancelled predecessor to settle (including its rollback).
            _ = await previous?.task.result
            return try await self.run(profile, source: source, trigger: trigger, confirm: confirm)
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
        source: Profile?,
        trigger: ApplyTrigger,
        confirm: (@Sendable (ApplyPreview) async -> Bool)?
    ) async throws -> ApplyResult {
        if Task.isCancelled { return .cancelled(rolledBack: false) }

        // Everything up to and including the snapshot is read-only for the Dock.
        let preview: ApplyPreview
        let snapshot: Snapshot
        let expected: DockState
        let prefsImage: DockPrefsRollbackImage?
        do {
            try validate(profile)
            let resolved = resolve(profile)
            let first = try await makePreview(
                profile: profile,
                source: source,
                trigger: trigger,
                resolved: resolved,
                current: try await backend.read()
            )

            if first.plan.unsatisfiable { throw ApplyError.unsatisfiable(issues: first.plan.issues) }
            if let section = first.emptiedSections.first {
                throw ApplyError.wouldEmptySection(section, skipped: first.skipped.filter { $0.section == section })
            }
            // Leaving apps out needs the user's say-so even when the rest of the profile is
            // already on the Dock, so a headless caller cannot be told "no changes" while part of
            // the profile was silently dropped. With `confirm`, an empty plan returns
            // `.noChanges` without asking (nothing is written); `preview.skipped` lists the apps.
            if confirm == nil, !first.skipped.isEmpty {
                throw ApplyError.confirmationRequired(skipped: first.skipped)
            }
            // Quitting apps can lose work: it needs a yes, or an automatic trigger the profile
            // explicitly allowed to quit. A headless caller gets an error and nothing is touched.
            if confirm == nil, first.confirmationRequired {
                throw ApplyError.quitConfirmationRequired(apps: first.willQuitApps)
            }
            if first.isNoOp { return .noChanges(first) }
            if Task.isCancelled { return .cancelled(rolledBack: false) }

            if let confirm {
                let accepted = await Self.confirmation(confirm, for: first)
                if !accepted || Task.isCancelled { return .cancelled(rolledBack: false) }
            }

            // The Dock already matches: only apps to quit/launch. No snapshot, nothing to restore.
            if !first.hasDockChanges {
                return .appsOnly(await switchApps(first.switchPlan) ?? SwitchOutcome())
            }

            expected = try first.current.applying(first.plan.operations)
            prefsImage = first.hasPrefsChanges ? first.prefsBaseline.flatMap { baseline in
                first.prefsDiff.map { DockPrefsRollbackImage(restoring: $0, from: baseline) }
            } : nil

            // Cheap early exit that also avoids a pointless snapshot.
            try await checkUnchanged(first)

            snapshot = try await snapshots.save(
                reason: "Before applying profile \(profile.name)",
                profileName: profile.name,
                prefsPreImage: prefsImage
            )

            // Past this point the snapshot exists but nothing is written yet: leaving without
            // writing must not leave a backup of an unchanged Dock behind.
            do {
                try Task.checkCancellation()
                // The plan's indices are only valid for the Dock it was computed from.
                try await checkUnchanged(first)
            } catch {
                await discard(snapshot)
                throw error
            }
            preview = first
        } catch is CancellationError {
            return .cancelled(rolledBack: false)
        }

        let plan = preview.plan
        var prefsResult: DockPrefsApplyResult?
        var restarted = false

        // Point of no return: from here every exit leaves the Dock (tiles and preferences)
        // restored or fully applied.
        var failure: (any Error)?
        do {
            do {
                // The backend reads the Dock itself right before its first write and refuses when
                // it is not the state the plan was computed from, so no edit can slip in between
                // the checks above and the write.
                if !plan.isEmpty {
                    try await backend.apply(plan.operations, expecting: preview.current)
                }
            } catch DockBackendError.dockChanged {
                // Refused before the first write: nothing to restore, and the backup is of an
                // unchanged Dock.
                await discard(snapshot)
                throw ApplyError.dockChanged
            } catch is CancellationError {
                // Raised after its last read and before its first write (see `DockBackend`).
                await discard(snapshot)
                return .cancelled(rolledBack: false)
            }
            if plan.isEmpty, Task.isCancelled {
                // Preferences only and nothing written yet.
                await discard(snapshot)
                return .cancelled(rolledBack: false)
            }
            // Preferences go in right after the tiles and before the one restart, which loads both.
            // The writer refuses when the preferences changed since the preview; when nothing was
            // written before that, there is nothing to restore either.
            if let diff = preview.prefsDiff, !diff.isEmpty, !Task.isCancelled, let prefsWriter,
               let target = profile.prefs
            {
                do {
                    prefsResult = try prefsWriter.apply(target, expecting: preview.prefsBaseline)
                } catch DockPrefsWriterError.prefsChanged where plan.isEmpty {
                    await discard(snapshot)
                    throw ApplyError.dockChanged
                }
            }
            let needsRestart = !plan.isEmpty || prefsResult?.needsDockRestart == true
            if !Task.isCancelled, needsRestart {
                try await restarter.restart()
                restarted = true
            }
            if !Task.isCancelled {
                // The restarted Dock has loaded (and may have rewritten) what was written.
                if !plan.isEmpty {
                    let actual = try await backend.read()
                    guard expected.matchesAfterWrite(actual) else {
                        throw DockBackendError.verificationFailed(expected: expected, actual: actual)
                    }
                }
                if let diff = preview.prefsDiff, !diff.isEmpty, let prefsWriter {
                    let actual = try prefsWriter.captureCurrent()
                    for entry in diff.entries where actual[entry.key] != entry.target {
                        throw DockPrefsWriterError.verificationFailed(
                            key: entry.key,
                            expected: entry.target,
                            actual: actual[entry.key]
                        )
                    }
                }
            }
        } catch let error as ApplyError {
            throw error
        } catch {
            failure = error
        }

        if failure == nil && !Task.isCancelled {
            // The Dock change is committed and verified; only now are apps asked to quit. A switch
            // that rolled back never gets here, and a cancellation from now on stops the app phase
            // but does not undo the Dock.
            let outcome = await switchApps(preview.switchPlan)
            return .applied(ApplyReport(
                plan: plan,
                snapshotID: snapshot.id,
                skipped: preview.skipped,
                clearsRecentApps: preview.clearsRecentApps,
                restarted: restarted,
                prefsChangedKeys: prefsResult?.changedKeys ?? preview.prefsDiff?.entries.map(\.key) ?? [],
                switchOutcome: outcome
            ))
        }

        let original = failure ?? CancellationError()
        if let rollbackError = await rollBack(to: snapshot, expecting: preview.current, prefs: prefsImage) {
            throw ApplyError.rollbackFailed(original: original, rollback: rollbackError, snapshotID: snapshot.id)
        }
        if original is CancellationError {
            return .cancelled(rolledBack: true)
        }
        throw ApplyError.failedAndRolledBack(original: original)
    }

    /// Throws `dockChanged` when the tiles or the managed preferences are not what the preview read.
    private func checkUnchanged(_ preview: ApplyPreview) async throws {
        if try await backend.read() != preview.current { throw ApplyError.dockChanged }
        if preview.hasPrefsChanges, let prefsWriter, let baseline = preview.prefsBaseline {
            let now: DockPrefsCapture
            do {
                now = try prefsWriter.captureCurrent()
            } catch {
                throw ApplyError.prefsRejected(original: error)
            }
            if now != baseline { throw ApplyError.dockChanged }
        }
    }

    /// Quits and launches per `plan`, if there is a switcher and something to do. Runs inside the
    /// apply's task, so a cancellation stops it before the next app is asked to quit.
    private func switchApps(_ plan: SwitchPlan?) async -> SwitchOutcome? {
        guard let appSwitcher, let plan, !plan.isEmpty else { return nil }
        return await appSwitcher.execute(plan)
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

    /// Drops a snapshot taken for a write that never happened. Best effort: a leftover backup is
    /// harmless, a failed delete must not mask the reason the apply ended.
    private func discard(_ snapshot: Snapshot) async {
        try? await snapshots.delete(id: snapshot.id)
    }

    // MARK: Rollback

    /// Restores the snapshot (the whole Dock domain, plus the preference values it recorded),
    /// restarts the Dock once, then re-reads the Dock and checks the tiles are the state they had
    /// before the apply (`original`) and the preferences hold their `prefs` pre-image. Returns the
    /// error if any step failed; the restart is skipped when the restore failed (a restart would
    /// load the half-written preferences). A restart that reloads the failed state is a failed
    /// rollback, not a successful one. Runs detached so the cancellation that may have triggered
    /// the rollback cannot cut it short.
    private func rollBack(
        to snapshot: Snapshot,
        expecting original: DockState,
        prefs: DockPrefsRollbackImage?
    ) async -> (any Error)? {
        let snapshots = snapshots
        let restarter = restarter
        let backend = backend
        let prefsWriter = prefsWriter
        let id = snapshot.id
        return await Task.detached {
            do {
                try await snapshots.restore(id: id, createSafetySnapshot: false, prefsWriter: prefsWriter)
                try await restarter.restart()
                let actual = try await backend.read()
                guard original.matchesAfterWrite(actual) else {
                    throw DockBackendError.verificationFailed(expected: original, actual: actual)
                }
                if let prefs, let prefsWriter, try !prefsWriter.holds(prefs) {
                    throw ApplyError.prefsRejected(original: PrefsRollbackMismatch())
                }
                return nil
            } catch {
                return error
            }
        }.value
    }

    // MARK: Planning

    private func validate(_ profile: Profile) throws {
        do {
            try profile.validate(allowingUnknownTiles: true)
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
        source: Profile?,
        trigger: ApplyTrigger,
        resolved: Resolved,
        current: DockState
    ) async throws -> ApplyPreview {
        let target = Self.canonicalized(resolved.target, against: current)
        let plan = planner(current, target)
        // Only a plan that will be written has side effects to report.
        var clearsRecentApps = false
        if !plan.unsatisfiable, !plan.isEmpty {
            do {
                clearsRecentApps = try await backend.preflight(plan.operations, from: current).clearsRecentApps
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Raised before the first write: there is nothing to restore or restart.
                throw ApplyError.rejectedByBackend(original: error)
            }
        }
        // No preferences in the profile: leave the Dock's alone.
        var prefsDiff: PrefsDiff?
        var prefsBaseline: DockPrefsCapture?
        if let prefs = profile.prefs, !prefs.isEmpty {
            guard let prefsWriter else { throw ApplyError.prefsUnavailable }
            do {
                let baseline = try prefsWriter.captureCurrent()
                prefsDiff = try prefsWriter.diff(current: baseline, target: prefs)
                prefsBaseline = baseline
            } catch {
                throw ApplyError.prefsRejected(original: error)
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
            clearsRecentApps: clearsRecentApps,
            prefsDiff: prefsDiff,
            prefsBaseline: prefsBaseline,
            switchPlan: appSwitcher?.plan(from: source, to: profile),
            quitsAuthorized: trigger == .automatic && profile.switching.quitOnAutomaticSwitch
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

/// The preference values were not back at their pre-apply state after a rollback.
private struct PrefsRollbackMismatch: Error, CustomStringConvertible {
    var description: String { "the Dock preferences did not return to their previous values" }
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
