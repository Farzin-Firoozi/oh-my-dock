import Foundation

public enum QuitStatus: Hashable, Sendable {
    /// Exited after `terminate()`.
    case quit
    /// Gone before we asked (or `terminate()` returned false because it had just exited).
    case alreadyExited
    /// `terminate()` returned false while the app is still running.
    case refused
    /// Asked to quit, still running when the timeout ended: save sheet, veto, `.terminateLater`, hung.
    /// Left alone. Never force quit automatically.
    case stillRunningAfterTimeout
    /// Asked to quit, but the switch was cancelled while waiting and the app is still running.
    case quitRequestedUnconfirmed
    /// Re-check just before quitting found the app protected or not regular. Not asked to quit.
    case skippedProtected
    /// Switch cancelled before this app was asked. Not asked to quit.
    case skippedCancelled

    /// Still running after we asked: the UI reports these, and may offer force quit.
    public var isStraggler: Bool {
        switch self {
        case .refused, .stillRunningAfterTimeout, .quitRequestedUnconfirmed: true
        default: false
        }
    }
}

public struct QuitResult: Hashable, Sendable {
    public let app: RunningAppInfo
    public let status: QuitStatus
}

public enum LaunchStatus: Hashable, Sendable {
    case launched
    /// Already running when its turn came; not relaunched.
    case alreadyRunning
    case failed(String)
    case skippedCancelled
}

public struct LaunchResult: Hashable, Sendable {
    public let request: LaunchRequest
    public let status: LaunchStatus
}

/// Per-app result of a switch.
public struct SwitchOutcome: Hashable, Sendable {
    public var quits: [QuitResult]
    public var launches: [LaunchResult]
    /// The switch stopped early; quits that already happened are not rolled back.
    public var wasCancelled: Bool

    public init(quits: [QuitResult] = [], launches: [LaunchResult] = [], wasCancelled: Bool = false) {
        self.quits = quits
        self.launches = launches
        self.wasCancelled = wasCancelled
    }

    public var quitCount: Int { quits.filter { $0.status == .quit }.count }
    public var stragglers: [RunningAppInfo] { quits.filter { $0.status.isStraggler }.map(\.app) }
    public var launchFailures: [LaunchResult] {
        launches.filter { if case .failed = $0.status { true } else { false } }
    }

    /// One line for notifications, e.g. "Quit 3, Safari refused, Notes still running".
    public var summary: String {
        var parts: [String] = []
        if quitCount > 0 { parts.append("Quit \(quitCount)") }
        for q in quits {
            switch q.status {
            case .refused: parts.append("\(q.app.name) refused")
            case .stillRunningAfterTimeout, .quitRequestedUnconfirmed: parts.append("\(q.app.name) still running")
            default: break
            }
        }
        for l in launches {
            if case .failed = l.status { parts.append("\(l.request.name) failed to launch") }
        }
        if wasCancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

public enum ForceQuitResult: Hashable, Sendable {
    /// `offerForceQuit` is off. Nothing was done.
    case notOffered
    /// The app wasn't a straggler in the given outcome. Nothing was done.
    case notAStraggler
    /// The app is protected or no longer regular. Nothing was done.
    case protected
    case alreadyExited
    /// `forceTerminate()` returned false.
    case failed
    case terminated
    case stillRunningAfterTimeout
}
