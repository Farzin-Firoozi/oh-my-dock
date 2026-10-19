import AppKit
import Foundation

/// NSWorkspace-backed running apps. Not exercised by tests: it would quit real apps.
///
/// Every AppKit call (the process list, `isTerminated`, `isFinishedLaunching`, `activationPolicy`,
/// `terminate()`, `forceTerminate()`) runs on the main thread through `MainThread.run`, whatever
/// thread the caller is on.
///
/// `terminate`/`forceTerminate` re-resolve the process by pid and refuse unless the bundle id still
/// matches and the app is regular, as a last line of defense.
public struct LiveRunningApps: RunningAppsProviding {
    public init() {}

    public func runningApps() -> [RunningAppInfo] {
        MainThread.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated else { return nil }
                return RunningAppInfo(
                    processIdentifier: app.processIdentifier,
                    bundleId: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                    activationPolicy: Self.map(app.activationPolicy),
                    isFinishedLaunching: app.isFinishedLaunching
                )
            }
        }
    }

    public func terminate(_ app: RunningAppInfo) -> Bool {
        MainThread.run {
            guard let live = Self.resolve(app) else { return false }
            return live.terminate()
        }
    }

    public func forceTerminate(_ app: RunningAppInfo) -> Bool {
        MainThread.run {
            guard let live = Self.resolve(app) else { return false }
            return live.forceTerminate()
        }
    }

    /// Main thread only: reads `isTerminated` and `activationPolicy`.
    @MainActor
    private static func resolve(_ app: RunningAppInfo) -> NSRunningApplication? {
        guard let live = NSRunningApplication(processIdentifier: app.processIdentifier),
              !live.isTerminated,
              live.activationPolicy == .regular,
              normalizedBundleId(live.bundleIdentifier) == normalizedBundleId(app.bundleId)
        else { return nil }
        return live
    }

    @MainActor
    private static func map(_ policy: NSApplication.ActivationPolicy) -> AppActivationPolicy {
        switch policy {
        case .regular: .regular
        case .accessory: .accessory
        case .prohibited: .prohibited
        @unknown default: .prohibited
        }
    }
}

/// `NSWorkspace.openApplication` with `activates = false`. Not exercised by tests: it would launch real apps.
/// `hides = true` applies asynchronously (see spike 0.6). The `NSWorkspace` calls run on the main actor.
public struct LiveAppLauncher: AppLauncher {
    public init() {}

    public func launch(_ request: LaunchRequest) async throws {
        try await Self.launchOnMain(request)
    }

    @MainActor
    private static func launchOnMain(_ request: LaunchRequest) async throws {
        let workspace = NSWorkspace.shared
        let url: URL
        if let byId = workspace.urlForApplication(withBundleIdentifier: request.bundleId) {
            url = byId
        } else if let path = request.path, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else {
            throw AppLaunchError.notInstalled(bundleId: request.bundleId)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = request.hidden
        _ = try await workspace.openApplication(at: url, configuration: configuration)
    }
}
