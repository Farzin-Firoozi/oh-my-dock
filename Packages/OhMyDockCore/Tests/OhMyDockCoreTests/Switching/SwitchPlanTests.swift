import Testing
@testable import OhMyDockCore

@Suite("AppSwitcher.plan")
struct SwitchPlanTests {
    private let a = profile("A", apps: [ref("com.a.one"), ref("com.a.two"), ref("com.shared")])
    private func running() -> [RunningAppInfo] {
        [info(1, "com.a.one"), info(2, "com.a.two"), info(3, "com.shared"), info(4, "com.other"), info(5, "com.b.new")]
    }

    @Test func previousProfileScopeQuitsOnlySourceAppsNotInTarget() {
        let b = profile("B", apps: [ref("com.shared"), ref("com.b.new")], scope: .previousProfileApps)
        let plan = AppSwitcher.plan(from: a, to: b, running: running(), neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [1, 2])
        #expect(plan.willKeep.map(\.processIdentifier) == [3])
        // com.other is not in A, so it is untouched under this scope.
        #expect(!plan.willQuit.contains { $0.bundleId == "com.other" })
    }

    @Test func allNotInProfileScopeQuitsEverythingRegularNotInTarget() {
        let b = profile("B", apps: [ref("com.shared"), ref("com.b.new")], scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: a, to: b, running: running(), neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [1, 2, 4])
        #expect(plan.willKeep.map(\.processIdentifier) == [3, 5])
    }

    @Test func allNotInProfileIgnoresSource() {
        let b = profile("B", apps: [ref("com.shared")], scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: nil, to: b, running: running(), neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [1, 2, 4, 5])
    }

