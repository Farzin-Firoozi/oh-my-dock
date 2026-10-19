import Foundation
import OhMyDockCore
import Testing

@MainActor
@Suite struct SwitchConfirmationViewModelTests {
    private let slack = RunningAppInfo(processIdentifier: 101, bundleId: "com.slack", name: "Slack")
    private let figma = RunningAppInfo(processIdentifier: 102, bundleId: "com.figma", name: "Figma")
    private let safari = RunningAppInfo(processIdentifier: 103, bundleId: "com.apple.Safari", name: "Safari")
    private let finder = RunningAppInfo(processIdentifier: 104, bundleId: "com.apple.finder", name: "Finder")
    private let xcode = LaunchRequest(bundleId: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app", hidden: false)

    private func makePlan() -> SwitchPlan {
        SwitchPlan(
            scope: .previousProfileApps,
            willQuit: [slack, figma],
            willKeep: [safari],
            willLaunch: [xcode],
            protected: [
                ProtectedApp(app: finder, reason: .neverQuit(.builtIn))
            ]
        )
    }

    @Test func planMapsToRowSections() {
        let plan = makePlan()
        let vm = SwitchConfirmationViewModel(plan: plan, profileName: "Development")

        #expect(vm.profileName == "Development")
        #expect(vm.willQuitApps.map(\.name) == ["Slack", "Figma"])
        #expect(vm.willKeepApps.map(\.name) == ["Safari"])
        #expect(vm.willOpenApps.map(\.name) == ["Xcode"])
        #expect(vm.protectedApps.map(\.name) == ["Finder"])
        #expect(vm.protectedApps.first?.reason == "macOS system app")
        #expect(vm.hasAppChanges == true)
        #expect(vm.excludedBundleIDs.isEmpty)
    }

    @Test func uncheckingAppExcludesItAndMovesToKeep() {
        let plan = makePlan()
        let vm = SwitchConfirmationViewModel(plan: plan, profileName: "Development")

        #expect(vm.isAppChecked(bundleId: "com.slack"))
        #expect(vm.isAppChecked(bundleId: "com.figma"))

        // Uncheck Slack
        vm.toggleAppChecked(for: "com.slack")
        #expect(!vm.isAppChecked(bundleId: "com.slack"))
        #expect(vm.excludedBundleIDs == ["com.slack"])

        // Slack now appears in willKeepApps
        let keepNames = vm.willKeepApps.map(\.name)
        #expect(keepNames.contains("Slack"))
        #expect(keepNames.contains("Safari"))

        // Confirm result reflects exclusion
        let result = vm.confirmResult
        #expect(result.accepted == true)
        #expect(result.excludedBundleIDs == ["com.slack"])

        // Re-checking Slack restores it
        vm.toggleAppChecked(for: "com.slack")
        #expect(vm.isAppChecked(bundleId: "com.slack"))
        #expect(vm.excludedBundleIDs.isEmpty)
    }

    @Test func cancelProducesRejectedResult() {
        var confirmedResult: ApplyConfirmResult?
        let plan = makePlan()
        let vm = SwitchConfirmationViewModel(
            plan: plan,
            profileName: "Development",
            onConfirm: { res in confirmedResult = res }
        )

        vm.cancelAction()
        #expect(confirmedResult?.accepted == false)

        vm.switchAction()
        #expect(confirmedResult?.accepted == true)
    }

    @Test func emptySwitchPlanHasNoAppChanges() {
        let plan = SwitchPlan(scope: .none, willQuit: [], willKeep: [], willLaunch: [], protected: [])
        let vm = SwitchConfirmationViewModel(plan: plan)
        #expect(vm.hasAppChanges == false)
        #expect(vm.willQuitApps.isEmpty)
        #expect(vm.willKeepApps.isEmpty)
        #expect(vm.willOpenApps.isEmpty)
        #expect(vm.protectedApps.isEmpty)
    }
}
