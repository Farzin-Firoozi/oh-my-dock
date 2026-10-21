import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct OperationLockProbeTests {
    @Test func sameProcessProbeDoesNotReleaseHeldMutationLocks() async throws {
        try await ExternalTestSupport.withSupportRoot { root in
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
    }

    @Test func inProcessPreviewHolderIsNotDroppedByMutationLocks() async throws {
        try await ExternalTestSupport.withSupportRoot { root in
            let locks = try OperationLock(supportRoot: root)
            try await locks.withExclusivePreview {
                await #expect(throws: OperationLockError.busy(reason: .previewActive)) {
                    try await locks.withMutationLocks(timeout: .zero) {}
                }
                #expect(locks.isPreviewHeld())
            }
            #expect(!locks.isPreviewHeld())
        }
    }

    @Test func sharedLockProbeDoesNotReleaseSharedHold() async throws {
        try await ExternalTestSupport.withSupportRoot { root in
        let locks = try OperationLock(supportRoot: root)

        try await locks.withSharedOperation(timeout: .seconds(2)) {
            #expect(!locks.isOperationHeld())
            _ = locks.isPreviewHeld()
            #expect(!locks.isOperationHeld())
        }
        }
    }

    @Test func childProcessContentionIsVisible() async throws {
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
            time.sleep(4)
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
        }
    }
}
