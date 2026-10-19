import Foundation
import Testing
@testable import OhMyDockCore

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    private var _log: [String] = []

    var log: [String] { lock.withLock { _log } }

    func enter(_ name: String) { lock.withLock { active += 1; maxActive = max(maxActive, active); _log.append("start \(name)") } }
    func leave(_ name: String) { lock.withLock { active -= 1; _log.append("end \(name)") } }
}

@Suite("SwitchQueue")
struct SwitchQueueTests {
    @Test func operationsNeverOverlap() async {
        let queue = SwitchQueue()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await queue.run(supersedingEarlier: false) {
                        probe.enter("\(i)")
                        for _ in 0..<20 { await Task.yield() }
                        probe.leave("\(i)")
                    }
                }
            }
        }
        #expect(probe.maxActive == 1)
        #expect(probe.log.count == 10)
    }

    @Test func returnsOperationResult() async {
        let queue = SwitchQueue()
        let value = await queue.run { 42 }
        #expect(value == 42)
    }

    @Test func switchesDoNotInterleaveQuitPhases() async {
        let rig = Rig()
        let queue = SwitchQueue()
        let first = [info(1, "a"), info(2, "b"), info(3, "c")]
        let second = [info(4, "d"), info(5, "e")]
        for app in first + second { rig.apps.add(app, behavior: .quits(after: .milliseconds(300))) }
        let switcher = rig.switcher

        async let r1 = queue.run(supersedingEarlier: false) {
            await switcher.execute(SwitchPlan(scope: .none, willQuit: first))
        }
        async let r2 = queue.run(supersedingEarlier: false) {
            await switcher.execute(SwitchPlan(scope: .none, willQuit: second))
        }
        let (o1, o2) = await (r1, r2)

        #expect(!o1.wasCancelled && !o2.wasCancelled)
        let firstPids = Set(first.map(\.processIdentifier))
        let order = rig.apps.terminated
        #expect(order.count == 5)
        // All pids of one plan come before all pids of the other.
        let kinds = order.map { firstPids.contains($0) }
        #expect(kinds == [true, true, true, false, false] || kinds == [false, false, true, true, true])
    }

    @Test func newerSwitchSupersedesInFlightOne() async {
        let rig = Rig()
        let queue = SwitchQueue()
        let slow = [info(1, "a"), info(2, "b"), info(3, "c")]
        let quick = [info(4, "d")]
        for app in slow { rig.apps.add(app, behavior: .quits(after: .seconds(1))) }
        rig.apps.add(quick[0])
        let switcher = rig.switcher

        let firstTask = Task {
            await queue.run { await switcher.execute(SwitchPlan(scope: .none, willQuit: slow)) }
        }
        // Make sure the first switch is in flight before superseding it.
        while rig.apps.terminated.isEmpty { await Task.yield() }
        let second = await queue.run { await switcher.execute(SwitchPlan(scope: .none, willQuit: quick)) }
        let first = await firstTask.value

        #expect(first.wasCancelled)
        #expect(first.quits.count == 3)
        #expect(first.quits.contains { $0.status == .skippedCancelled })
        #expect(!second.wasCancelled)
        #expect(second.quits.map(\.status) == [.quit])
        // Nothing from the cancelled switch was asked after the new one started.
        #expect(rig.apps.terminated.last == 4)
    }

    @Test func callerCancellationCancelsOperation() async {
        let queue = SwitchQueue()
        let task = Task { await queue.run { () -> Bool in
            for _ in 0..<1000 { if Task.isCancelled { return true }; await Task.yield() }
            return false
        } }
        await Task.yield()
        task.cancel()
        #expect(await task.value)
    }
}
