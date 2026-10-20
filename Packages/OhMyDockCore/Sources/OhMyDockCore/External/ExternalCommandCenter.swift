import AppKit
import Foundation

public struct ExternalCommandCenter: Sendable {
    public var profiles: ProfileStore
    public var snapshots: SnapshotStore
    public var applier: ProfileApplier
    public var undo: SnapshotUndoService
    public var restorer: SnapshotRestorer
    public var dock: any DockBackend
    public var prefsWriter: (any DockPrefsWriting)?
    public var locks: OperationLock
    public var activeRecord: any ActiveProfileRecording
    public var bundleID: String
    public var dockutilURL: URL?

    public init(
        profiles: ProfileStore,
        snapshots: SnapshotStore,
        applier: ProfileApplier,
        undo: SnapshotUndoService,
        restorer: SnapshotRestorer,
        dock: any DockBackend,
        prefsWriter: (any DockPrefsWriting)? = nil,
        locks: OperationLock,
        activeRecord: any ActiveProfileRecording,
        bundleID: String = "io.github.farzin-firoozi.OhMyDock",
        dockutilURL: URL? = nil
    ) {
        self.profiles = profiles
        self.snapshots = snapshots
        self.applier = applier
        self.undo = undo
        self.restorer = restorer
        self.dock = dock
        self.prefsWriter = prefsWriter
        self.locks = locks
        self.activeRecord = activeRecord
        self.bundleID = bundleID
        self.dockutilURL = dockutilURL
    }

    public func run(_ request: ExternalRequest) async -> ExternalResult {
        let name = ExternalCommandName.canonical(request.command)
        do {
            _ = try DockPlistEnvironment.resolvedOverridePlist()
        } catch DockPlistEnvironmentError.liveDockPlistRefused {
            return failure(name, code: "usage", exit: 2, message: "OHMYDOCK_DOCK_PLIST must not point at the live Dock plist.", reason: "liveDockPlistRefused")
        } catch {
            return internalFailure(name, error)
        }

        do {
            _ = try SupportPaths.root()
        } catch SupportPathsError.relativeSupportDirectory {
            return failure(name, code: "usage", exit: 2, message: "OHMYDOCK_SUPPORT_DIR must be an absolute path.")
        } catch {
            return internalFailure(name, error)
        }

        let timeout = LockTimeout.resolve(requestTimeout: request.lockTimeout)

        switch request.command {
        case .version:
            return success(name, message: OhMyDockCore.version, payload: {
                var p = ExternalPayload()
                p.version = OhMyDockCore.version
                return p
            }())
        case .list:
            return await withShared(timeout: timeout, name: name) { await listProfiles(name: name) }
        case let .show(profile):
            return await withShared(timeout: timeout, name: name) { await show(profile: profile, name: name) }
        case .current:
            return await current(request: request, timeout: timeout, name: name)
        case let .apply(profile, dryRun, quitScope, keepRunning):
            return await apply(
                request: request,
                profileAddress: profile,
                dryRun: dryRun,
                quitScope: quitScope,
                keepRunning: keepRunning,
                timeout: timeout,
                name: name
            )
        case let .save(saveName, force, includePrefs):
            return await save(
                request: request,
                name: saveName,
                force: force,
                includePrefs: includePrefs,
                timeout: timeout,
                name: name
            )
        case let .delete(profile):
            return await deleteProfile(request: request, address: profile, timeout: timeout, name: name)
        case let .rename(profile, newName):
            return await renameProfile(address: profile, newName: newName, timeout: timeout, name: name)
        case let .duplicate(profile, newName):
            return await duplicateProfile(address: profile, newName: newName, timeout: timeout, name: name)
        case .undo:
            return await undoChange(request: request, timeout: timeout, name: name)
        case .snapshots:
            return await withShared(timeout: timeout, name: name) { await listSnapshots(name: name) }
        case let .snapshotsPin(id):
            return await pinSnapshot(id: id, timeout: timeout, name: name)
        case let .snapshotsUnpin(id):
            return await unpinSnapshot(id: id, timeout: timeout, name: name)
        case let .snapshotsDelete(id):
            return await deleteSnapshot(request: request, id: id, timeout: timeout, name: name)
        case let .restore(id):
            return await restoreSnapshot(request: request, id: id, timeout: timeout, name: name)
        case let .export(profile, format, output, force):
            return await exportProfile(
                address: profile,
                format: format,
                output: output,
                force: force,
                timeout: timeout,
                name: name
            )
        case let .import(source, overrideName):
            return await importProfile(
                source: source,
                overrideName: overrideName,
                timeout: timeout,
                name: name
            )
        case .status:
            return await withShared(timeout: timeout, name: name) { await status(name: name) }
        case .doctor:
            return await withShared(timeout: timeout, name: name) { await doctor(name: name) }
        }
    }