    @Test func noneScopeQuitsAndKeepsNothingButStillLaunches() {
        let b = profile("B", apps: [ref("com.shared"), ref("com.b.launch", launch: true)], scope: .none)
        let plan = AppSwitcher.plan(from: a, to: b, running: running(), neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
        #expect(plan.willKeep.isEmpty)
        #expect(plan.protected.isEmpty)
        #expect(plan.willLaunch.map(\.bundleId) == ["com.b.launch"])
    }

    @Test func noPreviousProfileQuitsNothingUnderPreviousScope() {
        let b = profile("B", apps: [ref("com.shared")], scope: .previousProfileApps)
        let plan = AppSwitcher.plan(from: nil, to: b, running: running(), neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
    }

    @Test func scopeComesFromTargetProfile() {
        let source = profile("A", apps: [ref("com.a.one")], scope: .allNotInProfile)
        let target = profile("B", scope: .none)
        let plan = AppSwitcher.plan(from: source, to: target, running: running(), neverQuit: testPolicy)
        #expect(plan.scope == .none)
        #expect(plan.willQuit.isEmpty)
    }

    @Test func neverQuitListIsHonoredAndReported() {
        let source = profile("A", apps: [ref("com.apple.finder"), ref("com.apple.dock"), ref("com.a.one"), ref(ownBundleId)])
        let target = profile("B", scope: .allNotInProfile)
        let run = [
            info(1, "com.apple.finder"), info(2, "com.apple.dock"), info(3, "com.apple.SystemUIServer"),
            info(4, "com.apple.loginwindow"), info(5, "com.apple.WindowServer"), info(6, ownBundleId),
            info(7, "com.a.one"),
        ]
        let plan = AppSwitcher.plan(from: source, to: target, running: run, neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [7])
        #expect(Set(plan.protected.map(\.app.processIdentifier)) == [1, 2, 3, 4, 5, 6])
    }

    @Test func userExtraNeverQuitIdsAreCaseInsensitive() {
        let policy = NeverQuitPolicy(extraBundleIds: ["com.1Password.1Password"], ownProcessIdentifier: ownPid)
        let target = profile("B", scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: nil, to: target, running: [info(1, "com.1password.1password"), info(2, "com.x")], neverQuit: policy)
        #expect(plan.willQuit.map(\.processIdentifier) == [2])
        #expect(plan.protected.first?.reason == .neverQuit(.userList))
    }

    @Test func ownAppIsProtectedByPidEvenWithOddBundleId() {
        let target = profile("B", scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: nil, to: target, running: [info(ownPid, "com.renamed.copy")], neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
        #expect(plan.protected.first?.reason == .neverQuit(.ownApp))
    }

    @Test func nonRegularAppsAreNeverTouched() {
        let source = profile("A", apps: [ref("com.menubar"), ref("com.agent")])
        let target = profile("B", scope: .allNotInProfile)
        let run = [info(1, "com.menubar", policy: .accessory), info(2, "com.agent", policy: .prohibited), info(3, "com.x")]
        let plan = AppSwitcher.plan(from: source, to: target, running: run, neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [3])
        #expect(plan.protected.isEmpty)
    }

    @Test func processesWithoutBundleIdAreNotQuit() {
        let target = profile("B", scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: nil, to: target, running: [info(1, nil), info(2, "")], neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
        #expect(plan.protected.count == 2)
    }

    @Test func appsStillLaunchingAreLeftAlone() {
        let target = profile("B", scope: .allNotInProfile)
        let plan = AppSwitcher.plan(from: nil, to: target, running: [info(1, "com.x", launched: false)], neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
        #expect(plan.protected.first?.reason == .stillLaunching)
    }

    @Test func duplicateInstancesAreAllPlannedAndKeptTogether() {
        let source = profile("A", apps: [ref("com.dup"), ref("com.keep")])
        let target = profile("B", apps: [ref("com.keep")])
        let run = [info(1, "com.dup"), info(2, "com.dup"), info(3, "com.keep"), info(4, "com.keep")]
        let plan = AppSwitcher.plan(from: source, to: target, running: run, neverQuit: testPolicy)
        #expect(plan.willQuit.map(\.processIdentifier) == [1, 2])
        #expect(plan.willKeep.map(\.processIdentifier) == [3, 4])
    }

    @Test func bundleIdMatchingIsCaseInsensitive() {
        let source = profile("A", apps: [ref("COM.Foo.App")])
        let target = profile("B", apps: [ref("com.foo.app")])
        let plan = AppSwitcher.plan(from: source, to: target, running: [info(1, "com.FOO.app")], neverQuit: testPolicy)
        #expect(plan.willQuit.isEmpty)
        #expect(plan.willKeep.count == 1)
    }

    @Test func appsInBothProfilesAreKeptNotRelaunched() {
        let source = profile("A", apps: [ref("com.shared")])
        let target = profile("B", apps: [ref("com.shared", launch: true)])
        let plan = AppSwitcher.plan(from: source, to: target, running: [info(1, "com.shared")], neverQuit: testPolicy)
        #expect(plan.willKeep.count == 1)
        #expect(plan.willLaunch.isEmpty)
        #expect(plan.willQuit.isEmpty)
    }

    @Test func launchOnlyMarkedAndNotRunningAndDeduped() {
        let target = profile("B", apps: [
            ref("com.l1", launch: true), ref("com.l1", launch: true), ref("com.notmarked"),
            ref("com.running", launch: true), ref("", launch: true),
        ], launchHidden: true)
        let run = [info(1, "com.running"), info(2, "com.menubar", policy: .accessory)]
        let plan = AppSwitcher.plan(from: nil, to: target, running: run, neverQuit: testPolicy)
        #expect(plan.willLaunch.map(\.bundleId) == ["com.l1"])
        #expect(plan.willLaunch.first?.hidden == true)
    }

    @Test func runningNonRegularAppCountsAsRunningForLaunch() {
        let target = profile("B", apps: [ref("com.agent", launch: true)])
        let plan = AppSwitcher.plan(from: nil, to: target, running: [info(1, "com.agent", policy: .accessory)], neverQuit: testPolicy)
        #expect(plan.willLaunch.isEmpty)
    }
}
