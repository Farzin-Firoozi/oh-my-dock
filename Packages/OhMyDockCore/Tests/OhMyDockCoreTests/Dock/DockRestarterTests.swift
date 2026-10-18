import Foundation
import Testing
@testable import OhMyDockCore

/// `LiveDockRestarter` is only ever given a recording runner here; `killall Dock` is never run.
@Suite struct DockRestarterTests {
    @Test func liveRestarterRunsKillallDock() async throws {
        let runner = ScriptedProcessRunner()

        try await LiveDockRestarter(processRunner: runner).restart()

        #expect(runner.calls == [
            ScriptedProcessRunner.Call(
                executableURL: URL(fileURLWithPath: "/usr/bin/killall"),
                arguments: ["Dock"]
            ),
        ])
    }

    @Test func nonZeroExitIsReported() async throws {
        let runner = ScriptedProcessRunner { _, _ in
            ProcessResult(terminationStatus: 1, standardError: "No matching processes")
        }

        await #expect(throws: DockRestartError.commandFailed(exitStatus: 1, standardError: "No matching processes")) {
            try await LiveDockRestarter(processRunner: runner).restart()
        }
    }

    @Test func launchFailureIsReported() async throws {
        let runner = ScriptedProcessRunner { _, _ in throw ScriptedProcessRunner.LaunchError() }

        let error = await #expect(throws: DockRestartError.self) {
            try await LiveDockRestarter(processRunner: runner).restart()
        }

        guard case let .launchFailed(path, _)? = error else {
            Issue.record("Expected launchFailed, got \(String(describing: error))")
            return
        }
        #expect(path == "/usr/bin/killall")
    }

    @Test func noopRestarterDoesNothing() async throws {
        let restarter: any DockRestarting = NoopDockRestarter()
        try await restarter.restart()
    }

    @Test func staticCommandIsKillallDock() {
        #expect(LiveDockRestarter.executableURL.path == "/usr/bin/killall")
        #expect(LiveDockRestarter.arguments == ["Dock"])
    }
}