    // MARK: - Locks

    private func withShared(
        timeout: Duration,
        name: String,
        _ body: @Sendable () async throws -> ExternalResult
    ) async -> ExternalResult {
        do {
            return try await locks.withSharedOperation(timeout: timeout) { try await body() }
        } catch OperationLockError.busy(let reason) {
            return locked(name, reason: reason)
        } catch {
            return mapError(error, name: name)
        }
    }

    private func withExclusive(
        timeout: Duration,
        refusePreview: Bool,
        name: String,
        _ body: @Sendable () async throws -> ExternalResult
    ) async -> ExternalResult {
        do {
            return try await locks.withExclusiveOperation(timeout: timeout, refuseWhenPreviewHeld: refusePreview) {
                try await body()
            }
        } catch OperationLockError.busy(let reason) {
            return locked(name, reason: reason)
        } catch {
            return mapError(error, name: name)
        }
    }

    private func withMutation(
        timeout: Duration,
        name: String,
        _ body: @Sendable () async throws -> ExternalResult
    ) async -> ExternalResult {
        do {
            return try await locks.withMutationLocks(timeout: timeout) { try await body() }
        } catch OperationLockError.busy(let reason) {
            return locked(name, reason: reason)
        } catch {
            return mapError(error, name: name)
        }
    }

    /// Errors thrown by a locked body: undo/restore/snapshot/apply failures keep their own exit codes.
    private func mapError(_ error: any Error, name: String) -> ExternalResult {
        switch error {
        case UndoError.nothingToUndo:
            return failure(name, code: "nothingToUndo", exit: 3, message: "There is nothing to undo.")
        case UndoError.targetChanged:
            return failure(name, code: "conflict", exit: 6, message: String(describing: error), reason: "targetChanged")
        case SnapshotStoreError.snapshotNotFound:
            return failure(name, code: "notFound", exit: 3, message: "Snapshot not found.")
        case let error as ApplyError:
            return mapApplyError(error, name: name, preview: nil)
        default:
            return internalFailure(name, error)
        }
    }

    // MARK: - Commands

