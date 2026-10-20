import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct ExternalCommandCenterTests {
    @Test func listIsEmptyInitially() async throws {
        try await ExternalTestSupport.withSupportRoot { _ in
            let center = try ExternalTestSupport.makeCenter()
            let result = await center.run(ExternalRequest(command: .list, source: .cli))
            #expect(result.exitCode == 0)
            #expect(result.envelope.result?.profiles?.isEmpty == true)
        }
    }

    @Test func livePlistOverrideIsRefused() async throws {
        let support = ExternalTestSupport.tempSupportRoot()
        let live = DockPlistEnvironment.liveDockPlistURL.path
        try await ExternalTestSupport.withEnvironment([
            SupportPaths.supportDirEnvironmentKey: support.path,
            DockPlistEnvironment.overrideKey: live,
        ]) {
            let center = try ExternalTestSupport.makeCenter(supportRoot: support)
            let result = await center.run(ExternalRequest(command: .list, source: .cli))
            #expect(result.exitCode == 2)
            #expect(result.envelope.error?.reason == "liveDockPlistRefused")
        }
    }

    @Test func applyNoChangesIsIdempotent() async throws {
        try await ExternalTestSupport.withSupportRoot { _ in
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
    }

    @Test func undoAndRestoreErrorsKeepTheirExitCodes() async throws {
        try await ExternalTestSupport.withSupportRoot { _ in
            let center = try ExternalTestSupport.makeCenter()
            let undo = await center.run(ExternalRequest(command: .undo, source: .cli))
            #expect(undo.exitCode == 3)
            let restore = await center.run(ExternalRequest(command: .restore(id: UUID()), source: .cli, yes: true))
            #expect(restore.exitCode == 3)
        }
    }

    @Test func quitsAreCoveredOnlyBySupersetPreview() {
        func preview(_ ids: [String]) -> ApplyPreview {
            ApplyPreview(
                profileName: "P", current: DockState(), target: DockState(),
                plan: DockPlan(operations: [], summary: ""), skipped: [],
                switchPlan: SwitchPlan(scope: .none, willQuit: ids.enumerated().map {
                    RunningAppInfo(processIdentifier: Int32($0.offset), bundleId: $0.element, name: $0.element, activationPolicy: .regular, isFinishedLaunching: true)
                }, willLaunch: [])
            )
        }
        #expect(preview(["a"]).quitsAreCovered(by: preview(["a", "b"])))
        #expect(!preview(["a", "b"]).quitsAreCovered(by: preview(["a"])))
        let missing = SkippedItem(section: .apps, index: 0, app: AppRef(bundleId: "gone", name: "Gone", path: "/Applications/Gone.app", launchOnSwitch: false))
        let withSkipped = ApplyPreview(
            profileName: "P", current: DockState(), target: DockState(),
            plan: DockPlan(operations: [], summary: ""), skipped: [missing]
        )
        #expect(!withSkipped.quitsAreCovered(by: preview([])))
        #expect(withSkipped.quitsAreCovered(by: withSkipped))
    }

    @Test func quitRequiresBothFlags() async throws {
        try await ExternalTestSupport.withSupportRoot { _ in
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
    }

    @Test func snapshotSourceTagRoundTrip() async throws {
        try await ExternalTestSupport.withSupportRoot { _ in
            let snapshots = SnapshotStore(rootDirectory: try SupportPaths.snapshotsDirectory())
            let saved = try await snapshots.save(reason: "Before applying profile Tagged", profileName: "Tagged", source: .cli)
            #expect(saved.source == .cli)
            let listed = await snapshots.list().snapshots
            #expect(listed.first?.source == .cli)
        }
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
