import Foundation

/// Mirror of `NSApplication.ActivationPolicy`, so the switching logic and its tests don't depend on AppKit.
public enum AppActivationPolicy: String, Hashable, Sendable {
    case regular
    case accessory
    case prohibited
}

/// A snapshot of one running process. Several instances can share a `bundleId`; `processIdentifier` tells them apart.
public struct RunningAppInfo: Hashable, Sendable, Identifiable {
    public var processIdentifier: Int32
    /// Nil for processes without a bundle identifier. Those are never quit.
    public var bundleId: String?
    public var name: String
    public var activationPolicy: AppActivationPolicy
    public var isFinishedLaunching: Bool

    public var id: Int32 { processIdentifier }

    public init(
        processIdentifier: Int32,
        bundleId: String?,
        name: String,
        activationPolicy: AppActivationPolicy = .regular,
        isFinishedLaunching: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.bundleId = bundleId
        self.name = name
        self.activationPolicy = activationPolicy
        self.isFinishedLaunching = isFinishedLaunching
    }
}

/// Lists running apps and sends quit requests. The only code that may touch real processes is the live
/// implementation (`LiveRunningApps`); tests use `FakeRunningApps`.
public protocol RunningAppsProviding: Sendable {
    func runningApps() -> [RunningAppInfo]
    /// Graceful quit request (same as ⌘Q). `true` means the request was sent, not that the app quit.
    func terminate(_ app: RunningAppInfo) -> Bool
    /// Forced quit. Unsaved work is lost. Behavior is unverified (see docs/technical-notes.md); only
    /// `AppSwitcher.forceQuit` calls this, after an explicit user action.
    func forceTerminate(_ app: RunningAppInfo) -> Bool
}

/// What to launch. `path` is only a hint; the app is resolved by `bundleId` first.
public struct LaunchRequest: Hashable, Sendable {
    public var bundleId: String
    public var name: String
    public var path: String?
    /// Launch hidden (`OpenConfiguration.hides`). Launches never activate the app.
    public var hidden: Bool

    public init(bundleId: String, name: String, path: String? = nil, hidden: Bool = false) {
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.hidden = hidden
    }
}

public enum AppLaunchError: Error, Hashable, Sendable, LocalizedError {
    case notInstalled(bundleId: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let bundleId): "App \(bundleId) is not installed"
        }
    }
}

/// Launches an app in the background (`activates = false`).
public protocol AppLauncher: Sendable {
    func launch(_ request: LaunchRequest) async throws
}

/// Monotonic time plus sleeping, so timeouts are testable without real waiting.
public protocol SwitchClock: Sendable {
    /// Monotonic offset from an arbitrary origin.
    var now: Duration { get }
    /// Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

public struct SystemSwitchClock: SwitchClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { origin.duration(to: .now) }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

func normalizedBundleId(_ bundleId: String?) -> String? {
    guard let trimmed = bundleId?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
    return trimmed.lowercased()
}