    private func sortedProfiles() async -> [Profile] {
        let listed = await profiles.list()
        return listed.profiles.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private enum ResolvedProfile {
        case found(Profile)
        case failed(ExternalResult)
    }

    private func resolveProfile(_ address: String, name: String) async -> ResolvedProfile {
        let all = await sortedProfiles()
        switch ProfileAddressing.resolve(address, in: all) {
        case let .found(profile):
            return .found(profile)
        case .notFound:
            return .failed(failure(name, code: "notFound", exit: 3, message: "Profile not found: \(address)"))
        case let .ambiguous(matches):
            return .failed(failure(
                name,
                code: "ambiguous",
                exit: 4,
                message: "More than one profile matches “\(address)”.",
                matches: matches
            ))
        }
    }

    private func listProfiles(name: String) async -> ExternalResult {
        let listed = await profiles.list()
        let sorted = await sortedProfiles()
        var payload = ExternalPayload()
        payload.profiles = sorted.map { profile in
            ExternalPayload.ListProfileEntry(
                id: profile.id.uuidString,
                name: profile.name,
                appCount: profile.apps.count,
                otherCount: profile.others.count,
                hasPrefs: profile.prefs != nil && !(profile.prefs?.isEmpty ?? true),
                quitScope: profile.switching.quitScope.rawValue
            )
        }
        payload.unreadable = listed.failures.map {
            ExternalPayload.UnreadableEntry(path: $0.url.path, message: String(describing: $0.error))
        }
        return success(name, message: "Listed \(sorted.count) profile(s).", payload: payload)
    }

    private func show(profile address: String, name: String) async -> ExternalResult {
        switch await resolveProfile(address, name: name) {
        case let .failed(result): return result
        case let .found(profile):
            let data: Data
            do {
                data = try profile.jsonData()
            } catch {
                return internalFailure(name, error)
            }
            var payload = ExternalPayload()
            payload.profileDocument = data
            return success(name, message: profile.name, payload: payload)
        }
    }

    private func current(request: ExternalRequest, timeout: Duration, name: String) async -> ExternalResult {
        if locks.isPreviewHeld() {
            return locked(name, reason: .previewActive)
        }
        do {
            return try await locks.withSharedOperation(timeout: timeout) {
                try await currentUnlocked(request: request, name: name)
            }
        } catch OperationLockError.busy(let reason) {
            return locked(name, reason: reason)
        } catch {
            return internalFailure(name, error)
        }
    }

    private func currentUnlocked(request: ExternalRequest, name: String) async throws -> ExternalResult {
        let all = await sortedProfiles()
        let currentDock = try await dock.read()
        let lastApplied = activeRecord.load()
        let match = ActiveProfileMatcher.match(profiles: all, current: currentDock, lastAppliedID: lastApplied)
        var payload = ExternalPayload()
        if let primary = match.primary {
            payload.matchedProfile = ref(primary)
            payload.otherMatches = match.otherMatches.map(ref)
            let previous = primary.id != lastApplied ? match.otherMatches.first : nil
            let preview = try await applier.preview(primary, from: previous, trigger: .user)
            payload.differs = !preview.isNoOp
            payload.noChanges = preview.isNoOp
            payload.confirmationRequired = preview.confirmationRequired
            payload.clearsRecentApps = preview.clearsRecentApps
            payload.planSummary = preview.plan.summary
            payload.prefsDiff = preview.prefsDiff.map { diff in
                diff.entries.map { entry in
                    ExternalPayload.PrefsDiffEntry(key: entry.key.rawValue, target: encodePrefsTarget(entry.target))
                }
            }
            payload.willQuit = preview.willQuitApps.map { ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "") }
            payload.willLaunch = (preview.switchPlan?.willLaunch ?? []).map {
                ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "")
            }
            payload.skipped = preview.skipped.map {
                ExternalAppRef(
                    name: $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name,
                    bundleId: $0.app.bundleId,
                    section: $0.section.rawValue
                )
            }
        } else {
            payload.otherMatches = []
        }
        return success(name, message: "Current Dock state.", payload: payload)
    }

    private func apply(
        request: ExternalRequest,
        profileAddress: String,
        dryRun: Bool,
        quitScope: SwitchingOptions.QuitScope?,
        keepRunning: [String],
        timeout: Duration,
        name: String
    ) async -> ExternalResult {
        if locks.isPreviewHeld() {
            return locked(name, reason: .previewActive)
        }
        switch await resolveProfile(profileAddress, name: name) {
        case let .failed(result): return result
        case let .found(stored):
            let profile: Profile = {
                guard let quitScope else { return stored }
                var copy = stored
                copy.switching.quitScope = quitScope
                return copy
            }()
            let previewPrevious = await previousProfile(for: profile)

            do {
                let preview = try await applier.preview(profile, from: previewPrevious, trigger: .user)
                if dryRun {
                    return try await locks.withSharedOperation(timeout: timeout) {
                        applyPreviewPayload(name: name, profile: profile, preview: preview, status: "dryRun")
                    }
                }
                if let refusal = cliConfirmationRefusal(request: request, preview: preview, name: name) {
                    return refusal
                }
                let lockedAnswer: ApplyConfirmResult?
                if let userConfirm = request.confirm {
                    let answer = await userConfirm(preview)
                    if !answer.accepted {
                        return success(name, message: "Cancelled.", payload: { var p = ExternalPayload(); p.status = "cancelled"; return p }())
                    }
                    lockedAnswer = answer
                } else {
                    lockedAnswer = nil
                }
                return try await locks.withMutationLocks(timeout: timeout) {
                    // The Dock may have changed since the preview: re-derive `previous` and re-check
                    // the quit/skip rules against the preview the applier builds under the locks.
                    let previous = await previousProfile(for: profile)
                    let refused = RefusedPreview()
                    let excluded = Set(keepRunning.map { $0.lowercased() })
                    let confirm: @Sendable (ApplyPreview) async -> ApplyConfirmResult = { fresh in
                        if let lockedAnswer {
                            guard fresh.quitsAreCovered(by: preview) else {
                                refused.set(fresh)
                                return .cancelled
                            }
                            return lockedAnswer
                        }
                        let needsQuit = !fresh.willQuitApps.isEmpty
                        if (needsQuit && !(request.allowQuit && request.yes))
                            || (!fresh.skipped.isEmpty && !request.yes)
                        {
                            refused.set(fresh)
                            return .cancelled
                        }
                        return ApplyConfirmResult(accepted: true, excludedBundleIDs: excluded)
                    }
                    let result = try await applier.apply(
                        profile,
                        from: previous,
                        trigger: .user,
                        controlSource: request.source,
                        confirm: confirm
                    )
                    if let fresh = refused.get() {
                        return needsConfirmation(name, preview: fresh, reason: fresh.willQuitApps.isEmpty ? "skip" : "quit")
                    }
                    activeRecord.save(profile.id)
                    return mapApplyResult(result, profile: profile, preview: preview, name: name)
                }
            } catch OperationLockError.busy(let reason) {
                return locked(name, reason: reason)
            } catch let error as ApplyError {
                return mapApplyError(error, name: name, preview: nil)
            } catch {
                return internalFailure(name, error)
            }
        }
    }

    private func cliConfirmationRefusal(
        request: ExternalRequest,
        preview: ApplyPreview,
        name: String
    ) -> ExternalResult? {
        if request.confirm != nil { return nil }
        let needsQuit = !preview.willQuitApps.isEmpty
        let needsSkip = !preview.skipped.isEmpty
        if needsQuit, !(request.allowQuit && request.yes) {
            return needsConfirmation(name, preview: preview, reason: "quit")
        }
        if needsSkip, !request.yes {
            return needsConfirmation(name, preview: preview, reason: "skip")
        }
        if needsQuit, request.yes, !request.allowQuit {
            return needsConfirmation(name, preview: preview, reason: "quit")
        }
        return nil
    }

    /// Set by the locked confirm closure when the fresh preview breaks the quit/skip rules.
    private final class RefusedPreview: @unchecked Sendable {
        private let lock = NSLock()
        private var preview: ApplyPreview?
        func set(_ value: ApplyPreview) { lock.withLock { preview = value } }
        func get() -> ApplyPreview? { lock.withLock { preview } }
    }

    private func previousProfile(for profile: Profile) async -> Profile? {
        let all = await sortedProfiles()
        guard let currentDock = try? await dock.read() else { return nil }
        let match = ActiveProfileMatcher.match(profiles: all, current: currentDock, lastAppliedID: activeRecord.load())
        return match.primary.flatMap { $0.id != profile.id ? $0 : nil }
    }

    private func mapApplyResult(
        _ result: ApplyResult,
        profile: Profile,
        preview: ApplyPreview,
        name: String
    ) -> ExternalResult {
        switch result {
        case let .applied(report):
            var payload = ExternalPayload()
            payload.status = "applied"
            payload.profile = ref(profile)
            payload.snapshotID = report.snapshotID.uuidString
            payload.restarted = report.restarted
            payload.clearsRecentApps = report.clearsRecentApps
            payload.prefsChangedKeys = report.prefsChangedKeys.map(\.rawValue)
            payload.planSummary = preview.plan.summary
            if let outcome = report.switchOutcome {
                payload.switchOutcome = ExternalPayload.ExternalSwitchOutcome(
                    summary: outcome.summary,
                    wasCancelled: outcome.wasCancelled
                )
            }
            return success(name, message: "Applied “\(profile.name)”.", payload: payload)
        case .noChanges:
            var payload = ExternalPayload()
            payload.status = "noChanges"
            payload.profile = ref(profile)
            return success(name, message: "“\(profile.name)” is already on the Dock.", payload: payload)
        case let .appsOnly(outcome):
            var payload = ExternalPayload()
            payload.status = "appsOnly"
            payload.profile = ref(profile)
            payload.switchOutcome = ExternalPayload.ExternalSwitchOutcome(
                summary: outcome.summary,
                wasCancelled: outcome.wasCancelled
            )
            return success(name, message: "“\(profile.name)” is already on the Dock.", payload: payload)
        case .cancelled:
            return success(name, message: "Cancelled.", payload: { var p = ExternalPayload(); p.status = "cancelled"; return p }())
        }
    }

    private func applyPreviewPayload(
        name: String,
        profile: Profile,
        preview: ApplyPreview,
        status: String
    ) -> ExternalResult {
        var payload = ExternalPayload()
        payload.status = status
        payload.profile = ref(profile)
        payload.confirmationRequired = preview.confirmationRequired
        payload.clearsRecentApps = preview.clearsRecentApps
        payload.planSummary = preview.plan.summary
        payload.willQuit = preview.willQuitApps.map { ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "") }
        payload.willLaunch = (preview.switchPlan?.willLaunch ?? []).map {
            ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "")
        }
        payload.skipped = preview.skipped.map {
            ExternalAppRef(
                name: $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name,
                bundleId: $0.app.bundleId,
                section: $0.section.rawValue
            )
        }
        return success(name, message: "Dry run for “\(profile.name)”.", payload: payload)
    }

    private func save(
        request: ExternalRequest,
        name rawName: String,
        force: Bool,
        includePrefs: Bool,
        timeout: Duration,
        name: String
    ) async -> ExternalResult {
        if locks.isPreviewHeld() {
            return locked(name, reason: .previewActive)
        }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > Profile.maxNameLength {
            return failure(name, code: "usage", exit: 2, message: "Profile name must be 1–\(Profile.maxNameLength) characters.")
        }
        return await withExclusive(timeout: timeout, refusePreview: includePrefs, name: name) {
            let listed = await profiles.list()
            let matches = listed.profiles.filter {
                $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }
            if force {
                if matches.count > 1 {
                    let ambiguous = matches.map { ProfileMatch(id: $0.id, name: $0.name) }.sorted { $0.id.uuidString < $1.id.uuidString }
                    return failure(name, code: "ambiguous", exit: 4, message: "More than one profile is named “\(trimmed)”.", matches: ambiguous)
                }
            } else if !matches.isEmpty {
                return failure(name, code: "conflict", exit: 6, message: "A profile named “\(trimmed)” already exists.", reason: "nameInUse")
            }

            let dockState = try await dock.read()
            var profile: Profile
            if force, let existing = matches.first {
                profile = existing
                profile.apps = dockState.apps
                profile.others = dockState.others
            } else {
                profile = Profile(name: trimmed, apps: dockState.apps, others: dockState.others)
            }
            if includePrefs, let prefsWriter {
                profile.prefs = try prefsWriter.captureCurrent().asDockPrefs()
            }
            try await profiles.save(profile)
            activeRecord.save(profile.id)
            var payload = ExternalPayload()
            payload.profile = ref(profile)
            return success(name, message: "Saved “\(profile.name)”.", payload: payload)
        }
    }

    private func deleteProfile(request: ExternalRequest, address: String, timeout: Duration, name: String) async -> ExternalResult {
        guard request.yes else {
            return failure(name, code: "usage", exit: 2, message: "delete requires --yes.")
        }
        switch await resolveProfile(address, name: name) {
        case let .failed(result): return result
        case let .found(profile):
            return await withExclusive(timeout: timeout, refusePreview: true, name: name) {
                try await profiles.delete(id: profile.id)
                if activeRecord.load() == profile.id { activeRecord.save(nil) }
                var payload = ExternalPayload()
                payload.profile = ref(profile)
                return success(name, message: "Deleted “\(profile.name)”.", payload: payload)
            }
        }
    }

    private func renameProfile(address: String, newName: String, timeout: Duration, name: String) async -> ExternalResult {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await resolveProfile(address, name: name) {
        case let .failed(result): return result
        case let .found(profile):
            return await withExclusive(timeout: timeout, refusePreview: true, name: name) {
                let listed = await profiles.list()
                if listed.profiles.contains(where: {
                    $0.id != profile.id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                }) {
                    return failure(name, code: "conflict", exit: 6, message: "Name already in use.", reason: "nameInUse")
                }
                try await profiles.rename(id: profile.id, newName: trimmed)
                let updated = try await profiles.load(id: profile.id)
                var payload = ExternalPayload()
                payload.profile = ref(updated)
                return success(name, message: "Renamed to “\(updated.name)”.", payload: payload)
            }
        }
    }

    private func duplicateProfile(address: String, newName: String, timeout: Duration, name: String) async -> ExternalResult {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await resolveProfile(address, name: name) {
        case let .failed(result): return result
        case let .found(profile):
            return await withExclusive(timeout: timeout, refusePreview: true, name: name) {
                let listed = await profiles.list()
                if listed.profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                    return failure(name, code: "conflict", exit: 6, message: "Name already in use.", reason: "nameInUse")
                }
                var copy = try await profiles.duplicate(id: profile.id, newName: trimmed)
                copy.hotkey = nil
                try await profiles.save(copy)
                var payload = ExternalPayload()
                payload.profile = ref(copy)
                return success(name, message: "Duplicated as “\(copy.name)”.", payload: payload)
            }
        }
    }

    private func undoChange(request: ExternalRequest, timeout: Duration, name: String) async -> ExternalResult {
        await withMutation(timeout: timeout, name: name) {
            let id = try await undo.undo(expecting: nil, controlSource: request.source)
            var payload = ExternalPayload()
            payload.snapshotID = id.uuidString
            payload.restarted = true
            payload.source = request.source.rawValue
            return success(name, message: "Undo complete.", payload: payload)
        }
    }

    private func listSnapshots(name: String) async -> ExternalResult {
        let listed = await snapshots.list()
        var payload = ExternalPayload()
        payload.snapshots = listed.snapshots.map(snapshotEntry)
        payload.unreadable = listed.failures.map {
            ExternalPayload.UnreadableEntry(path: $0.url.path, message: String(describing: $0.error))
        }
        return success(name, message: "Listed \(listed.snapshots.count) snapshot(s).", payload: payload)
    }

    private func pinSnapshot(id: UUID, timeout: Duration, name: String) async -> ExternalResult {
        await withExclusive(timeout: timeout, refusePreview: true, name: name) {
            try await snapshots.pin(id: id)
            return success(name, message: "Pinned.", payload: nil)
        }
    }

    private func unpinSnapshot(id: UUID, timeout: Duration, name: String) async -> ExternalResult {
        await withExclusive(timeout: timeout, refusePreview: true, name: name) {
            try await snapshots.unpin(id: id)
            return success(name, message: "Unpinned.", payload: nil)
        }
    }

    private func deleteSnapshot(request: ExternalRequest, id: UUID, timeout: Duration, name: String) async -> ExternalResult {
        guard request.yes else {
            return failure(name, code: "usage", exit: 2, message: "snapshots delete requires --yes.")
        }
        return await withExclusive(timeout: timeout, refusePreview: true, name: name) {
            try await snapshots.delete(id: id)
            return success(name, message: "Snapshot deleted.", payload: nil)
        }
    }

    private func restoreSnapshot(request: ExternalRequest, id: UUID, timeout: Duration, name: String) async -> ExternalResult {
        guard request.yes else {
            return failure(name, code: "usage", exit: 2, message: "restore requires --yes.")
        }
        return await withMutation(timeout: timeout, name: name) {
            try await restorer.restore(id: id, source: request.source)
            var payload = ExternalPayload()
            payload.snapshotID = id.uuidString
            payload.restarted = true
            payload.source = request.source.rawValue
            return success(name, message: "Snapshot restored.", payload: payload)
        }
    }

    private func exportProfile(
        address: String,
        format: ExportFormat,
        output: URL?,
        force: Bool,
        timeout: Duration,
        name: String
    ) async -> ExternalResult {
        switch await resolveProfile(address, name: name) {
        case let .failed(result): return result
        case let .found(profile):
            return await withShared(timeout: timeout, name: name) {
                let document: String
                switch format {
                case .json:
                    let data = try ProfileExchange.export(profile)
                    document = String(decoding: data, as: UTF8.self)
                case .script:
                    document = try DockutilScriptExporter.export(profile)
                }
                if let output {
                    if !force, FileManager.default.fileExists(atPath: output.path) {
                        return failure(name, code: "conflict", exit: 6, message: "Output file exists.", reason: "nameInUse")
                    }
                    try document.write(to: output, atomically: true, encoding: .utf8)
                    var payload = ExternalPayload()
                    payload.format = format.rawValue
                    payload.path = output.path
                    return success(name, message: "Exported.", payload: payload)
                }
                var payload = ExternalPayload()
                payload.format = format.rawValue
                payload.document = document
                return success(name, message: "Exported.", payload: payload)
            }
        }
    }

    private func importProfile(
        source: ImportSource,
        overrideName: String?,
        timeout: Duration,
        name: String
    ) async -> ExternalResult {
        // Read and sanitize before taking operation.lock: stdin may block indefinitely.
        let sanitized: SanitizedProfile
        do {
            let data: Data
            switch source {
            case let .file(url):
                if url.scheme?.hasPrefix("http") == true {
                    return failure(name, code: "usage", exit: 2, message: "HTTP URLs are not supported.")
                }
                data = try Data(contentsOf: url)
            case .stdin:
                data = try Data(FileHandle.standardInput.readToEnd() ?? Data())
            }
            sanitized = try ProfileExchange.importProfile(from: data)
        } catch {
            return internalFailure(name, error)
        }
        let profile: Profile = {
            var imported = sanitized.profile
            if let overrideName { imported.name = overrideName }
            return imported
        }()
        return await withExclusive(timeout: timeout, refusePreview: true, name: name) {
            let listed = await profiles.list()
            if listed.profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }) {
                return failure(name, code: "conflict", exit: 6, message: "Name already in use.", reason: "nameInUse")
            }
            try await profiles.save(profile)
            var payload = ExternalPayload()
            payload.profile = ref(profile)
            payload.changes = sanitized.changes.map { change in
                ExternalPayload.ImportChangeEntry(kind: importChangeKind(change), detail: importChangeDetail(change))
            }
            return success(name, message: "Imported “\(profile.name)”.", payload: payload)
        }
    }

    private func status(name: String) async -> ExternalResult {
        let support = (try? SupportPaths.root())?.path ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
        let lockHeld = locks.isOperationHeld()
        let previewHeld = locks.isPreviewHeld()
        let all = await sortedProfiles()
        let currentDock = try? await dock.read()
        let lastApplied = activeRecord.load()
        let match = currentDock.map {
            ActiveProfileMatcher.match(profiles: all, current: $0, lastAppliedID: lastApplied)
        }
        var payload = ExternalPayload()
        payload.appRunning = running
        payload.bundleId = bundleID
        payload.lock = lockHeld ? "held" : "free"
        payload.preview = previewHeld ? "active" : "inactive"
        if let primary = match?.primary {
            payload.activeProfile = ref(primary)
            payload.dockMatchesActive = true
        } else {
            payload.dockMatchesActive = false
        }
        payload.externalControl = externalControlSetting()
        payload.supportDir = support
        payload.version = OhMyDockCore.version
        return success(name, message: "Status.", payload: payload)
    }

    private func doctor(name: String) async -> ExternalResult {
        var checks: [ExternalPayload.DoctorCheck] = []
        if let url = dockutilURL, FileManager.default.isExecutableFile(atPath: url.path) {
            checks.append(.init(name: "dockutil", status: "pass", detail: url.path))
        } else {
            checks.append(.init(name: "dockutil", status: "fail", detail: "Missing or not executable."))
        }
        do {
            let root = try SupportPaths.ensureRootExists()
            checks.append(.init(name: "support", status: "pass", detail: root.path))
        } catch {
            checks.append(.init(name: "support", status: "fail", detail: String(describing: error)))
        }
        let listed = await profiles.list()
        if listed.failures.isEmpty {
            checks.append(.init(name: "profiles", status: "pass", detail: "\(listed.profiles.count) profile(s)."))
        } else {
            checks.append(.init(name: "profiles", status: "warn", detail: "\(listed.failures.count) unreadable file(s)."))
        }
        let names = listed.profiles.map(\.name)
        let dupes = Dictionary(grouping: names, by: { $0.lowercased() }).filter { $0.value.count > 1 }
        if !dupes.isEmpty {
            checks.append(.init(name: "profiles", status: "warn", detail: "Duplicate profile names on disk."))
        }
        let snaps = await snapshots.list()
        checks.append(.init(
            name: "snapshots",
            status: snaps.failures.isEmpty ? "pass" : "warn",
            detail: "\(snaps.snapshots.count) snapshot(s)."
        ))
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
        if !running {
            checks.append(.init(name: "app", status: "warn", detail: "Menu-bar app is not running."))
        }
        if locks.isOperationHeld() {
            checks.append(.init(name: "operationLock", status: "warn", detail: "Held by another process."))
        }
        if locks.isPreviewHeld() {
            checks.append(.init(name: "previewLock", status: "warn", detail: "Dock preferences preview is active."))
        }
        if OhMyDockProcessEnvironment.string(for: DockPlistEnvironment.overrideKey) != nil {
            do {
                _ = try DockPlistEnvironment.resolvedOverridePlist()
                checks.append(.init(name: "plistOverride", status: "warn", detail: "Test plist override is active."))
            } catch DockPlistEnvironmentError.liveDockPlistRefused {
                checks.append(.init(name: "plistOverride", status: "fail", detail: "Points at the live Dock plist."))
            } catch {
                checks.append(.init(name: "plistOverride", status: "warn", detail: "Override set."))
            }
        }
        var payload = ExternalPayload()
        payload.checks = checks
        let failed = checks.contains { $0.status == "fail" }
        if failed {
            return ExternalResult(
                exitCode: 0,
                message: "Doctor found failures.",
                envelope: ExternalEnvelope(command: name, ok: false, result: payload, error: ExternalErrorInfo(
                    code: "internal",
                    exitCode: 0,
                    message: "Doctor found failures."
                ))
            )
        }
        return success(name, message: "Doctor checks passed.", payload: payload)
    }

    // MARK: - Helpers

    private func ref(_ profile: Profile) -> ExternalPayload.ProfileRef {
        ExternalPayload.ProfileRef(id: profile.id.uuidString, name: profile.name)
    }

    private func snapshotEntry(_ snapshot: Snapshot) -> ExternalPayload.SnapshotEntry {
        ExternalPayload.SnapshotEntry(
            id: snapshot.id.uuidString,
            createdAt: iso8601(snapshot.createdAt),
            reason: snapshot.reason,
            profileName: snapshot.profileName,
            pinned: snapshot.pinned,
            byteSize: snapshot.byteSize,
            sha256: snapshot.sha256,
            source: snapshot.source?.rawValue
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func encodePrefsTarget(_ value: DockPrefs.Value?) -> ExternalPayload.PrefsDiffTarget {
        guard let value else { return .null }
        switch value {
        case .bool(let flag): return .bool(flag)
        case .double(let number): return .double(number)
        case .string(let text): return .string(text)
        }
    }

    private func externalControlSetting() -> String {
        let defaults = UserDefaults(suiteName: bundleID)
        guard let raw = defaults?.string(forKey: "externalControl") else { return "ask" }
        return raw
    }

    private func needsConfirmation(_ name: String, preview: ApplyPreview, reason: String) -> ExternalResult {
        let quitApps = preview.willQuitApps.map { ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "") }
        let skipped = preview.skipped.map {
            ExternalAppRef(
                name: $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name,
                bundleId: $0.app.bundleId,
                section: $0.section.rawValue
            )
        }
        let launch = (preview.switchPlan?.willLaunch ?? []).map {
            ExternalAppRef(name: $0.name, bundleId: $0.bundleId ?? "")
        }
        let message: String
        if !quitApps.isEmpty {
            message = "Switching would quit \(quitApps.count) app(s) and needs confirmation: "
                + quitApps.map(\.name).joined(separator: ", ")
        } else {
            message = "Switching needs confirmation."
        }
        var payload = ExternalPayload()
        payload.confirmationRequired = true
        payload.willQuit = quitApps
        payload.skipped = skipped
        payload.willLaunch = launch
        return ExternalResult(
            exitCode: 5,
            message: message,
            envelope: ExternalEnvelope(
                command: name,
                ok: false,
                result: payload,
                error: ExternalErrorInfo(
                    code: "needsConfirmation",
                    exitCode: 5,
                    message: message,
                    reason: reason,
                    quitApps: quitApps,
                    launchApps: launch,
                    skippedApps: skipped
                )
            )
        )
    }

    private func mapApplyError(_ error: ApplyError, name: String, preview: ApplyPreview?) -> ExternalResult {
        switch error {
        case .confirmationRequired, .quitConfirmationRequired:
            if let preview {
                return needsConfirmation(name, preview: preview, reason: "quit")
            }
            return failure(name, code: "needsConfirmation", exit: 5, message: error.localizedDescription ?? "Confirmation required.")
        case .dockChanged:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Dock changed.", reason: "dockChanged")
        case .wouldEmptySection:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Would empty section.", reason: "wouldEmptySection")
        case .unsatisfiable:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Unsatisfiable.", reason: "unsatisfiable")
        case .invalidProfile:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Invalid.", reason: "invalidProfile")
        case .prefsRejected:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Prefs rejected.", reason: "prefsRejected")
        case .rejectedByBackend:
            return failure(name, code: "conflict", exit: 6, message: error.localizedDescription ?? "Rejected.", reason: "rejectedByBackend")
        case .failedAndRolledBack:
            return failure(name, code: "rolledBack", exit: 8, message: error.localizedDescription ?? "Rolled back.", reason: "rolledBack")
        case let .rollbackFailed(_, _, snapshotID):
            return failure(name, code: "rollbackFailed", exit: 8, message: error.localizedDescription ?? "Rollback failed.", reason: "rollbackFailed", snapshotID: snapshotID)
        case .prefsUnavailable:
            return failure(name, code: "internal", exit: 1, message: error.localizedDescription ?? "Prefs unavailable.")
        }
    }

    private func locked(_ name: String, reason: LockBusyReason) -> ExternalResult {
        let message = reason == .previewActive ? OperationLock.previewActiveMessage : "Another oh-my-dock operation is in progress."
        return failure(name, code: "locked", exit: 7, message: message, reason: reason.rawValue)
    }

    private func success(_ command: String, message: String, payload: ExternalPayload?) -> ExternalResult {
        ExternalResult(
            exitCode: 0,
            message: message,
            envelope: ExternalEnvelope(command: command, ok: true, result: payload)
        )
    }

    private func failure(
        _ command: String,
        code: String,
        exit: Int,
        message: String,
        reason: String? = nil,
        matches: [ProfileMatch]? = nil,
        snapshotID: UUID? = nil
    ) -> ExternalResult {
        ExternalResult(
            exitCode: exit,
            message: message,
            envelope: ExternalEnvelope(
                command: command,
                ok: false,
                error: ExternalErrorInfo(
                    code: code,
                    exitCode: exit,
                    message: message,
                    reason: reason,
                    matches: matches,
                    snapshotID: snapshotID
                )
            )
        )
    }

    private func internalFailure(_ command: String, _ error: any Error) -> ExternalResult {
        failure(command, code: "internal", exit: 1, message: String(describing: error))
    }

    private func importChangeKind(_ change: ImportSanitizationChange) -> String {
        switch change {
        case .droppedItem: "droppedItem"
        case .droppedItemsOverLimit: "droppedItemsOverLimit"
        case .clearedAppPath: "clearedAppPath"
        case .clearedBrewCask: "clearedBrewCask"
        case .clearedLaunchOnSwitch: "clearedLaunchOnSwitch"
        case .truncatedString: "truncatedString"
        case let .forcedQuitScopeNone(was): "forcedQuitScopeNone"
        case .clearedOfferForceQuit: "clearedOfferForceQuit"
        case .clearedQuitOnAutomaticSwitch: "clearedQuitOnAutomaticSwitch"
        case .idReassigned: "idReassigned"
        }
    }

    private func importChangeDetail(_ change: ImportSanitizationChange) -> String? {
        switch change {
        case let .forcedQuitScopeNone(was): was.rawValue
        case let .truncatedString(field): field
        default: nil
        }
    }
}
