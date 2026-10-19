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
        /// Running apps the switch would ask to quit.
        let quitApps: [String]
        /// Apps the switch would open.
        let launchApps: [String]

        init(
            profileName: String,
            skippedApps: [String],
            clearsRecentApps: Bool,
            preview: ApplyPreview? = nil,
            quitApps: [String] = [],
            launchApps: [String] = []
        ) {
            self.profileName = profileName
            self.skippedApps = skippedApps
            self.clearsRecentApps = clearsRecentApps
            self.preview = preview
            self.quitApps = quitApps
            self.launchApps = launchApps
        }

        static func == (lhs: Confirmation, rhs: Confirmation) -> Bool {
            lhs.profileName == rhs.profileName &&
                lhs.skippedApps == rhs.skippedApps &&
                lhs.clearsRecentApps == rhs.clearsRecentApps &&
                lhs.quitApps == rhs.quitApps &&
                lhs.launchApps == rhs.launchApps &&
                (lhs.preview == nil || rhs.preview == nil || lhs.preview == rhs.preview)
        }
    }

    /// Where an apply was started from. A hotkey apply may run while the popover is closed, so a
    /// question it raises is also put in front of the user by the `ConfirmationPresenting` hook.
    enum ApplySource: Equatable {
        case popover
        case hotkey
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
    var showsOutcomeSheet = false
    var latestOutcome: SwitchOutcome?
    var outcomeViewModel: SwitchOutcomeViewModel?

    var isBusy: Bool { activity != nil || gate.isBusy }
    /// What another window (the history window) is doing to the Dock, when this model is idle.
    var externalActivity: String? { activity == nil ? gate.current : nil }
    var canUndo: Bool { undoTarget != nil && !isBusy }

    // MARK: Dependencies

    @ObservationIgnored private let library: any ProfileLibrary
    @ObservationIgnored private let dock: any DockBackend
    @ObservationIgnored private let applier: any ProfileApplying
    @ObservationIgnored private let undoer: any DockUndoing
    @ObservationIgnored private let bootstrap: (@Sendable () async throws -> Void)?
    @ObservationIgnored private let gate: DockOperationGate
    @ObservationIgnored private let confirmationPresenter: (any ConfirmationPresenting)?
    @ObservationIgnored private let confirmationTimeout: Duration
    @ObservationIgnored private let appSwitcher: (any AppSwitching)?

    @ObservationIgnored private let activeRecord: any ActiveProfileRecording
    @ObservationIgnored private var lastAppliedID: UUID? {
        didSet { activeRecord.save(lastAppliedID) }
    }
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var pendingConfirmation: CheckedContinuation<ApplyConfirmResult, Never>?
    /// Identifies the open question, so a late answer from an old alert or timeout can't resolve a newer one.
    @ObservationIgnored private var confirmationToken = 0
    @ObservationIgnored private var confirmationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var confirmationTimedOut = false
    @ObservationIgnored private var applySource = ApplySource.popover

    init(
        library: any ProfileLibrary,
        dock: any DockBackend,
        applier: any ProfileApplying,
        undoer: any DockUndoing,
        bootstrap: (@Sendable () async throws -> Void)? = nil,
        gate: DockOperationGate = DockOperationGate(),
        activeRecord: any ActiveProfileRecording = InMemoryActiveProfileRecord(),
        confirmationPresenter: (any ConfirmationPresenting)? = nil,
        confirmationTimeout: Duration = .seconds(120),
        changes: DockChangeSignal = DockChangeSignal(),
        appSwitcher: (any AppSwitching)? = nil
    ) {
        self.gate = gate
        self.confirmationPresenter = confirmationPresenter
        self.confirmationTimeout = confirmationTimeout
        self.appSwitcher = appSwitcher
        self.activeRecord = activeRecord
        lastAppliedID = activeRecord.load()
        self.library = library
        self.dock = dock
        self.applier = applier
        self.undoer = undoer
        self.bootstrap = bootstrap
        // A history restore or delete changes what Undo would do; reload so it can't act on a stale target.
        changes.observe { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
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
    ///
    /// Latest call wins: `start()` and the popover's `.task` both refresh, and a refresh that began
    /// earlier but finishes later must not overwrite the newer one's result.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let loadedProfiles = await library.profiles()
        let target = await undoer.undoTarget()
        let current = try? await dock.read()
        guard generation == refreshGeneration else { return }
        profiles = loadedProfiles
        undoTarget = target
        activeProfileID = current.flatMap(activeProfile(in:))?.id
    }

    /// The profile the Dock currently shows. Of the profiles that match the Dock, the one applied
    /// last wins (it survives relaunches); failing that, the closest match: the one whose tiles
    /// equal the Dock's most exactly, labels and paths included, then the first by name.
    private func activeProfile(in current: DockState) -> Profile? {
        let matching = profiles.filter { $0.dockState.matchesAfterWrite(current) }
        if let id = lastAppliedID, let applied = matching.first(where: { $0.id == id }) { return applied }
        func exactTiles(_ profile: Profile) -> Int {
            DockSection.allCases.reduce(0) { total, section in
                total + zip(profile.dockState[section], current[section]).filter { $0 == $1 }.count
            }
        }
        // Only a strictly better score replaces the earlier candidate, so ties stay in name order.
        return matching.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return exactTiles(candidate) > exactTiles(best) ? candidate : best
        }
    }

    // MARK: Apply

    /// Starts applying `profile`; the popover's click handler. Use `cancelOperation()` to stop it.
    func apply(_ profile: Profile) {
        guard !isBusy else {
            show(.failure, "Another Dock change is already running. Try again when it finishes.")
            return
        }
        operation = Task { await performApply(profile) }
    }

    /// The hotkey entry point. Applies the latest stored version of the profile, not the copy the
    /// hotkey was registered with, and says so when it can't run.
    func applyFromHotkey(profileID: UUID) {
        guard !isBusy else {
            show(.failure, "Another Dock change is already running. Try again when it finishes.")
            return
        }
        operation = Task {
            guard let latest = await library.profiles().first(where: { $0.id == profileID }) else {
                show(.failure, "That profile no longer exists.")
                return
            }
            await performApply(latest, source: .hotkey)
        }
    }

    func performApply(_ profile: Profile, source: ApplySource = .popover) async {
        guard !isBusy else {
            if source == .hotkey { show(.failure, "Another Dock change is already running. Try again when it finishes.") }
            return
        }
        activity = .applying(profileName: profile.name)
        banner = nil
        applySource = source
        confirmationTimedOut = false
        defer { activity = nil }

        do {
            // The profile on the Dock now scopes which apps may be quit (the previous profile's).
            let previous = profiles.first { $0.id == (activeProfileID ?? lastAppliedID) && $0.id != profile.id }
            // A hotkey is an automatic source: it quits nothing unless the preview is confirmed.
            let trigger: ApplyTrigger = source == .popover ? .user : .automatic
            let result = try await gate.run("Applying “\(profile.name)”") {
                try await applier.apply(profile, from: previous, trigger: trigger) { [weak self] preview in
                    guard let self else { return .cancelled }
                    return await self.requestConfirmation(for: preview)
                }
            }
            switch result {
            case let .applied(report):
                lastAppliedID = profile.id
                show(.success, appliedMessage(profile.name, report: report))
                if let outcome = report.switchOutcome {
                    self.latestOutcome = outcome
                    self.outcomeViewModel = SwitchOutcomeViewModel(
                        outcome: outcome,
                        options: profile.switching,
                        switcher: self.appSwitcher,
                        onDismiss: { [weak self] in self?.showsOutcomeSheet = false }
                    )
                    if !outcome.stragglers.isEmpty || !outcome.launchFailures.isEmpty {
                        self.showsOutcomeSheet = true
                    }
                }
            case let .appsOnly(outcome):
                lastAppliedID = profile.id
                show(.success, "“\(profile.name)” is already on the Dock. " + appsMessage(outcome))
                self.latestOutcome = outcome
                self.outcomeViewModel = SwitchOutcomeViewModel(
                    outcome: outcome,
                    options: profile.switching,
                    switcher: self.appSwitcher,
                    onDismiss: { [weak self] in self?.showsOutcomeSheet = false }
                )
                if !outcome.stragglers.isEmpty || !outcome.launchFailures.isEmpty {
                    self.showsOutcomeSheet = true
                }
            case .noChanges:
                lastAppliedID = profile.id
                show(.success, "“\(profile.name)” is already on the Dock.")
            case let .cancelled(rolledBack):
                let reason = confirmationTimedOut ? "Timed out waiting for confirmation" : "Cancelled"
                show(confirmationTimedOut ? .failure : .success, rolledBack
                    ? "\(reason). The previous Dock was restored."
                    : "\(reason). The Dock was not changed.")
            }
        } catch {
            show(.failure, describe(error))
        }
        await refresh()
    }

    private func appliedMessage(_ name: String, report: ApplyReport) -> String {
        var message = report.skipped.isEmpty
            ? "Applied “\(name)”."
            : "Applied “\(name)”, without \(report.skipped.count) missing app(s)."
        if let outcome = report.switchOutcome { message += " " + appsMessage(outcome) }
        return message
    }

    /// What the app phase did. The Dock change stands even when it was cut short, and Undo does
    /// not reopen what was quit.
    private func appsMessage(_ outcome: SwitchOutcome) -> String {
        var message = outcome.summary + "."
        if outcome.quitCount > 0 { message += " Undo restores the Dock only; quit apps are not reopened." }
        return message
    }

    // MARK: Confirmation

    /// The applier's `confirm` hook. Profiles that lose nothing apply without asking; otherwise the
    /// popover shows `confirmation` until `resolveConfirmation(_:)` (or a cancel) answers it.
    private func requestConfirmation(for preview: ApplyPreview) async -> ApplyConfirmResult {
        guard preview.confirmationRequired else { return .accepted }
        resolveConfirmation(.cancelled) // at most one question at a time
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                confirmationToken += 1
                let token = confirmationToken
                pendingConfirmation = continuation
                let question = Confirmation(
                    profileName: preview.profileName,
                    skippedApps: preview.skipped.map { $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name },
                    clearsRecentApps: preview.clearsRecentApps,
                    preview: preview,
                    quitApps: preview.willQuitApps.map(\.name),
                    launchApps: (preview.switchPlan?.willLaunch ?? []).map(\.name)
                )
                confirmation = question
                // Nobody may be looking at the popover (a hotkey apply with the menu closed), so
                // hand the question to the presenter too, and never wait forever.
                if applySource == .hotkey {
                    confirmationPresenter?.present(question) { [weak self] (result: ApplyConfirmResult) in
                        self?.resolveConfirmation(result, token: token)
                    }
                }
                confirmationTimeoutTask = Task { [weak self, confirmationTimeout] in
                    try? await Task.sleep(for: confirmationTimeout)
                    guard !Task.isCancelled else { return }
                    self?.expireConfirmation(token: token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveConfirmation(.cancelled) }
        }
    }

    /// Answers the open question. With a `token`, only if that question is still the open one.
    func resolveConfirmation(_ result: ApplyConfirmResult, token: Int? = nil) {
        if let token, token != confirmationToken { return }
        showsDiffSheet = false
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        let continuation = pendingConfirmation
        pendingConfirmation = nil
        confirmation = nil
        if continuation != nil { confirmationPresenter?.dismiss() }
        continuation?.resume(returning: result)
    }

    func resolveConfirmation(_ accepted: Bool, token: Int? = nil) {
        resolveConfirmation(ApplyConfirmResult(accepted: accepted), token: token)
    }

    private func expireConfirmation(token: Int) {
        guard token == confirmationToken, pendingConfirmation != nil else { return }
        confirmationTimedOut = true
        resolveConfirmation(.cancelled, token: token)
    }

    /// Closes the diff sheet and returns to the confirmation card; the question stays open.
    func cancelDiffSheet() {
        showsDiffSheet = false
    }

    /// Stops the running apply, declining any open question. The applier restores the Dock if it
    /// had already started writing.
    func cancelOperation() {
        showsDiffSheet = false
        showsOutcomeSheet = false
        resolveConfirmation(.cancelled)
        operation?.cancel()
    }

    // MARK: Undo

    func undoLastChange() {
        guard canUndo else { return }
        operation = Task { await performUndo() }
    }

    func performUndo() async {
        guard let target = undoTarget, !isBusy else { return }
        // The service resolves the real target under the gate and refuses if it isn't `target`.
        activity = .undoing
        banner = nil
        defer { activity = nil }
        do {
            try await gate.run("Restoring the previous Dock") { try await undoer.undo(expecting: target.id) }
            lastAppliedID = nil
            show(.success, "Restored the Dock from before the last change. Apps that were quit are not reopened.")
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
