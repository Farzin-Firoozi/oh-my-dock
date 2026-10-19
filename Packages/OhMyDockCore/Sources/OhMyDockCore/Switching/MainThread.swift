import Foundation

/// Runs AppKit work (`NSRunningApplication`, `NSWorkspace`) on the main thread for callers that
/// may be on any thread. `ProfileApplier` is an actor, so `AppSwitcher` and the live providers
/// normally run on the cooperative pool, where AppKit must not be touched.
///
/// The provider protocols stay synchronous (the fakes and `AppSwitcher.plan` rely on that), so a
/// background caller blocks while the main thread runs `body`. Nothing on the main actor ever
/// waits for these callers, so this cannot deadlock.
enum MainThread {
    static func run<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
