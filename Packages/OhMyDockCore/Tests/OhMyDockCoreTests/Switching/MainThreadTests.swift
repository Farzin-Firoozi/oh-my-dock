import Foundation
import Testing
@testable import OhMyDockCore

private func probeThreads() -> (caller: Bool, body: Bool) {
    (Thread.isMainThread, MainThread.run { Thread.isMainThread })
}

@Suite struct MainThreadTests {
    @Test(.timeLimit(.minutes(1)))
    func backgroundCallerRunsBodyOnTheMainThread() async {
        let onMain = await Task.detached { probeThreads() }.value
        #expect(onMain.caller == false)
        #expect(onMain.body == true)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func mainThreadCallerRunsInlineWithoutDeadlock() {
        #expect(MainThread.run { Thread.isMainThread })
    }

    @Test(.timeLimit(.minutes(1)))
    func resultIsReturnedToTheCaller() async {
        let value = await Task.detached { MainThread.run { 42 } }.value
        #expect(value == 42)
    }
}
