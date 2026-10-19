import Foundation
import Observation
import OhMyDockCore

/// What the view model needs from `UpdateChecker`; tests use a fake so nothing hits the network.
protocol UpdateChecking: Sendable {
    func check(currentVersion: String) async throws -> UpdateCheckResult
}

extension UpdateChecker: UpdateChecking {}

/// Opens a release page in the browser. Live code uses `NSWorkspace`; tests record the URL.
protocol ReleasePageOpening {
    @MainActor func open(_ url: URL)
}

/// Drives the "new version available" notice. It only ever reads the latest release from GitHub
/// and opens its page on request: nothing is downloaded or installed, and nothing is sent beyond
/// the request itself.
@MainActor
@Observable
final class UpdateViewModel {
    static let autoCheckKey = "updates.autoCheckEnabled"
    static let lastCheckKey = "updates.lastCheckDate"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// A newer release, once one has been found.
    private(set) var availableUpdate: ReleaseInfo?
    private(set) var isChecking = false
    /// Short result of the last *manual* check ("You're up to date", or why it failed).
    private(set) var manualMessage: String?

    var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Self.autoCheckKey) }
    }

    @ObservationIgnored private let checker: any UpdateChecking
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let opener: any ReleasePageOpening

    init(
        checker: any UpdateChecking,
        defaults: UserDefaults = .standard,
        currentVersion: String,
        opener: any ReleasePageOpening,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.opener = opener
        self.now = now
        // On by default: only an explicit `false` turns it off.
        autoCheckEnabled = defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true
    }

    var lastCheckDate: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    /// Background check: does nothing when the toggle is off or the last check was under 24h ago,
    /// and fails silently. Safe to call as often as convenient (launch, popover open).
    func checkIfDue() async {
        guard autoCheckEnabled, !isChecking else { return }
        if let last = lastCheckDate {
            let elapsed = now().timeIntervalSince(last)
            // A last-check date in the future (clock change) counts as due.
            if elapsed >= 0, elapsed < Self.checkInterval { return }
        }
        _ = await perform()
    }

    /// The Settings button: ignores the toggle and the throttle, and reports the outcome.
    func checkNow() async {
        guard !isChecking else { return }
        manualMessage = nil
        switch await perform() {
        case .upToDate: manualMessage = "You’re up to date (v\(currentVersion))."
        case let .available(info): manualMessage = "Version \(info.version) is available."
        case let .failed(message): manualMessage = message
        }
    }

    func openReleasePage() {
        guard let url = availableUpdate?.pageURL else { return }
        opener.open(url)
    }

    private enum Outcome {
        case upToDate
        case available(ReleaseInfo)
        case failed(String)
    }

    private func perform() async -> Outcome {
        isChecking = true
        defer { isChecking = false }
        // Recorded per attempt (not just success) so a failing network or a rate limit is not hammered.
        defaults.set(now(), forKey: Self.lastCheckKey)
        do {
            switch try await checker.check(currentVersion: currentVersion) {
            case .upToDate:
                availableUpdate = nil
                return .upToDate
            case let .available(info):
                availableUpdate = info
                return .available(info)
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "Could not check for updates.")
        }
    }
}
