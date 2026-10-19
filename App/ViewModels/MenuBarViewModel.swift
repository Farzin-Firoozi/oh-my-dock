import Foundation
import Observation
import OhMyDockCore

/// State and actions behind the menu bar popover. Depends only on protocols, so tests drive it with
/// `FakeDockBackend` and in-memory stores; the real services are wired in `AppEnvironment`.
@MainActor
@Observable
final class MenuBarViewModel {
    struct Banner: Equatable {
        enum Kind: Equatable { case success, failure }
        let kind: Kind
        let message: String
    }

    /// A profile whose apps are missing: applying it needs the user's say-so.
    struct Confirmation: Equatable {
        let profileName: String
        let skippedApps: [String]
        let clearsRecentApps: Bool
        let preview: ApplyPreview?

        init(
            profileName: String,
            skippedApps: [String],
            clearsRecentApps: Bool,
            preview: ApplyPreview? = nil
        ) {
            self.profileName = profileName
            self.skippedApps = skippedApps
            self.clearsRecentApps = clearsRecentApps
            self.preview = preview
        }

        static func == (lhs: Confirmation, rhs: Confirmation) -> Bool {
            lhs.profileName == rhs.profileName &&
                lhs.skippedApps == rhs.skippedApps &&
                lhs.clearsRecentApps == rhs.clearsRecentApps &&
                (lhs.preview == nil || rhs.preview == nil || lhs.preview == rhs.preview)
        }
    }

    enum Activity: Equatable {
        case applying(profileName: String)
        case undoing
        case saving
    }

    // MARK: Observed state

    private(set) var profiles: [Profile] = []
    private(set) var activeProfileID: UUID?
    private(set) var undoTarget: UndoTarget?
    private(set) var activity: Activity?
    private(set) var confirmation: Confirmation?
    private(set) var banner: Banner?
    var isNamingProfile = false
    var newProfileName = ""
    var showsDiffSheet = false

    var isBusy: Bool { activity != nil }
    var canUndo: Bool { undoTarget != nil && !isBusy }

    // MARK: Dependencies

    @ObservationIgnored private let library: any ProfileLibrary
    @ObservationIgnored private let dock: any DockBackend
    @ObservationIgnored private let applier: any ProfileApplying
    @ObservationIgnored private let undoer: any DockUndoing
    @ObservationIgnored private let bootstrap: (@Sendable () async throws -> Void)?

    @ObservationIgnored private var lastAppliedID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var pendingConfirmation: CheckedContinuation<Bool, Never>?

    init(
        library: any ProfileLibrary,
        dock: any DockBackend,
        applier: any ProfileApplying,
        undoer: any DockUndoing,
        bootstrap: (@Sendable () async throws -> Void)? = nil
    ) {
        self.library = library
        self.dock = dock
        self.applier = applier
        self.undoer = undoer
        self.bootstrap = bootstrap
    }

    // MARK: Lifecycle

    /// Runs the first-launch capture (if any), then loads profiles, the active profile and undo.
    func start() async {
        if let bootstrap {
            do {
                try await bootstrap()
            } catch {
                show(.failure, "First-launch capture failed: \(describe(error))")
            }
        }
        await refresh()
    }

    /// Reloads everything the popover shows. Never writes.
    func refresh() async {
        profiles = await library.profiles()
        undoTarget = await undoer.undoTarget()
        let current = try? await dock.read()
        activeProfileID = current.flatMap(activeProfile(in:))?.id
    }

    private func activeProfile(in current: DockState) -> Profile? {
        let matching = profiles.filter { $0.dockState.matchesAfterWrite(current) }
        return matching.first { $0.id == lastAppliedID } ?? matching.first
    }

    // MARK: Apply

    /// Starts applying `profile`; the popover's click handler. Use `cancelOperation()` to stop it.
    func apply(_ profile: Profile) {
        guard !isBusy else { return }
        operation = Task { await performApply(profile) }
    }

