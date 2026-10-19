import Foundation
import OhMyDockCore
import Testing

/// Fake Dock: holds "live" prefs in memory, records calls, can be slowed or made to fail.
private actor FakePreviewer: DockPrefsPreviewing {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    private(set) var live: DockPrefs
    private(set) var beginCalls: [DockPrefs] = []
    private(set) var revertCalls = 0
    private(set) var running = 0
    private(set) var maxRunning = 0
    var failBegin = false
    var failRevert = false
    var failCapture = false
    var delay: Duration = .zero
    private let captured: DockPrefs

    init(live: DockPrefs = DockPrefs(tileSize: 70, autohide: true)) {
        self.live = live
        captured = live
    }

    nonisolated func captureCurrent() throws -> DockPrefs {
        // Synchronous protocol requirement: the flag is read through the unsafe snapshot below.
        if Flags.shared.failCapture { throw Boom() }
        return Flags.shared.captured
    }

    func begin(_ prefs: DockPrefs) async throws -> PrefsPreviewSession? {
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        beginCalls.append(prefs)
        if delay != .zero { try await Task.sleep(for: delay) }
        if failBegin { throw Boom() }
        if prefs == live { return nil }
        live = prefs
        return PrefsPreviewSession(snapshotID: UUID(), image: DockPrefsRollbackImage(previousValues: [:]), changedKeys: [.tileSize])
    }

    func revert(_ session: PrefsPreviewSession) async throws {
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        revertCalls += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if failRevert { throw Boom() }
        live = captured
    }

    func configure(failBegin: Bool? = nil, failRevert: Bool? = nil, delay: Duration? = nil) {
        if let failBegin { self.failBegin = failBegin }
        if let failRevert { self.failRevert = failRevert }
        if let delay { self.delay = delay }
    }

    enum Flags {
        final class Box: @unchecked Sendable {
            var failCapture = false
            var captured = DockPrefs(tileSize: 70, autohide: true)
        }
        static let shared = Box()
    }
}

@MainActor
private struct Rig {
    let panel: PrefsPanelViewModel
    let previewer: FakePreviewer
    let gate: DockOperationGate
    let saves: Saves

    @MainActor final class Saves {
        var log: [DockPrefs?] = []
        var refuse = false
    }

    let id = UUID()

    init(prefs: DockPrefs? = nil, live: DockPrefs = DockPrefs(tileSize: 70, autohide: true)) {
        FakePreviewer.Flags.shared.failCapture = false
        FakePreviewer.Flags.shared.captured = live
        let previewer = FakePreviewer(live: live)
        let gate = DockOperationGate()
        let saves = Saves()
        let panel = PrefsPanelViewModel(previewer: previewer, gate: gate) { _, prefs in
            if saves.refuse { return false }
            saves.log.append(prefs)
            return true
        }
        self.previewer = previewer
        self.gate = gate
        self.saves = saves
        self.panel = panel
        panel.bind(profileID: id, name: "Work", prefs: prefs)
    }
}

@MainActor
@Suite(.serialized) struct PrefsPanelViewModelTests {
    @Test func togglingOnSeedsFromDockAndOffSetsNil() {
        let rig = Rig()
        rig.panel.setManaged(true)
        #expect(rig.panel.isManaged)
        // Captured keys win; keys the Dock doesn't store are reset to the system default, not guessed.
        #expect(rig.panel.prefs?.tileSize == 70)
        #expect(rig.panel.prefs?.autohide == true)
        #expect(rig.panel.prefs?.minimizeEffect == nil)
        #expect(rig.panel.prefs?.resetKeys == Set(DockPrefs.Key.allCases).subtracting([.tileSize, .autohide]))

        rig.panel.setManaged(false)
        #expect(rig.panel.prefs == nil)
        #expect(rig.saves.log.last! == nil)
        #expect(rig.saves.log.count == 2)
    }

    @Test func togglingOnResetsEverythingWhenDockUnreadable() {
        let rig = Rig()
        FakePreviewer.Flags.shared.failCapture = true
        rig.panel.setManaged(true)
        #expect(rig.panel.prefs == .allSystemDefaults)
        #expect(rig.panel.message?.kind == .error)
    }

