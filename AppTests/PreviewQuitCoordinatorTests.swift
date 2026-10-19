import Foundation
import Testing

@MainActor
private final class FakeReverter: PreviewReverting {
    var isPreviewing: Bool
    var succeeds = true
    var delay: Duration = .zero
    private(set) var revertCalls = 0

    init(isPreviewing: Bool) { self.isPreviewing = isPreviewing }

    func revert() async -> Bool {
        revertCalls += 1
        if delay != .zero { try? await Task.sleep(for: delay) }
        if succeeds { isPreviewing = false }
        return succeeds
    }
}

@MainActor
@Suite struct PreviewQuitCoordinatorTests {
    @Test func quitWithNoRegisteredPanelHasNothingToRevert() async {
        let coordinator = PreviewQuitCoordinator()
        #expect(!coordinator.hasActivePreview)
        #expect(await coordinator.revertForQuit() == .nothingToRevert)
    }

    @Test func quitWithoutAPreviewDoesNotRevert() async {
        let coordinator = PreviewQuitCoordinator()
        let reverter = FakeReverter(isPreviewing: false)
        coordinator.register(reverter)
        #expect(!coordinator.hasActivePreview)
        #expect(await coordinator.revertForQuit() == .nothingToRevert)
        #expect(reverter.revertCalls == 0)
    }

    @Test func quitRevertsAnActivePreviewFirst() async {
        let coordinator = PreviewQuitCoordinator()
        let reverter = FakeReverter(isPreviewing: true)
        coordinator.register(reverter)
        #expect(coordinator.hasActivePreview)
        let outcome = await coordinator.revertForQuit()
        #expect(outcome == .reverted)
        #expect(outcome.leavesDockRestored)
        #expect(reverter.revertCalls == 1)
        #expect(!reverter.isPreviewing)
    }

    @Test func failedRevertIsReportedSoTheUserCanDecide() async {
        let coordinator = PreviewQuitCoordinator()
        let reverter = FakeReverter(isPreviewing: true)
        reverter.succeeds = false
        coordinator.register(reverter)
        let outcome = await coordinator.revertForQuit()
        #expect(outcome == .failed)
        #expect(!outcome.leavesDockRestored)
        #expect(coordinator.hasActivePreview)
    }

    @Test func slowRevertIsBoundedByTheTimeout() async {
        let coordinator = PreviewQuitCoordinator(timeout: .milliseconds(30))
        let reverter = FakeReverter(isPreviewing: true)
        reverter.delay = .seconds(5)
        coordinator.register(reverter)
        let started = ContinuousClock.now
        let outcome = await coordinator.revertForQuit()
        #expect(outcome == .timedOut)
        #expect(!outcome.leavesDockRestored)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func fastRevertBeatsTheTimeoutAndLateTimerIsIgnored() async {
        let coordinator = PreviewQuitCoordinator(timeout: .milliseconds(80))
        let reverter = FakeReverter(isPreviewing: true)
        coordinator.register(reverter)
        #expect(await coordinator.revertForQuit() == .reverted)
        try? await Task.sleep(for: .milliseconds(120))
    }

    @Test func coordinatorDoesNotKeepAClosedPanelAlive() async {
        let coordinator = PreviewQuitCoordinator()
        var reverter: FakeReverter? = FakeReverter(isPreviewing: true)
        coordinator.register(reverter!)
        reverter = nil
        #expect(!coordinator.hasActivePreview)
        #expect(await coordinator.revertForQuit() == .nothingToRevert)
    }
}
