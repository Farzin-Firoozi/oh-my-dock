import Foundation

/// Virtual clock: `sleep` advances time instantly (after a yield, so concurrent tasks can interleave).
public final class FakeSwitchClock: SwitchClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var _sleeps: [Duration] = []

    public init() {}

    public var now: Duration { lock.withLock { elapsed } }
    public var sleeps: [Duration] { lock.withLock { _sleeps } }

    public func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        lock.withLock {
            elapsed += duration
            _sleeps.append(duration)
        }
    }
}

/// In-memory running apps for tests. Never touches a real process.
public final class FakeRunningApps: RunningAppsProviding, @unchecked Sendable {
    public enum Behavior: Hashable, Sendable {
        /// Exits as soon as it is asked to quit.
        case quitsImmediately
        /// Exits this long (virtual time) after being asked: a slow save, or `.terminateLater` that resolves.
        case quits(after: Duration)
        /// `terminate()` returns false.
        case refuses
        /// `terminate()` returns true but the app never exits: save sheet, veto, hung.
        case ignores
    }

    public enum Event: Hashable, Sendable {
        case terminate(Int32)
        case forceTerminate(Int32)
    }

    private struct Entry {
        var info: RunningAppInfo
        var behavior: Behavior
        var terminateRequestedAt: Duration?
        var forced = false
    }

    private let lock = NSLock()
    private let clock: FakeSwitchClock
    private var entries: [Entry] = []
    private var _events: [Event] = []
    /// Called synchronously inside `terminate`, on the calling task.
    private var _onTerminate: (@Sendable (RunningAppInfo) -> Void)?

    public init(clock: FakeSwitchClock) { self.clock = clock }

    public func add(_ info: RunningAppInfo, behavior: Behavior = .quitsImmediately) {
        lock.withLock { entries.append(Entry(info: info, behavior: behavior)) }
    }

    public func setOnTerminate(_ hook: (@Sendable (RunningAppInfo) -> Void)?) {
        lock.withLock { _onTerminate = hook }
    }

    public var events: [Event] { lock.withLock { _events } }
    public var terminated: [Int32] {
        events.compactMap { if case .terminate(let pid) = $0 { pid } else { nil } }
    }
    public var forceTerminated: [Int32] {
        events.compactMap { if case .forceTerminate(let pid) = $0 { pid } else { nil } }
    }

    public func runningApps() -> [RunningAppInfo] {
        lock.withLock { entries.filter { !hasExited($0) }.map(\.info) }
    }

    public func terminate(_ app: RunningAppInfo) -> Bool {
        let (result, hook): (Bool, (@Sendable (RunningAppInfo) -> Void)?) = lock.withLock {
            _events.append(.terminate(app.processIdentifier))
            guard let i = entries.firstIndex(where: { $0.info.processIdentifier == app.processIdentifier }),
                  !hasExited(entries[i])
            else { return (false, _onTerminate) }
            if entries[i].behavior == .refuses { return (false, _onTerminate) }
            entries[i].terminateRequestedAt = clock.now
            return (true, _onTerminate)
        }
        hook?(app)
        return result
    }

    public func forceTerminate(_ app: RunningAppInfo) -> Bool {
        lock.withLock {
            _events.append(.forceTerminate(app.processIdentifier))
            guard let i = entries.firstIndex(where: { $0.info.processIdentifier == app.processIdentifier }),
                  !hasExited(entries[i])
            else { return false }
            entries[i].forced = true
            return true
        }
    }

    private func hasExited(_ entry: Entry) -> Bool {
        if entry.forced { return true }
        guard let requested = entry.terminateRequestedAt else { return false }
        switch entry.behavior {
        case .quitsImmediately: return true
        case .quits(let delay): return clock.now - requested >= delay
        case .refuses, .ignores: return false
        }
    }
}

/// Records launches; can fail chosen bundle ids. Never launches anything.
public final class FakeAppLauncher: AppLauncher, @unchecked Sendable {
    public struct LaunchFailure: Error, Hashable, Sendable, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private let lock = NSLock()
    private var _launched: [LaunchRequest] = []
    private var failures: [String: any Error] = [:]

    public init() {}

    public var launched: [LaunchRequest] { lock.withLock { _launched } }

    public func failLaunch(of bundleId: String, with error: any Error = LaunchFailure(message: "launch failed")) {
        lock.withLock { failures[bundleId] = error }
    }

    public func launch(_ request: LaunchRequest) async throws {
        try lock.withLock {
            _launched.append(request)
            if let error = failures[request.bundleId] { throw error }
        }
    }
}