    @Test func editsClampToValidRanges() {
        let rig = Rig(prefs: .displayDefaults)
        rig.panel.set(\.tileSize, to: 500)
        #expect(rig.panel.prefs?.tileSize == 128)
        rig.panel.set(\.tileSize, to: -3)
        #expect(rig.panel.prefs?.tileSize == 16)
        rig.panel.set(\.autohideDelay, to: 99)
        #expect(rig.panel.prefs?.autohideDelay == 10)
        rig.panel.set(\.autohideTimeModifier, to: .nan)
        #expect(rig.panel.prefs?.autohideTimeModifier == 0)
        rig.panel.set(\.largeSize, to: 200)
        #expect(rig.panel.prefs?.largeSize == 128)
        // The saved value is the clamped one, so validation can never fail on it.
        #expect(rig.saves.log.last??.largeSize == 128)
        #expect(throws: Never.self) { try rig.panel.prefs?.validate() }
    }

    @Test func editsWhileUnmanagedAreIgnored() {
        let rig = Rig()
        rig.panel.set(\.tileSize, to: 40)
        #expect(rig.panel.prefs == nil)
        #expect(rig.saves.log.isEmpty)
    }

    @Test func captureReplacesValuesWithTheDocks() {
        let rig = Rig(prefs: .displayDefaults, live: DockPrefs(tileSize: 33, orientation: .left))
        rig.panel.captureFromDock()
        #expect(rig.panel.prefs?.tileSize == 33)
        #expect(rig.panel.prefs?.orientation == .left)
        #expect(rig.panel.prefs?.launchAnimation == nil)
        #expect(rig.panel.prefs?.resetKeys.contains(.launchAnimation) == true)
        #expect(rig.panel.message?.kind == .success)
    }

    @Test func captureFailureKeepsValuesAndReports() {
        let rig = Rig(prefs: DockPrefs(tileSize: 20))
        FakePreviewer.Flags.shared.failCapture = true
        rig.panel.captureFromDock()
        #expect(rig.panel.prefs?.tileSize == 20)
        #expect(rig.panel.message?.kind == .error)
    }

    @Test func resetInventsNoNumbersAndMarksEveryKeyForRemoval() {
        let rig = Rig(prefs: DockPrefs(tileSize: 20, autohide: true))
        rig.panel.resetToDefaults()
        let saved = rig.saves.log.last!
        #expect(rig.panel.prefs == .allSystemDefaults)
        #expect(saved == .allSystemDefaults)
        #expect(saved?.values.isEmpty == true)
        #expect(saved?.resetKeys == Set(DockPrefs.Key.allCases))
        #expect(throws: Never.self) { try saved?.validate() }
    }

    @Test func editingAResetKeyGivesItAValueAgain() {
        let rig = Rig(prefs: .allSystemDefaults)
        rig.panel.set(\.tileSize, to: 40)
        #expect(rig.panel.prefs?.tileSize == 40)
        #expect(rig.panel.prefs?.resetKeys.contains(.tileSize) == false)
        #expect(rig.panel.prefs?.resetKeys.count == DockPrefs.Key.allCases.count - 1)
        #expect(throws: Never.self) { try rig.panel.prefs?.validate() }
    }

    @Test func refusedSaveLeavesValuesUnchanged() {
        let rig = Rig(prefs: .displayDefaults)
        rig.saves.refuse = true
        rig.panel.set(\.tileSize, to: 20)
        #expect(rig.panel.prefs?.tileSize == 48)
        #expect(rig.panel.message?.kind == .error)
    }

    @Test func previewAppliesOnlyPrefsAndRevertRestores() async {
        let rig = Rig(prefs: DockPrefs.displayDefaults)
        await rig.panel.preview()
        #expect(rig.panel.isPreviewing)
        #expect(rig.panel.previewedProfileName == "Work")
        #expect(await rig.previewer.beginCalls == [.displayDefaults])
        #expect(await rig.previewer.live == .displayDefaults)

        #expect(await rig.panel.revert())
        #expect(!rig.panel.isPreviewing)
        #expect(await rig.previewer.revertCalls == 1)
        #expect(await rig.previewer.live == DockPrefs(tileSize: 70, autohide: true))
        #expect(rig.gate.isBusy == false)
    }

    @Test func activePreviewIsVisibleOnTheSharedGateUntilRevertedOrKept() async {
        let rig = Rig(prefs: .displayDefaults)
        #expect(!rig.gate.isPreviewActive)
        await rig.panel.preview()
        #expect(rig.gate.isPreviewActive)
        #expect(await rig.panel.revert())
        #expect(!rig.gate.isPreviewActive)

        await rig.panel.preview()
        #expect(rig.gate.isPreviewActive)
        rig.panel.keepPreview()
        #expect(!rig.gate.isPreviewActive)
    }

