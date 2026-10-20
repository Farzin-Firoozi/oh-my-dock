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
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            time.sleep(5)
            """,
        ]
        try process.run()
        try await Task.sleep(for: .milliseconds(300))
        let probe = try OperationLock(supportRoot: root)
        #expect(probe.isOperationHeld())
        process.terminate()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!probe.isOperationHeld())
        }
    }
}
