import Foundation
@testable import OhMyDockCore

let ownBundleId = "io.github.farzin-firoozi.OhMyDock"
let ownPid: Int32 = 999

func info(
    _ pid: Int32,
    _ bundleId: String?,
    name: String? = nil,
    policy: AppActivationPolicy = .regular,
    launched: Bool = true
) -> RunningAppInfo {
    RunningAppInfo(
        processIdentifier: pid,
        bundleId: bundleId,
        name: name ?? bundleId ?? "pid\(pid)",
        activationPolicy: policy,
        isFinishedLaunching: launched
    )
}

func profile(
    _ name: String,
    apps: [AppRef] = [],
    scope: SwitchingOptions.QuitScope = .previousProfileApps,
    launchHidden: Bool = false,
    offerForceQuit: Bool = false
) -> Profile {
    Profile(
        name: name,
        apps: apps.map { .app($0) },
        switching: SwitchingOptions(quitScope: scope, launchHidden: launchHidden, offerForceQuit: offerForceQuit)
    )
}

func ref(_ bundleId: String, launch: Bool = false) -> AppRef {
    AppRef(bundleId: bundleId, name: bundleId, launchOnSwitch: launch)
}

let testPolicy = NeverQuitPolicy(ownBundleId: ownBundleId, ownProcessIdentifier: ownPid)

struct Rig {
    let clock = FakeSwitchClock()
    let apps: FakeRunningApps
    let launcher = FakeAppLauncher()
    let switcher: AppSwitcher

    init(quitTimeout: Duration = .seconds(5), policy: NeverQuitPolicy = testPolicy) {
        apps = FakeRunningApps(clock: clock)
        switcher = AppSwitcher(
            provider: apps,
            launcher: launcher,
            clock: clock,
            neverQuit: policy,
            quitTimeout: quitTimeout
        )
    }

    func plan(from: Profile?, to: Profile) -> SwitchPlan { switcher.plan(from: from, to: to) }
}
