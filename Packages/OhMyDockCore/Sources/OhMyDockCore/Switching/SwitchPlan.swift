import Foundation

/// A running app the scope would have quit but that is left alone, and why.
public struct ProtectedApp: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case neverQuit(NeverQuitPolicy.Reason)
        /// Still launching; quitting mid-launch is flaky and there is no work to lose, so wait for the next switch.
        case stillLaunching
    }

    public let app: RunningAppInfo
    public let reason: Reason
}

/// What a switch will do, computed without touching any process.
public struct SwitchPlan: Hashable, Sendable {
    public var scope: SwitchingOptions.QuitScope
    /// Running regular apps to ask to quit, in input order. Duplicate instances are listed individually.
    public var willQuit: [RunningAppInfo]
    /// Running apps in both profiles (within the scope); left untouched and not relaunched.
    public var willKeep: [RunningAppInfo]
    /// Target apps marked launch-on-switch that aren't running.
    public var willLaunch: [LaunchRequest]
    /// Apps the scope covers but that are protected.
    public var protected: [ProtectedApp]

    public var isEmpty: Bool { willQuit.isEmpty && willLaunch.isEmpty }

    public init(
        scope: SwitchingOptions.QuitScope,
        willQuit: [RunningAppInfo] = [],
        willKeep: [RunningAppInfo] = [],
        willLaunch: [LaunchRequest] = [],
        protected: [ProtectedApp] = []
    ) {
        self.scope = scope
        self.willQuit = willQuit
        self.willKeep = willKeep
        self.willLaunch = willLaunch
        self.protected = protected
    }
}

extension AppSwitcher {
    /// Pure planning. Uses the **target** profile's `switching` options (scope, launchHidden).
    ///
    /// - `.none`: quits nothing and keeps nothing (launches still happen).
    /// - `.previousProfileApps`: quits running regular apps that are in `source` and not in `target`.
    /// - `.allNotInProfile`: quits every running regular app not in `target`, `source` ignored.
    ///
    /// Never quits: non-`.regular` apps, apps in `neverQuit`, apps without a bundle id, apps still
    /// launching, apps in the target. `source == nil` (no previous profile) makes `.previousProfileApps` quit nothing.
    public static func plan(
        from source: Profile?,
        to target: Profile,
        running: [RunningAppInfo],
        neverQuit: NeverQuitPolicy
    ) -> SwitchPlan {
        let scope = target.switching.quitScope
        let targetRefs = appRefs(of: target)
        let targetIds = Set(targetRefs.compactMap { normalizedBundleId($0.bundleId) })
        let sourceIds = Set(source.map(appRefs(of:))?.compactMap { normalizedBundleId($0.bundleId) } ?? [])

        var plan = SwitchPlan(scope: scope)

        if scope != .none {
            for app in running where app.activationPolicy == .regular {
                guard let id = normalizedBundleId(app.bundleId) else {
                    if scope == .allNotInProfile {
                        plan.protected.append(ProtectedApp(app: app, reason: .neverQuit(.noBundleId)))
                    }
                    continue
                }
                let inScope = scope == .allNotInProfile || sourceIds.contains(id)
                guard inScope else { continue }
                if targetIds.contains(id) {
                    plan.willKeep.append(app)
                } else if let reason = neverQuit.reason(for: app) {
                    plan.protected.append(ProtectedApp(app: app, reason: .neverQuit(reason)))
                } else if !app.isFinishedLaunching {
                    plan.protected.append(ProtectedApp(app: app, reason: .stillLaunching))
                } else {
                    plan.willQuit.append(app)
                }
            }
        }

        let runningIds = Set(running.compactMap { normalizedBundleId($0.bundleId) })
        var seen = Set<String>()
        for ref in targetRefs where ref.launchOnSwitch {
            guard let id = normalizedBundleId(ref.bundleId),
                  !runningIds.contains(id),
                  seen.insert(id).inserted
            else { continue }
            plan.willLaunch.append(LaunchRequest(
                bundleId: ref.bundleId,
                name: ref.name,
                path: ref.path,
                hidden: target.switching.launchHidden
            ))
        }
        return plan
    }

    static func appRefs(of profile: Profile) -> [AppRef] {
        (profile.apps + profile.others).compactMap {
            if case .app(let ref) = $0 { ref } else { nil }
        }
    }
}