    func performApply(_ profile: Profile) async {
        guard !isBusy else { return }
        activity = .applying(profileName: profile.name)
        banner = nil
        defer { activity = nil }

        do {
            let result = try await applier.apply(profile) { [weak self] preview in
                guard let self else { return false }
                return await self.requestConfirmation(for: preview)
            }
            switch result {
            case let .applied(report):
                lastAppliedID = profile.id
                show(.success, appliedMessage(profile.name, skipped: report.skipped))
            case .noChanges:
                lastAppliedID = profile.id
                show(.success, "“\(profile.name)” is already on the Dock.")
            case let .cancelled(rolledBack):
                show(.success, rolledBack
                    ? "Cancelled. The previous Dock was restored."
                    : "Cancelled. The Dock was not changed.")
            }
        } catch {
            show(.failure, describe(error))
        }
        await refresh()
    }

    private func appliedMessage(_ name: String, skipped: [SkippedItem]) -> String {
        skipped.isEmpty ? "Applied “\(name)”." : "Applied “\(name)”, without \(skipped.count) missing app(s)."
    }

    // MARK: Confirmation

    /// The applier's `confirm` hook. Profiles that lose nothing apply without asking; otherwise the
    /// popover shows `confirmation` until `resolveConfirmation(_:)` (or a cancel) answers it.
    private func requestConfirmation(for preview: ApplyPreview) async -> Bool {
        guard !preview.skipped.isEmpty else { return true }
        resolveConfirmation(false) // at most one question at a time
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingConfirmation = continuation
                confirmation = Confirmation(
                    profileName: preview.profileName,
                    skippedApps: preview.skipped.map { $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name },
                    clearsRecentApps: preview.clearsRecentApps,
                    preview: preview
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveConfirmation(false) }
        }
    }

    func resolveConfirmation(_ accepted: Bool) {
        showsDiffSheet = false
        let continuation = pendingConfirmation
        pendingConfirmation = nil
        confirmation = nil
        continuation?.resume(returning: accepted)
    }

    /// Stops the running apply, declining any open question. The applier restores the Dock if it
    /// had already started writing.
    func cancelOperation() {
        showsDiffSheet = false
        resolveConfirmation(false)
        operation?.cancel()
    }

    // MARK: Undo

    func undoLastChange() {
        guard canUndo else { return }
        operation = Task { await performUndo() }
    }

    func performUndo() async {
        guard let target = undoTarget, !isBusy else { return }
        activity = .undoing
        banner = nil
        defer { activity = nil }
        do {
            try await undoer.undo(target)
            lastAppliedID = nil
            show(.success, "Restored the Dock from before the last change.")
        } catch {
            show(.failure, describe(error))
        }
        await refresh()
    }

    // MARK: Save current Dock

    func beginSavingCurrentDock() {
        guard !isBusy else { return }
        newProfileName = ""
        banner = nil
        isNamingProfile = true
    }

    func cancelSavingCurrentDock() {
        isNamingProfile = false
        newProfileName = ""
    }

    func saveNamedProfile() {
        guard !isBusy else { return }
        let name = newProfileName
        operation = Task { _ = await saveCurrentDock(as: name) }
    }

    /// Captures the live Dock into a new profile named `name`. Returns whether it was saved.
    @discardableResult
    func saveCurrentDock(as rawName: String) async -> Bool {
        guard !isBusy else { return false }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = nameProblem(name, existing: await library.profiles()) {
            show(.failure, problem)
            return false
        }

        activity = .saving
        banner = nil
        defer { activity = nil }
        do {
            let state = try await dock.read()
            let profile = Profile(name: name, apps: state.apps, others: state.others)
            try await library.save(profile)
            lastAppliedID = profile.id
            isNamingProfile = false
            newProfileName = ""
            show(.success, "Saved the current Dock as “\(name)”.")
            await refresh()
            return true
        } catch {
            show(.failure, "Could not save the Dock: \(describe(error))")
            return false
        }
    }

    private func nameProblem(_ name: String, existing: [Profile]) -> String? {
        if name.isEmpty { return "Enter a name for the profile." }
        if name.count > Profile.maxNameLength {
            return "Use a name of at most \(Profile.maxNameLength) characters."
        }
        if existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return "A profile named “\(name)” already exists."
        }
        return nil
    }

    // MARK: Banner

    func dismissBanner() { banner = nil }

    private func show(_ kind: Banner.Kind, _ message: String) {
        banner = Banner(kind: kind, message: message)
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
