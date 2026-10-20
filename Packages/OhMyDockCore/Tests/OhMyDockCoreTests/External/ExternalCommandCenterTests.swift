import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct ExternalCommandCenterTests {
    @Test func listIsEmptyInitially() async throws {
        _ = ExternalTestSupport.tempSupportRoot()
        let center = try ExternalTestSupport.makeCenter()
        let result = await center.run(ExternalRequest(command: .list, source: .cli))
        #expect(result.exitCode == 0)
        #expect(result.envelope.result?.profiles?.isEmpty == true)
    }

    @Test func livePlistOverrideIsRefused() async throws {
        try await ExternalTestSupport.withExclusiveEnvironment {
            unsetenv(DockPlistEnvironment.overrideKey)
            _ = ExternalTestSupport.tempSupportRoot()
            let live = DockPlistEnvironment.liveDockPlistURL.path
            setenv(DockPlistEnvironment.overrideKey, live, 1)
            defer { unsetenv(DockPlistEnvironment.overrideKey) }
            let center = try ExternalTestSupport.makeCenter()
            let result = await center.run(ExternalRequest(command: .list, source: .cli))
            #expect(result.exitCode == 2)
            #expect(result.envelope.error?.reason == "liveDockPlistRefused")
        }
    }

    @Test func applyNoChangesIsIdempotent() async throws {
        _ = ExternalTestSupport.tempSupportRoot()
        let dock = FakeDockBackend()
        let center = try ExternalTestSupport.makeCenter(dock: dock)
        let state = try await dock.read()
        let profile = Profile(name: "Work", apps: state.apps, others: state.others)
        try await center.profiles.save(profile)

        let apply = await center.run(ExternalRequest(
            command: .apply(profile: "Work", dryRun: false, quitScope: nil, keepRunning: []),
            source: .cli,
            yes: true
        ))
        #expect(apply.exitCode == 0)
        #expect(apply.envelope.result?.status == "noChanges")

        let again = await center.run(ExternalRequest(
            command: .apply(profile: "Work", dryRun: false, quitScope: nil, keepRunning: []),
            source: .cli,
            yes: true
        ))
        #expect(again.exitCode == 0)
        #expect(again.envelope.result?.status == "noChanges")
    }

    @Test func quitRequiresBothFlags() async throws {
        _ = ExternalTestSupport.tempSupportRoot()
        let dock = FakeDockBackend()
        let switcher = ConfigurableSwitcher(
            plan: SwitchPlan(scope: .none, willQuit: [RunningAppInfo(
                processIdentifier: 1,
                bundleId: "com.example.app",
                name: "Example",
                activationPolicy: .regular,
                isFinishedLaunching: true
            )], willLaunch: [])
        )
        let center = try ExternalTestSupport.makeCenter(dock: dock, switcher: switcher)
        let state = try await dock.read()
        var profile = Profile(name: "Work", apps: state.apps, others: state.others)
        profile.apps.append(.app(AppRef(bundleId: "com.other.app", name: "Other", path: "/Apps/Other.app")))
        try await center.profiles.save(profile)

        let noFlags = await center.run(ExternalRequest(
            command: .apply(profile: "Work", dryRun: false, quitScope: nil, keepRunning: []),
            source: .cli
        ))
        #expect(noFlags.exitCode == 5)

        let yesOnly = await center.run(ExternalRequest(
            command: .apply(profile: "Work", dryRun: false, quitScope: nil, keepRunning: []),
            source: .cli,
            yes: true
        ))
        #expect(yesOnly.exitCode == 5)

        let both = await center.run(ExternalRequest(
            command: .apply(profile: "Work", dryRun: false, quitScope: nil, keepRunning: []),
            source: .cli,
            yes: true,
            allowQuit: true
        ))
        #expect(both.exitCode == 0)
    }

    @Test func snapshotSourceTagRoundTrip() async throws {
        _ = ExternalTestSupport.tempSupportRoot()
        let snapshots = SnapshotStore(rootDirectory: try SupportPaths.snapshotsDirectory())
        let saved = try await snapshots.save(reason: "Before applying profile Tagged", profileName: "Tagged", source: .cli)
        #expect(saved.source == .cli)
        let listed = await snapshots.list().snapshots
        #expect(listed.first?.source == .cli)
    }

    @Test func oldSnapshotJSONDecodesWithoutSource() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":788941200,"reason":"Before applying profile X","byteSize":10,"sha256":"abc","pinned":false}
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.source == nil)
    }
}

@Suite struct ExternalConfirmationPolicyTests {
    @Test func urlPromptWhenDockWouldWriteEvenWithoutConfirmation() {
        let preview = ApplyPreview(
            profileName: "Work",
            current: DockState(),
            target: DockState(apps: [.app(AppRef(bundleId: "a", name: "A", path: "/A.app"))]),
            plan: DiffEngine.plan(from: DockState(), to: DockState(apps: [.app(AppRef(bundleId: "a", name: "A", path: "/A.app"))])),
            skipped: [],
            switchPlan: SwitchPlan(scope: .none, willQuit: [], willLaunch: [])
        )
        #expect(ExternalConfirmationPolicy.requiresPrompt(source: .url, preview: preview))
        #expect(!ExternalConfirmationPolicy.requiresPrompt(source: .intent, preview: preview))
    }
}

private struct ConfigurableSwitcher: AppSwitching {
    var plan: SwitchPlan
    func plan(from source: Profile?, to target: Profile) -> SwitchPlan { plan }
    func execute(_ plan: SwitchPlan) async -> SwitchOutcome { SwitchOutcome() }
}
