import Foundation

/// Quits, keeps and launches apps when switching profiles. SAFETY-CRITICAL: a bug here can lose unsaved work.
///
/// Rules:
/// - Quits are graceful `terminate()` only (⌘Q semantics: save sheets and vetoes are honored).
/// - Apps still running after the per-app timeout are **reported**, never force quit by `execute`.
///   `forceQuit` is a separate method for the UI to call after an explicit user click, and only when
///   `SwitchingOptions.offerForceQuit` is on. `forceTerminate()` behavior is unverified
///   (docs/technical-notes.md), so verify it before shipping the UI.
/// - Before every quit the app is looked up again and the never-quit/regular checks re-run, so a stale
///   plan can't quit an app that exited, was replaced by a different process, or is protected.
/// - Cancellation (`Task.cancel()`, or a newer switch superseding this one via `SwitchQueue`) stops before
///   the next app is asked to quit and skips the launch phase. Quits that already happened are **not
///   rolled back**: relaunching would not restore the apps' windows or unsaved state, and an app the user
///   saved and closed would reopen unexpectedly. The outcome lists exactly what happened.
/// - Quits run one app at a time, so a save sheet is visible before the next app is asked.
///   Worst case is `quitTimeout` per straggler.
///
/// Run from the main actor (or with a live run loop): `NSRunningApplication` state only updates while it runs.
public struct AppSwitcher: Sendable {
    public let provider: any RunningAppsProviding
    public let launcher: any AppLauncher
    public let clock: any SwitchClock
    public let neverQuit: NeverQuitPolicy
    public let quitTimeout: Duration
    public let forceQuitTimeout: Duration
    public let pollInterval: Duration

    public init(
        provider: any RunningAppsProviding,
        launcher: any AppLauncher,
        clock: any SwitchClock = SystemSwitchClock(),
        neverQuit: NeverQuitPolicy,
        quitTimeout: Duration = .seconds(5),
        forceQuitTimeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.provider = provider
        self.launcher = launcher
        self.clock = clock
        self.neverQuit = neverQuit
        self.quitTimeout = quitTimeout
        self.forceQuitTimeout = forceQuitTimeout
        self.pollInterval = pollInterval
    }

    /// Plans against the provider's current running apps.
    public func plan(from source: Profile?, to target: Profile) -> SwitchPlan {
        Self.plan(from: source, to: target, running: provider.runningApps(), neverQuit: neverQuit)
    }

    // MARK: - Execute

    /// Quit phase, then launch phase. Never throws and never force quits.
    public func execute(_ plan: SwitchPlan) async -> SwitchOutcome {
        var outcome = SwitchOutcome()

        for app in plan.willQuit {
            if Task.isCancelled || outcome.wasCancelled {
                outcome.wasCancelled = true
                outcome.quits.append(QuitResult(app: app, status: .skippedCancelled))
                continue
            }
            let status = await quit(app)
            outcome.quits.append(QuitResult(app: app, status: status))
            if status == .quitRequestedUnconfirmed { outcome.wasCancelled = true }
        }

        for request in plan.willLaunch {
            if Task.isCancelled || outcome.wasCancelled {
                outcome.wasCancelled = true
                outcome.launches.append(LaunchResult(request: request, status: .skippedCancelled))
                continue
            }
            outcome.launches.append(LaunchResult(request: request, status: await launch(request)))
        }
        return outcome
    }

    private func quit(_ planned: RunningAppInfo) async -> QuitStatus {
        guard let app = currentInfo(of: planned) else { return .alreadyExited }
        guard app.activationPolicy == .regular, !neverQuit.protects(app) else { return .skippedProtected }

        guard provider.terminate(app) else {
            return currentInfo(of: app) == nil ? .alreadyExited : .refused
        }
        switch await waitForExit(of: app, timeout: quitTimeout) {
        case .exited: return .quit
        case .timedOut: return .stillRunningAfterTimeout
        case .cancelled: return .quitRequestedUnconfirmed
        }
    }

    private func launch(_ request: LaunchRequest) async -> LaunchStatus {
        let id = normalizedBundleId(request.bundleId)
        if provider.runningApps().contains(where: { normalizedBundleId($0.bundleId) == id }) {
            return .alreadyRunning
        }
        do {
            try await launcher.launch(request)
            return .launched
        } catch is CancellationError {
            return .skippedCancelled
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Force quit

    /// Force quits one straggler. Call only after the user explicitly asked for it for this app.
    ///
    /// Refuses unless `options.offerForceQuit` is on and `app` is a straggler in `outcome`. Re-checks the
    /// never-quit list and activation policy. `forceTerminate()` behavior is unverified.
    public func forceQuit(
        _ app: RunningAppInfo,
        after outcome: SwitchOutcome,
        options: SwitchingOptions
    ) async -> ForceQuitResult {
        guard options.offerForceQuit else { return .notOffered }
        guard outcome.stragglers.contains(app) else { return .notAStraggler }
        guard let current = currentInfo(of: app) else { return .alreadyExited }
        guard current.activationPolicy == .regular, !neverQuit.protects(current) else { return .protected }
        guard provider.forceTerminate(current) else {
            return currentInfo(of: current) == nil ? .terminated : .failed
        }
        return switch await waitForExit(of: current, timeout: forceQuitTimeout) {
        case .exited: .terminated
        case .timedOut, .cancelled: .stillRunningAfterTimeout
        }
    }

    // MARK: - Helpers

    /// The live process matching `app` (same pid and bundle id), or nil when it has exited. Matching the
    /// bundle id too guards against pid reuse.
    private func currentInfo(of app: RunningAppInfo) -> RunningAppInfo? {
        provider.runningApps().first {
            $0.processIdentifier == app.processIdentifier
                && normalizedBundleId($0.bundleId) == normalizedBundleId(app.bundleId)
        }
    }

    private enum WaitResult { case exited, timedOut, cancelled }

    private func waitForExit(of app: RunningAppInfo, timeout: Duration) async -> WaitResult {
        let deadline = clock.now + timeout
        while true {
            if currentInfo(of: app) == nil { return .exited }
            let remaining = deadline - clock.now
            if remaining <= .zero { return .timedOut }
            do {
                try await clock.sleep(for: min(pollInterval, remaining))
            } catch {
                return currentInfo(of: app) == nil ? .exited : .cancelled
            }
        }
    }
}