    @Test func failedRevertKeepsThePreviewFlagSoApplyStaysBlocked() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        await rig.previewer.configure(failRevert: true)
        #expect(await rig.panel.revert() == false)
        #expect(rig.gate.isPreviewActive)
    }

    @Test func previewWhenDockAlreadyMatchesStartsNothing() async {
        let live = DockPrefs.displayDefaults
        let rig = Rig(prefs: live, live: live)
        await rig.panel.preview()
        #expect(!rig.panel.isPreviewing)
        #expect(rig.panel.message?.kind == .info)
    }

    @Test func previewWithoutManagedPrefsDoesNothing() async {
        let rig = Rig()
        await rig.panel.preview()
        #expect(await rig.previewer.beginCalls.isEmpty)
    }

    @Test func previewAgainRevertsFirstSoRevertTargetStaysOriginal() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        rig.panel.set(\.tileSize, to: 30)
        await rig.panel.preview()
        #expect(await rig.previewer.revertCalls == 1)
        #expect(await rig.previewer.beginCalls.count == 2)
        #expect(rig.panel.isPreviewing)
    }

    @Test func previewFailureReportsAndLeavesNoPreview() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.previewer.configure(failBegin: true)
        await rig.panel.preview()
        #expect(!rig.panel.isPreviewing)
        #expect(rig.panel.message == .init(kind: .error, text: "boom"))
        #expect(rig.gate.isBusy == false)
        #expect(rig.panel.isWorking == false)
    }

    @Test func revertFailureKeepsPreviewSoItCanBeRetried() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        await rig.previewer.configure(failRevert: true)
        #expect(await rig.panel.revert() == false)
        #expect(rig.panel.isPreviewing)
        #expect(rig.panel.message?.kind == .error)

        await rig.previewer.configure(failRevert: false)
        #expect(await rig.panel.revert())
        #expect(!rig.panel.isPreviewing)
    }

    @Test func cancelOrCloseWithPreviewRevertsOnRequest() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        #expect(await rig.panel.resolvePreview(revert: true))
        #expect(!rig.panel.isPreviewing)
        #expect(await rig.previewer.live == DockPrefs(tileSize: 70, autohide: true))
    }

    @Test func keepEndsPreviewWithoutReverting() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        #expect(await rig.panel.resolvePreview(revert: false))
        #expect(!rig.panel.isPreviewing)
        #expect(await rig.previewer.revertCalls == 0)
        #expect(await rig.previewer.live == .displayDefaults)
    }

    @Test func resolveWithoutPreviewIsANoOp() async {
        let rig = Rig(prefs: .displayDefaults)
        #expect(await rig.panel.resolvePreview(revert: true))
        #expect(await rig.previewer.revertCalls == 0)
    }

    @Test func captureIsRefusedWhileAPreviewIsOnTheDock() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        rig.panel.captureFromDock()
        #expect(rig.panel.prefs == .displayDefaults)
    }

    @Test func previewWaitsForAnotherDockOperation() async {
        let rig = Rig(prefs: .displayDefaults)
        let order = Order()
        let other = Task { @MainActor in
            await rig.gate.run("Applying a profile") {
                await order.add("other-start")
                try? await Task.sleep(for: .milliseconds(80))
                await order.add("other-end")
            }
        }
        // Let the other operation take the gate first.
        while !rig.gate.isBusy { await Task.yield() }
        await rig.panel.preview()
        await order.add("preview-done")
        await other.value
        #expect(await order.items == ["other-start", "other-end", "preview-done"])
        #expect(await rig.previewer.beginCalls.count == 1)
        #expect(rig.panel.isPreviewing)
    }

    @Test func previewAndRevertNeverOverlapOnTheDock() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.previewer.configure(delay: .milliseconds(30))
        await rig.panel.preview()
        async let a: Void = rig.panel.preview()
        async let b = rig.panel.revert()
        _ = await (a, b)
        #expect(await rig.previewer.maxRunning == 1)
    }

    @Test func secondPreviewWhileOneIsRunningIsIgnored() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.previewer.configure(delay: .milliseconds(40))
        async let first: Void = rig.panel.preview()
        async let second: Void = rig.panel.preview()
        _ = await (first, second)
        #expect(await rig.previewer.beginCalls.count == 1)
    }

    @Test func bindingAnotherProfileKeepsAnActivePreview() async {
        let rig = Rig(prefs: .displayDefaults)
        await rig.panel.preview()
        rig.panel.bind(profileID: UUID(), name: "Home", prefs: nil)
        #expect(rig.panel.isPreviewing)
        #expect(rig.panel.previewedProfileName == "Work")
        #expect(rig.panel.prefs == nil)
    }
}

private actor Order {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}
