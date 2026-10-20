import OhMyDockCore
import Testing

@Suite struct AppExternalConfirmationPolicyTests {
    @Test func intentFollowsMenuRuleForTileOnlyChange() {
        let preview = ApplyPreview(
            profileName: "Work",
            current: DockState(),
            target: DockState(apps: [.app(AppRef(bundleId: "a", name: "A", path: "/A.app"))]),
            plan: DiffEngine.plan(
                from: DockState(),
                to: DockState(apps: [.app(AppRef(bundleId: "a", name: "A", path: "/A.app"))])
            ),
            skipped: [],
            switchPlan: SwitchPlan(scope: .none, willQuit: [], willLaunch: [])
        )
        #expect(!ExternalConfirmationPolicy.requiresPrompt(source: .intent, preview: preview))
        #expect(ExternalConfirmationPolicy.requiresPrompt(source: .url, preview: preview))
    }
}
