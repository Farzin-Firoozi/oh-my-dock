import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct FakeDockBackendTests {
    private let app1 = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
    private let app2 = DockItem.app(AppRef(bundleId: "com.apple.Mail", name: "Mail"))
    private let folder1 = DockItem.folder(FolderItem(path: "/Users/me/Downloads"))

    @Test func initialReadReturnsState() async throws {
        let initial = DockState(apps: [app1], others: [folder1])
        let backend = FakeDockBackend(state: initial)

        let readState = try await backend.read()
        #expect(readState == initial)
        #expect(await backend.readCount == 1)
        #expect(await backend.appliedBatches.isEmpty)
    }

    @Test func recordsAppliedBatchesAndReadCount() async throws {
        let backend = FakeDockBackend()
        #expect(await backend.readCount == 0)
        #expect(await backend.appliedBatches.isEmpty)

        _ = try await backend.read()
        _ = try await backend.read()
        #expect(await backend.readCount == 2)

        let batch1: [DockOperation] = [.insert(app1, section: .apps, index: 0)]
        let batch2: [DockOperation] = [.insert(app2, section: .apps, index: 1)]

        try await backend.apply(batch1)
        try await backend.apply(batch2)

        let batches = await backend.appliedBatches
        #expect(batches.count == 2)
        #expect(batches[0] == batch1)
        #expect(batches[1] == batch2)

        let currentState = await backend.state
        #expect(currentState.apps == [app1, app2])
    }

    @Test func failureInjectionThrowsAndIsOneShot() async throws {
        let backend = FakeDockBackend(state: DockState(apps: [app1]))
        let expectedError = DockBackendError.commandFailed("simulated dockutil failure")

        await backend.failNextApply(with: expectedError)

        let batch: [DockOperation] = [.insert(app2, section: .apps, index: 1)]

        await #expect(throws: expectedError) {
            try await backend.apply(batch)
        }

        // Call was recorded despite the error
        let batches = await backend.appliedBatches
        #expect(batches == [batch])

        // State remains unchanged
        let stateAfterFailure = await backend.state
        #expect(stateAfterFailure.apps == [app1])

        // Next apply succeeds because failNextApply is one-shot
        try await backend.apply(batch)
        let stateAfterSuccess = await backend.state
        #expect(stateAfterSuccess.apps == [app1, app2])
        #expect(await backend.appliedBatches.count == 2)
    }

    @Test func corruptNextWriteFailsVerificationAndStoresCorruptedState() async throws {
        let initial = DockState(apps: [app1])
        let backend = FakeDockBackend(state: initial)

        await backend.corruptNextWrite()

        let batch: [DockOperation] = [.insert(app2, section: .apps, index: 1)]
        let expectedState = DockState(apps: [app1, app2])

        var caughtExpected: DockState?
        var caughtActual: DockState?

        do {
            try await backend.apply(batch)
            Issue.record("Expected apply to throw verificationFailed")
        } catch let DockBackendError.verificationFailed(expected, actual) {
            caughtExpected = expected
            caughtActual = actual
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }

        #expect(caughtExpected == expectedState)
        #expect(caughtActual != nil && caughtActual != expectedState)

        // The corrupted state is stored in the backend (enabling rollback tests)
        let storedState = await backend.state
        #expect(storedState == caughtActual)

        // Subsequent apply succeeds without corruption (corruptNextWrite is one-shot)
        let recoveryBatch: [DockOperation] = [.replaceAll(initial)]
        try await backend.apply(recoveryBatch)
        let recoveredState = await backend.state
        #expect(recoveredState == initial)
    }

    @Test func corruptNextWriteWithExplicitState() async throws {
        let initial = DockState(apps: [app1])
        let backend = FakeDockBackend(state: initial)
        let explicitCorrupted = DockState(apps: [app1], others: [folder1])

        await backend.corruptNextWrite(to: explicitCorrupted)

        let batch: [DockOperation] = [.insert(app2, section: .apps, index: 1)]
        let expectedState = DockState(apps: [app1, app2])

        await #expect(throws: DockBackendError.verificationFailed(expected: expectedState, actual: explicitCorrupted)) {
            try await backend.apply(batch)
        }

        let storedState = await backend.state
        #expect(storedState == explicitCorrupted)
    }

    @Test func applyPropagatesApplyingErrorsWithoutMutatingState() async throws {
        let initial = DockState(apps: [app1])
        let backend = FakeDockBackend(state: initial)

        let badBatch: [DockOperation] = [.remove(section: .apps, index: 5)]

        await #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 5)) {
            try await backend.apply(badBatch)
        }

        #expect(await backend.state == initial)
        #expect(await backend.appliedBatches.count == 1)
    }
}
