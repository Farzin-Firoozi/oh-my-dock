import Foundation
import Testing
@testable import OhMyDockCore

@Suite("AppSwitcher.execute")
struct AppSwitcherExecuteTests {
    private func switchPlan(_ rig: Rig, quit: [RunningAppInfo], launch: [LaunchRequest] = []) -> SwitchPlan {
        _ = rig
        return SwitchPlan(scope: .allNotInProfile, willQuit: quit, willLaunch: launch)
    }

    @Test func gracefulQuitReportsQuit() async {
        let rig = Rig()
        let app = info(1, "com.x")
        rig.apps.add(app)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits == [QuitResult(app: app, status: .quit)])
        #expect(rig.apps.terminated == [1])
        #expect(rig.apps.forceTerminated.isEmpty)
        #expect(outcome.summary == "Quit 1")
    }

    @Test func slowQuitWithinTimeoutIsQuit() async {
        let rig = Rig(quitTimeout: .seconds(5))
        let app = info(1, "com.x")
        rig.apps.add(app, behavior: .quits(after: .seconds(3)))
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits.first?.status == .quit)
    }

    @Test func terminateFalseIsRefusedAndNeverForced() async {
        let rig = Rig()
        let app = info(1, "com.apple.Safari", name: "Safari")
        rig.apps.add(app, behavior: .refuses)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits.first?.status == .refused)
        #expect(outcome.stragglers == [app])
        #expect(rig.apps.forceTerminated.isEmpty)
        #expect(outcome.summary == "Safari refused")
    }

    @Test func timeoutReportsStillRunningWithoutForcing() async {
        let rig = Rig(quitTimeout: .seconds(5))
        let app = info(1, "com.apple.Notes", name: "Notes")
        rig.apps.add(app, behavior: .ignores)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits.first?.status == .stillRunningAfterTimeout)
        #expect(rig.clock.now >= .seconds(5))
        #expect(rig.clock.now < .seconds(6))
        #expect(rig.apps.forceTerminated.isEmpty)
        #expect(rig.apps.runningApps().contains(app))
    }

    @Test func terminateLaterDeferralPastTimeoutIsStraggler() async {
        let rig = Rig(quitTimeout: .seconds(5))
        let app = info(1, "com.x")
        rig.apps.add(app, behavior: .quits(after: .seconds(30)))
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits.first?.status == .stillRunningAfterTimeout)
        #expect(outcome.stragglers == [app])
        #expect(rig.apps.forceTerminated.isEmpty)
    }

    @Test func mixedOutcomeSummary() async {
        let rig = Rig()
        let apps = [info(1, "a"), info(2, "b"), info(3, "c"), info(4, "com.apple.Safari", name: "Safari"), info(5, "n", name: "Notes")]
        for (i, app) in apps.enumerated() {
            rig.apps.add(app, behavior: i == 3 ? .refuses : i == 4 ? .ignores : .quitsImmediately)
        }
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: apps))
        #expect(outcome.summary == "Quit 3, Safari refused, Notes still running")
    }

    @Test func staleNonRegularAppIsNotQuit() async {
        let rig = Rig()
        let planned = info(1, "com.x")
        rig.apps.add(info(1, "com.x", policy: .accessory))
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [planned]))
        #expect(outcome.quits.first?.status == .skippedProtected)
        #expect(rig.apps.terminated.isEmpty)
    }

    @Test func handCraftedPlanCannotQuitNeverQuitApps() async {
        let rig = Rig()
        let finder = info(1, "com.apple.finder")
        let me = info(ownPid, "com.whatever")
        let ownById = info(3, ownBundleId)
        for app in [finder, me, ownById] { rig.apps.add(app) }
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [finder, me, ownById]))
        #expect(outcome.quits.map(\.status) == [.skippedProtected, .skippedProtected, .skippedProtected])
        #expect(rig.apps.terminated.isEmpty)
        #expect(rig.apps.runningApps().count == 3)
    }

    @Test func appGoneBeforeItsTurnIsNotTerminated() async {
        let rig = Rig()
        let app = info(1, "com.x")
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        #expect(outcome.quits.first?.status == .alreadyExited)
        #expect(rig.apps.terminated.isEmpty)
    }

    @Test func reusedPidWithDifferentBundleIsNotQuit() async {
        let rig = Rig()
        rig.apps.add(info(1, "com.someone.else"))
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [info(1, "com.x")]))
        #expect(outcome.quits.first?.status == .alreadyExited)
        #expect(rig.apps.terminated.isEmpty)
    }

    @Test func duplicateInstancesAreQuitIndividually() async {
        let rig = Rig()
        let one = info(1, "com.dup"), two = info(2, "com.dup")
        rig.apps.add(one)
        rig.apps.add(two, behavior: .ignores)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [one, two]))
        #expect(outcome.quits.map(\.status) == [.quit, .stillRunningAfterTimeout])
        #expect(rig.apps.terminated == [1, 2])
    }

    // MARK: Cancellation

    @Test func cancelBeforeStartQuitsNothingAndSkipsLaunches() async {
        let rig = Rig()
        let app = info(1, "com.x")
        rig.apps.add(app)
        let launch = LaunchRequest(bundleId: "com.l", name: "L")
        let plan = switchPlan(rig, quit: [app], launch: [launch])
        let switcher = rig.switcher
        let task = Task { () -> SwitchOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await switcher.execute(plan)
        }
        let outcome = await task.value
        #expect(outcome.wasCancelled)
        #expect(outcome.quits.map(\.status) == [.skippedCancelled])
        #expect(outcome.launches.map(\.status) == [.skippedCancelled])
        #expect(rig.apps.terminated.isEmpty)
        #expect(rig.launcher.launched.isEmpty)
    }

    @Test func cancelBetweenAppsStopsBeforeNextQuitWithoutRollback() async {
        let rig = Rig()
        let first = info(1, "com.first"), second = info(2, "com.second"), third = info(3, "com.third")
        for app in [first, second, third] { rig.apps.add(app) }
        // Cancel while the first quit request is being sent; the wait for it then sees the cancellation.
        rig.apps.setOnTerminate { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let plan = switchPlan(rig, quit: [first, second, third], launch: [LaunchRequest(bundleId: "com.l", name: "L")])
        let switcher = rig.switcher
        let outcome = await Task { await switcher.execute(plan) }.value

        #expect(outcome.wasCancelled)
        // First app's quit (immediate in the fake) was confirmed before the cancellation was observed or reported unconfirmed; never undone.
        #expect([.quit, .quitRequestedUnconfirmed].contains(outcome.quits[0].status))
        #expect(outcome.quits[1].status == .skippedCancelled)
        #expect(outcome.quits[2].status == .skippedCancelled)
        #expect(rig.apps.terminated == [1])
        #expect(rig.launcher.launched.isEmpty)
    }

    @Test func cancelDuringWaitReportsUnconfirmedAndStops() async {
        let rig = Rig()
        let first = info(1, "com.first"), second = info(2, "com.second")
        rig.apps.add(first, behavior: .quits(after: .seconds(2)))
        rig.apps.add(second)
        rig.apps.setOnTerminate { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let plan = switchPlan(rig, quit: [first, second])
        let switcher = rig.switcher
        let outcome = await Task { await switcher.execute(plan) }.value
        #expect(outcome.quits.map(\.status) == [.quitRequestedUnconfirmed, .skippedCancelled])
        #expect(outcome.stragglers == [first])
        #expect(rig.apps.terminated == [1])
    }

    // MARK: Launch

    @Test func launchesWithRequestedOptionsAndReportsFailures() async {
        let rig = Rig()
        rig.launcher.failLaunch(of: "com.bad", with: AppLaunchError.notInstalled(bundleId: "com.bad"))
        let good = LaunchRequest(bundleId: "com.good", name: "Good", hidden: true)
        let bad = LaunchRequest(bundleId: "com.bad", name: "Bad")
        let outcome = await rig.switcher.execute(SwitchPlan(scope: .none, willLaunch: [bad, good]))
        #expect(outcome.launches.map(\.status) == [.failed("App com.bad is not installed"), .launched])
        #expect(rig.launcher.launched == [bad, good])
        #expect(outcome.launchFailures.count == 1)
        #expect(outcome.summary == "Bad failed to launch")
    }

    @Test func launchSkippedIfAppAppearedMeanwhile() async {
        let rig = Rig()
        rig.apps.add(info(1, "com.l"))
        let outcome = await rig.switcher.execute(SwitchPlan(scope: .none, willLaunch: [LaunchRequest(bundleId: "COM.L", name: "L")]))
        #expect(outcome.launches.map(\.status) == [.alreadyRunning])
        #expect(rig.launcher.launched.isEmpty)
    }

    @Test func fullSwitchKeepsSharedAppsAndLaunchesNew() async {
        let rig = Rig()
        for app in [info(1, "com.a"), info(2, "com.shared"), info(3, "com.apple.finder")] { rig.apps.add(app) }
        let source = profile("A", apps: [ref("com.a"), ref("com.shared"), ref("com.apple.finder")])
        let target = profile("B", apps: [ref("com.shared", launch: true), ref("com.new", launch: true)])
        let plan = rig.plan(from: source, to: target)
        let outcome = await rig.switcher.execute(plan)
        #expect(rig.apps.terminated == [1])
        #expect(rig.launcher.launched.map(\.bundleId) == ["com.new"])
        #expect(outcome.summary == "Quit 1")
        #expect(rig.apps.runningApps().map(\.processIdentifier) == [2, 3])
    }

    // MARK: Force quit

    @Test func forceQuitRefusedWhenNotOffered() async {
        let rig = Rig()
        let app = info(1, "com.x")
        rig.apps.add(app, behavior: .ignores)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        let result = await rig.switcher.forceQuit(app, after: outcome, options: SwitchingOptions(offerForceQuit: false))
        #expect(result == .notOffered)
        #expect(rig.apps.forceTerminated.isEmpty)
    }

    @Test func forceQuitWorksForStragglerWhenOffered() async {
        let rig = Rig()
        let app = info(1, "com.x")
        rig.apps.add(app, behavior: .ignores)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [app]))
        let result = await rig.switcher.forceQuit(app, after: outcome, options: SwitchingOptions(offerForceQuit: true))
        #expect(result == .terminated)
        #expect(rig.apps.forceTerminated == [1])
    }

    @Test func forceQuitOnlyForReportedStragglers() async {
        let rig = Rig()
        let straggler = info(1, "com.x"), other = info(2, "com.y")
        rig.apps.add(straggler, behavior: .ignores)
        rig.apps.add(other)
        let outcome = await rig.switcher.execute(switchPlan(rig, quit: [straggler]))
        let result = await rig.switcher.forceQuit(other, after: outcome, options: SwitchingOptions(offerForceQuit: true))
        #expect(result == .notAStraggler)
        #expect(rig.apps.forceTerminated.isEmpty)
    }

    @Test func forceQuitRechecksNeverQuit() async {
        let rig = Rig()
        let finder = info(1, "com.apple.finder")
        rig.apps.add(finder, behavior: .ignores)
        // A forged outcome that claims Finder is a straggler.
        let forged = SwitchOutcome(quits: [QuitResult(app: finder, status: .stillRunningAfterTimeout)])
        let result = await rig.switcher.forceQuit(finder, after: forged, options: SwitchingOptions(offerForceQuit: true))
        #expect(result == .protected)
        #expect(rig.apps.forceTerminated.isEmpty)
    }

    @Test func forceQuitAlreadyExited() async {
        let rig = Rig()
        let app = info(1, "com.x")
        let outcome = SwitchOutcome(quits: [QuitResult(app: app, status: .refused)])
        let result = await rig.switcher.forceQuit(app, after: outcome, options: SwitchingOptions(offerForceQuit: true))
        #expect(result == .alreadyExited)
    }

    @Test func executeNeverForceQuitsAnything() async {
        let rig = Rig()
        let apps = [info(1, "a"), info(2, "b"), info(3, "c")]
        rig.apps.add(apps[0], behavior: .ignores)
        rig.apps.add(apps[1], behavior: .refuses)
        rig.apps.add(apps[2], behavior: .quits(after: .seconds(60)))
        _ = await rig.switcher.execute(switchPlan(rig, quit: apps))
        #expect(rig.apps.forceTerminated.isEmpty)
    }
}
