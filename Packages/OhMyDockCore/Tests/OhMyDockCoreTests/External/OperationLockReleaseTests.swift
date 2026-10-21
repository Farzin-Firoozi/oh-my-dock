import Darwin
import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct OperationLockReleaseTests {
    @Test func lockReleasedWhenHolderProcessDies() async throws {
        try await ExternalTestSupport.withSupportRoot { root in
        let lockURL = root.appendingPathComponent("operation.lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, time
            f = open('\(lockURL.path)', 'a')
            fcntl.lockf(f.fileno(), fcntl.LOCK_EX)
            time.sleep(5)
            """,
        ]
        try process.run()
        let probe = try OperationLock(supportRoot: root)
        for _ in 0..<50 where !probe.isOperationHeld() {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(probe.isOperationHeld())
        process.terminate()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!probe.isOperationHeld())
        }
    }
}
