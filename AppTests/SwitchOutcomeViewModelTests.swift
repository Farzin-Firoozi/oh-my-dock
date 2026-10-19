import Foundation
import OhMyDockCore
import Testing

private final class FakeAppSwitcher: AppSwitching, @unchecked Sendable {
    private let lock = NSLock()
    private var _forceQuitCalls: [RunningAppInfo] = []
    var forceQuitResult: ForceQuitResult = .terminated

    var forceQuitCalls: [RunningAppInfo] {
        lock.withLock { _forceQuitCalls }
    }

    func plan(from source: Profile?, to target: Profile) -> SwitchPlan {
        SwitchPlan(scope: .none, willQuit: [], willKeep: [], willLaunch: [], protected: [])
    }

    func execute(_ plan: SwitchPlan) async -> SwitchOutcome {
        SwitchOutcome(quits: [], launches: [])
    }

    func forceQuit(
        _ app: RunningAppInfo,
        after outcome: SwitchOutcome,
        options: SwitchingOptions
    ) async -> ForceQuitResult {
        lock.withLock { _forceQuitCalls.append(app) }
        return forceQuitResult
    }
}

@MainActor
@Suite struct SwitchOutcomeViewModelTests {
    private let slack = RunningAppInfo(processIdentifier: 101, bundleId: "com.slack", name: "Slack")
    private let figma = RunningAppInfo(processIdentifier: 102, bundleId: "com.figma", name: "Figma")
    private let safari = RunningAppInfo(processIdentifier: 103, bundleId: "com.apple.Safari", name: "Safari")
    private let xcodeReq = LaunchRequest(bundleId: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app", hidden: false)

    private func makeOutcome(
        quits: [QuitResult] = [],
        launches: [LaunchResult] = []
    ) -> SwitchOutcome {
        SwitchOutcome(
            quits: quits,
            launches: launches
        )
    }

    @Test func outcomeSummaryShowsQuitCountAndStragglers() {
        let outcome = makeOutcome(
            quits: [
                QuitResult(app: safari, status: .quit),
                QuitResult(app: slack, status: .refused),
                QuitResult(app: figma, status: .stillRunningAfterTimeout)
            ],
            launches: [
                LaunchResult(request: xcodeReq, status: .failed("Application not installed"))
            ]
        )
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(offerForceQuit: true),
            switcher: switcher
        )

        #expect(vm.quitCount == 1)
        #expect(vm.stragglers.count == 2)
        #expect(vm.stragglers.map(\.app.name) == ["Slack", "Figma"])
        #expect(vm.launchFailures.count == 1)
        #expect(vm.launchFailures.first?.name == "Xcode")
        #expect(vm.summary.contains("Quit 1"))
    }

    @Test func cleanOutcomeHasNoIssues() {
        let outcome = makeOutcome(
            quits: [
                QuitResult(app: safari, status: .quit),
                QuitResult(app: slack, status: .quit)
            ],
            launches: []
        )
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(offerForceQuit: true),
            switcher: switcher
        )

        #expect(vm.quitCount == 2)
        #expect(vm.stragglers.isEmpty)
        #expect(vm.launchFailures.isEmpty)
    }

    @Test func forceQuitGatedWhenOfferForceQuitIsFalse() {
        let outcome = makeOutcome(
            quits: [
                QuitResult(app: slack, status: .refused)
            ]
        )
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(offerForceQuit: false),
            switcher: switcher
        )

        #expect(vm.canForceQuit(app: slack) == false)
        vm.promptForceQuit(for: slack)
        #expect(vm.appPendingForceQuit == nil)
    }

    @Test func forceQuitRefusedForNormalQuitApps() {
        let outcome = makeOutcome(
            quits: [
                QuitResult(app: safari, status: .quit)
            ]
        )
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(offerForceQuit: true),
            switcher: switcher
        )

        #expect(vm.canForceQuit(app: safari) == false)
    }

    @Test func twoStepExplicitConfirmationRequiredForForceQuit() async {
        let outcome = makeOutcome(
            quits: [
                QuitResult(app: slack, status: .stillRunningAfterTimeout)
            ]
        )
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(offerForceQuit: true),
            switcher: switcher
        )

        #expect(vm.canForceQuit(app: slack) == true)

        // Step 1: User clicks "Force quit…" -> sets prompt
        vm.promptForceQuit(for: slack)
        #expect(vm.appPendingForceQuit?.processIdentifier == slack.processIdentifier)

        // Verify NO force-quit action has run yet (never automatic!)
        let initialCalls = switcher.forceQuitCalls
        #expect(initialCalls.isEmpty)

        // If user cancels alert:
        vm.cancelForceQuitPrompt()
        #expect(vm.appPendingForceQuit == nil)
        let callsAfterCancel = switcher.forceQuitCalls
        #expect(callsAfterCancel.isEmpty)

        // Prompt again and explicitly confirm:
        vm.promptForceQuit(for: slack)
        let result = await vm.confirmForceQuit()
        #expect(result == .terminated)

        // Verify switcher was called with the straggler app
        let finalCalls = switcher.forceQuitCalls
        #expect(finalCalls.count == 1)
        #expect(finalCalls.first?.processIdentifier == slack.processIdentifier)

        // After successful force quit, canForceQuit is false for that app
        #expect(vm.canForceQuit(app: slack) == false)
    }

    @Test func dismissInvokesCallback() {
        var dismissed = false
        let outcome = makeOutcome()
        let switcher = FakeAppSwitcher()
        let vm = SwitchOutcomeViewModel(
            outcome: outcome,
            options: SwitchingOptions(),
            switcher: switcher,
            onDismiss: { dismissed = true }
        )

        vm.dismiss()
        #expect(dismissed == true)
    }
}
