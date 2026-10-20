import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct OperationLockProbeTests {
    @Test func sameProcessProbeDoesNotReleaseHeldMutationLocks() async throws {
        let root = ExternalTestSupport.tempSupportRoot()
        let locks = try OperationLock(supportRoot: root)

        try await locks.withMutationLocks(timeout: .seconds(2)) {
            #expect(locks.isPreviewHeld())
            #expect(locks.isOperationHeld())
            _ = locks.isPreviewHeld()
            _ = locks.isOperationHeld()
            #expect(locks.isPreviewHeld())
            #expect(locks.isOperationHeld())
        }
    }

    @Test func sharedLockProbeDoesNotReleaseSharedHold() async throws {
        let root = ExternalTestSupport.tempSupportRoot()
        let locks = try OperationLock(supportRoot: root)

        try await locks.withSharedOperation(timeout: .seconds(2)) {
            #expect(!locks.isOperationHeld())
            _ = locks.isPreviewHeld()
            #expect(!locks.isOperationHeld())
        }
    }

    @Test func childProcessContentionIsVisible() async throws {
        let root = ExternalTestSupport.tempSupportRoot()
        let lockURL = try SupportPaths.operationLockURL()
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, time
            f = open('\(lockURL.path)', 'a')
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            time.sleep(4)
            """,
        ]
        try process.run()
        try await Task.sleep(for: .milliseconds(300))

        let probe = try OperationLock(supportRoot: root)
        #expect(probe.isOperationHeld())

        process.terminate()
        process.waitUntilExit()
    }
}
