import Foundation
import Testing
@testable import OhMyDockCore

// MARK: - Fakes (in memory only: no live Dock, no real apps)

private struct Boom: Error, Equatable {}

/// Stands in for the `com.apple.dock` plist domain behind `SnapshotStore`. `onImport` plays the
/// Dock reloading what a restore imported.
private actor DomainIO: DockDomainIO {
    private(set) var data: Data
    private(set) var imports = 0
    private let onImport: (@Sendable () async -> Void)?

    init(data: Data, onImport: (@Sendable () async -> Void)? = nil) {
        self.data = data
        self.onImport = onImport
    }

    func exportDomain(to url: URL) async throws { try data.write(to: url) }

    func importDomain(from url: URL) async throws {
        imports += 1
        data = try Data(contentsOf: url)
        await onImport?()
    }
}

/// Shared log of what happened in what order.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var entries: [String] { lock.withLock { items } }
}

private actor LoggingRestarter: DockRestarting {
    private(set) var count = 0
    private let log: Log
    private let hook: (@Sendable (Int) async -> Void)?

    init(log: Log, hook: (@Sendable (Int) async -> Void)? = nil) {
        self.log = log
        self.hook = hook
    }

    func restart() async throws {
        count += 1
        log.add("restart")
        await hook?(count)
    }
}

/// A prefs domain that silently drops writes to some keys, like a Dock that does not take a value.
private final class StubbornPrefsIO: DockPrefsDomainIO, @unchecked Sendable {
    let inner: InMemoryDockPrefsDomainIO
    private let ignoring: Set<String>

    init(initial: [String: Any], ignoring: Set<String>) {
        inner = InMemoryDockPrefsDomainIO(initial: initial)
        self.ignoring = ignoring
    }

    func synchronize() {}
    func value(forKey key: String) -> Any? { inner.value(forKey: key) }
    func setValue(_ value: Any?, forKey key: String) {
        if !ignoring.contains(key) { inner.setValue(value, forKey: key) }
    }
    func allKeys() -> Set<String> { inner.allKeys() }
}

/// Counts reads of the preferences so "nil prefs = untouched" is checkable.
private final class CountingPrefsWriter: DockPrefsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (capture: 0, apply: 0, rollback: 0)
    let inner: DockPrefsWriter

    init(io: any DockPrefsDomainIO) { inner = DockPrefsWriter(domainIO: io) }

    var captureCount: Int { lock.withLock { counts.capture } }
    var applyCount: Int { lock.withLock { counts.apply } }
    var rollbackCount: Int { lock.withLock { counts.rollback } }

    func captureCurrent() throws -> DockPrefsCapture {
        lock.withLock { counts.capture += 1 }
        return try inner.captureCurrent()
    }
    func diff(current: DockPrefsCapture, target: DockPrefs) throws -> PrefsDiff {
        try inner.diff(current: current, target: target)
    }
    func apply(_ target: DockPrefs, expecting baseline: DockPrefsCapture?) throws -> DockPrefsApplyResult {
        lock.withLock { counts.apply += 1 }
        return try inner.apply(target, expecting: baseline)
    }
    func rollback(_ image: DockPrefsRollbackImage) throws {
        lock.withLock { counts.rollback += 1 }
        try inner.rollback(image)
    }
}

private let calculator = Sample.calculator
private let calendarApp = Sample.calendar
private let notes = Sample.notes
private let pathAsGiven: ProfileApplier.AppPathResolver = { $0.path }

private func plistData() throws -> Data {
    let domain: [String: Any] = ["persistent-apps": [Any](), "persistent-others": [Any]()]
    return try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
}

private let slack = "com.example.slack"
private let figma = "com.example.figma"

private struct World {
    let root: URL
    let io: DomainIO
    let store: SnapshotStore
    let backend: FakeDockBackend
    let log = Log()
    let restarter: LoggingRestarter
    let prefsIO: InMemoryDockPrefsDomainIO
    let writer: CountingPrefsWriter
    let rig = Rig()
    let current: DockState

    init(
        current: DockState = DockState(apps: [calendarApp]),
        prefs: [String: Any] = ["tilesize": 48.0, "autohide": false],
        prefsIO override: (any DockPrefsDomainIO)? = nil,
        restartHook: (@Sendable (Int) async -> Void)? = nil
    ) throws {
        self.current = current
        root = try makeTempDirectory("omd-applier-prefs")
        let backend = FakeDockBackend(state: current)
        self.backend = backend
        io = DomainIO(data: try plistData(), onImport: { await backend.setState(current) })
        store = SnapshotStore(rootDirectory: root.appendingPathComponent("snapshots"), domainIO: io)
        restarter = LoggingRestarter(log: log, hook: restartHook)
        prefsIO = (override as? StubbornPrefsIO)?.inner ?? InMemoryDockPrefsDomainIO(initial: prefs)
        writer = CountingPrefsWriter(io: override ?? prefsIO)
    }

    func applier(switcher: Bool = true, writer useWriter: Bool = true) -> ProfileApplier {
        ProfileApplier(
            backend: backend,
            snapshots: store,
            restarter: restarter,
            resolvePath: pathAsGiven,
            prefsWriter: useWriter ? writer : nil,
            appSwitcher: switcher ? rig.switcher : nil
        )
    }

    /// Slack is running and belongs to the previous profile, so switching to a profile without it quits it.
    func runSlack(_ behavior: FakeRunningApps.Behavior = .quitsImmediately) {
        rig.apps.add(info(10, slack, name: "Slack"), behavior: behavior)
        rig.apps.setOnTerminate { [log] app in log.add("quit \(app.name)") }
    }

    var previous: Profile { Profile(name: "Previous", apps: [.app(ref(slack))]) }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func prefValue(_ key: String) -> Any? { prefsIO.value(forKey: key) }
    var snapshots: [Snapshot] { get async { await store.list().snapshots } }
}

private func target(
    apps: [DockItem] = [calendarApp],
    prefs: DockPrefs? = nil,
    switching: SwitchingOptions = SwitchingOptions()
) -> Profile {
    Profile(name: "Work", apps: apps, prefs: prefs, switching: switching)
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1)))
struct ProfileApplierPrefsAndAppsTests {
    // MARK: Preview

    @Test func previewCarriesPrefsDiffAndSwitchPlan() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let preview = try await w.applier().preview(
            target(prefs: DockPrefs(tileSize: 64, autohide: false)),
            from: w.previous
        )
        #expect(preview.prefsDiff?.entries.map(\.key) == [.tileSize])
        #expect(preview.switchPlan?.willQuit.map(\.name) == ["Slack"])
        #expect(preview.confirmationRequired)
        #expect(!preview.hasDockChanges == false)
        #expect(await w.backend.appliedBatches.isEmpty)
        #expect(w.prefValue("tilesize") as? Double == 48)
        #expect(w.rig.apps.terminated.isEmpty)
    }

    @Test func nilPrefsLeaveThePreferencesUntouched() async throws {
        let w = try World()
        defer { w.cleanup() }
        let preview = try await w.applier().preview(target(apps: [calendarApp, calculator]))
        #expect(preview.prefsDiff == nil)
        #expect(preview.prefsBaseline == nil)
        let result = try await w.applier().apply(target(apps: [calendarApp, calculator]))
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(report.prefsChangedKeys.isEmpty)
        #expect(w.writer.captureCount == 0)
        #expect(w.writer.applyCount == 0)
        #expect(w.prefValue("tilesize") as? Double == 48)
        #expect(await w.restarter.count == 1)
    }

    @Test func profileWithPrefsButNoWriterIsRefused() async throws {
        let w = try World()
        defer { w.cleanup() }
        let applier = w.applier(writer: false)
        await #expect(throws: ApplyError.self) {
            _ = try await applier.apply(target(prefs: DockPrefs(autohide: true)))
        }
        #expect(await w.snapshots.isEmpty)
        #expect(await w.restarter.count == 0)
    }

    // MARK: Writing

    @Test func prefsOnlyChangeWritesPrefsAndRestartsOnce() async throws {
        let w = try World()
        defer { w.cleanup() }
        let result = try await w.applier().apply(target(prefs: DockPrefs(autohide: true)))
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(w.prefValue("autohide") as? Bool == true)
        #expect(report.prefsChangedKeys == [.autohide])
        #expect(report.plan.isEmpty)
        #expect(report.restarted)
        #expect(await w.backend.appliedBatches.isEmpty)
        #expect(await w.restarter.count == 1)
        // The snapshot carries the pre-image of the key it changed.
        let snapshot = try #require(await w.snapshots.first)
        #expect(snapshot.id == report.snapshotID)
        let expectedImage: [DockPrefs.Key: DockPrefs.Value?] = [.autohide: .bool(false)]
        #expect(snapshot.prefsImage?.rollbackImage.previousValues == expectedImage)
    }

    @Test func tilesAndPrefsShareOneRestart() async throws {
        let w = try World()
        defer { w.cleanup() }
        let result = try await w.applier().apply(
            target(apps: [calculator], prefs: DockPrefs(tileSize: 80, autohide: true))
        )
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(await w.backend.state.apps == [calculator])
        #expect(w.prefValue("tilesize") as? Double == 80)
        #expect(w.prefValue("autohide") as? Bool == true)
        #expect(report.prefsChangedKeys == [.autohide, .tileSize])
        #expect(await w.restarter.count == 1)
        let image = try #require(await w.snapshots.first?.prefsImage?.rollbackImage)
        let expectedImage: [DockPrefs.Key: DockPrefs.Value?] = [.tileSize: .double(48), .autohide: .bool(false)]
        #expect(image.previousValues == expectedImage)
    }

    @Test func tilesOnlyChangeRestartsOnceWithoutTouchingPrefs() async throws {
        let w = try World()
        defer { w.cleanup() }
        // Prefs already match the profile.
        _ = try await w.applier().apply(target(apps: [calculator], prefs: DockPrefs(tileSize: 48, autohide: false)))
        #expect(w.writer.applyCount == 0)
        #expect(await w.restarter.count == 1)
        #expect(await w.snapshots.first?.prefsImage == nil)
    }

    @Test func nothingChangedMeansNoSnapshotWriteOrRestart() async throws {
        let w = try World()
        defer { w.cleanup() }
        let result = try await w.applier().apply(target(prefs: DockPrefs(tileSize: 48, autohide: false)))
        guard case .noChanges = result else { Issue.record("expected noChanges, got \(result)"); return }
        #expect(await w.restarter.count == 0)
        #expect(await w.snapshots.isEmpty)
        #expect(w.writer.applyCount == 0)
    }

    @Test func prefsChangedAfterPreviewAreRefusedWithoutWriting() async throws {
        let w = try World()
        defer { w.cleanup() }
        let prefsIO = w.prefsIO
        let result = await Result {
            try await w.applier().apply(target(apps: [calculator], prefs: DockPrefs(autohide: true))) { _ in
                prefsIO.setValue(80.0, forKey: "tilesize") // someone edits during the confirmation
                return true
            }
        }
        guard case let .failure(error) = result, case ApplyError.dockChanged = error else {
            Issue.record("expected dockChanged, got \(result)")
            return
        }
        #expect(await w.backend.appliedBatches.isEmpty)
        #expect(w.prefValue("autohide") as? Bool == false)
        #expect(await w.restarter.count == 0)
        #expect(await w.snapshots.isEmpty)
    }

    // MARK: Failure and rollback

    @Test func prefsVerifyFailureRollsBackTilesAndPrefs() async throws {
        // The Dock ignores tilesize writes, so the writer's read-back fails after autohide was written.
        let stubborn = StubbornPrefsIO(initial: ["tilesize": 48.0, "autohide": false], ignoring: ["tilesize"])
        let w = try World(prefsIO: stubborn)
        defer { w.cleanup() }
        w.runSlack()
        let applier = w.applier()
        let result = await Result {
            try await applier.apply(
                target(apps: [calculator], prefs: DockPrefs(tileSize: 80, autohide: true)),
                from: w.previous
            ) { _ in true }
        }
        guard case let .failure(error) = result, case ApplyError.failedAndRolledBack = error else {
            Issue.record("expected failedAndRolledBack, got \(result)")
            return
        }
        #expect(await w.backend.state == w.current)
        #expect(w.prefValue("autohide") as? Bool == false)
        #expect(w.prefValue("tilesize") as? Double == 48)
        #expect(w.writer.rollbackCount == 1)
        // One restart for the rollback, none for the failed apply, and no app was quit.
        #expect(await w.restarter.count == 1)
        #expect(w.rig.apps.terminated.isEmpty)
    }

    @Test func dockRewritingPrefsAfterRestartRollsBackBoth() async throws {
        let prefsIO = InMemoryDockPrefsDomainIO(initial: ["tilesize": 48.0, "autohide": false])
        let w = try World(restartHook: { n in
            // The first restart is the apply's: the Dock comes back with another tile size.
            if n == 1 { prefsIO.setValue(30.0, forKey: "tilesize") }
        })
        // Use the same IO the hook mutates.
        let writer = CountingPrefsWriter(io: prefsIO)
        let applier = ProfileApplier(
            backend: w.backend, snapshots: w.store, restarter: w.restarter,
            resolvePath: pathAsGiven, prefsWriter: writer, appSwitcher: w.rig.switcher
        )
        defer { w.cleanup() }
        w.runSlack()
        let result = await Result {
            try await applier.apply(target(apps: [calculator], prefs: DockPrefs(tileSize: 80)), from: w.previous) { _ in true }
        }
        guard case let .failure(error) = result, case ApplyError.failedAndRolledBack = error else {
            Issue.record("expected failedAndRolledBack, got \(result)")
            return
        }
        #expect(await w.backend.state == w.current)
        #expect(prefsIO.value(forKey: "tilesize") as? Double == 48)
        #expect(await w.restarter.count == 2)
        #expect(w.rig.apps.terminated.isEmpty)
    }

    @Test func tileWriteFailureQuitsNoApps() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        await w.backend.failNextApply(with: Boom())
        let applier = w.applier()
        let result = await Result {
            try await applier.apply(target(apps: [calculator]), from: w.previous) { _ in true }
        }
        guard case let .failure(error) = result, case ApplyError.failedAndRolledBack = error else {
            Issue.record("expected failedAndRolledBack, got \(result)")
            return
        }
        #expect(w.rig.apps.terminated.isEmpty)
        #expect(w.rig.apps.runningApps().map(\.name) == ["Slack"])
    }

    // MARK: Apps

    @Test func appsAreQuitOnlyAfterTheDockChangeIsVerified() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let prefsIO = w.prefsIO
        let log = w.log
        w.rig.apps.setOnTerminate { app in
            // By the time anything is asked to quit, both the prefs and the restart are done.
            log.add("quit \(app.name) autohide=\(prefsIO.value(forKey: "autohide") as? Bool ?? false)")
        }
        let result = try await w.applier().apply(
            target(apps: [calculator], prefs: DockPrefs(autohide: true)),
            from: w.previous
        ) { _ in true }
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(w.log.entries == ["restart", "quit Slack autohide=true"])
        #expect(report.switchOutcome?.quitCount == 1)
        #expect(w.rig.apps.runningApps().isEmpty)
    }

    @Test func reportListsStragglersAndNothingIsForceQuit() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack(.ignores)
        let result = try await w.applier().apply(target(apps: [calculator]), from: w.previous) { _ in true }
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(report.switchOutcome?.stragglers.map(\.name) == ["Slack"])
        #expect(w.rig.apps.forceTerminated.isEmpty)
        #expect(await w.backend.state.apps == [calculator])
    }

    @Test func launchesRunAfterTheDockChange() async throws {
        let w = try World()
        defer { w.cleanup() }
        let figmaTile = DockItem.app(AppRef(bundleId: figma, name: "Figma", path: "/Applications/Figma.app", launchOnSwitch: true))
        let result = try await w.applier().apply(target(apps: [figmaTile]))
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(w.rig.launcher.launched.map(\.bundleId) == [figma])
        #expect(report.switchOutcome?.launches.map(\.status) == [.launched])
    }

    @Test func quittingNeedsConfirmationWithoutAConfirmClosure() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let applier = w.applier()
        let result = await Result { try await applier.apply(target(apps: [calculator]), from: w.previous) }
        guard case let .failure(error) = result, case let ApplyError.quitConfirmationRequired(apps) = error else {
            Issue.record("expected quitConfirmationRequired, got \(result)")
            return
        }
        #expect(apps.map(\.name) == ["Slack"])
        #expect(await w.backend.appliedBatches.isEmpty)
        #expect(await w.snapshots.isEmpty)
        #expect(w.rig.apps.terminated.isEmpty)
    }

    @Test func confirmationSeesTheQuitPlanAndDecliningQuitsNothing() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let seen = Log()
        let result = try await w.applier().apply(target(apps: [calculator]), from: w.previous) { preview in
            seen.add(preview.willQuitApps.map(\.name).joined(separator: ","))
            return false
        }
        #expect(result == .cancelled(rolledBack: false))
        #expect(seen.entries == ["Slack"])
        #expect(w.rig.apps.terminated.isEmpty)
        #expect(await w.backend.appliedBatches.isEmpty)
    }

    @Test func automaticTriggerCannotQuitWithoutOptInOrConfirmation() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let applier = w.applier()
        let result = await Result {
            try await applier.apply(target(apps: [calculator]), from: w.previous, trigger: .automatic)
        }
        guard case let .failure(error) = result, case ApplyError.quitConfirmationRequired = error else {
            Issue.record("expected quitConfirmationRequired, got \(result)")
            return
        }
        #expect(w.rig.apps.terminated.isEmpty)
    }

    @Test func optInLetsAnAutomaticTriggerQuitButAUserTriggerStillNeedsConfirmation() async throws {
        let optedIn = SwitchingOptions(quitOnAutomaticSwitch: true)

        let user = try World()
        defer { user.cleanup() }
        user.runSlack()
        let userApplier = user.applier()
        let userResult = await Result {
            try await userApplier.apply(target(apps: [calculator], switching: optedIn), from: user.previous, trigger: .user)
        }
        guard case let .failure(error) = userResult, case ApplyError.quitConfirmationRequired = error else {
            Issue.record("expected quitConfirmationRequired, got \(userResult)")
            return
        }

        let auto = try World()
        defer { auto.cleanup() }
        auto.runSlack()
        let result = try await auto.applier().apply(
            target(apps: [calculator], switching: optedIn), from: auto.previous, trigger: .automatic
        )
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        #expect(report.switchOutcome?.quitCount == 1)
    }

    @Test func appsOnlySwitchTakesNoSnapshotAndNoRestart() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        let result = try await w.applier().apply(target(prefs: DockPrefs(tileSize: 48)), from: w.previous) { _ in true }
        guard case let .appsOnly(outcome) = result else { Issue.record("expected appsOnly, got \(result)"); return }
        #expect(outcome.quitCount == 1)
        #expect(await w.restarter.count == 0)
        #expect(await w.snapshots.isEmpty)
    }

    // MARK: Cancellation between phases

    @Test func cancellationDuringTheAppPhaseKeepsTheDockChange() async throws {
        let w = try World()
        defer { w.cleanup() }
        w.runSlack()
        w.rig.apps.add(info(11, "com.example.figma", name: "Figma"))
        let previous = Profile(name: "Previous", apps: [.app(ref(slack)), .app(ref(figma))])
        let applier = w.applier()
        let box = TaskBox()
        let task = Task {
            try await applier.apply(target(apps: [calculator], prefs: DockPrefs(autohide: true)), from: previous) { _ in true }
        }
        await box.set(task)
        w.rig.apps.setOnTerminate { _ in
            // The user supersedes the switch while the first app is being quit.
            Task { await box.cancel() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let result = try await task.value
        guard case let .applied(report) = result else { Issue.record("expected applied, got \(result)"); return }
        let outcome = try #require(report.switchOutcome)
        #expect(outcome.wasCancelled)
        #expect(outcome.quits.last?.status == .skippedCancelled)
        // The Dock change is committed, not rolled back because apps were (partly) quit.
        #expect(await w.backend.state.apps == [calculator])
        #expect(w.prefValue("autohide") as? Bool == true)
        #expect(await w.restarter.count == 1)
    }

    @Test func cancellationBeforeTheAppPhaseRollsBackAndQuitsNothing() async throws {
        let box = TaskBox()
        let w = try World(restartHook: { _ in await box.cancel() })
        defer { w.cleanup() }
        w.runSlack()
        let applier = w.applier()
        let task = Task {
            try await applier.apply(target(apps: [calculator], prefs: DockPrefs(autohide: true)), from: w.previous) { _ in true }
        }
        await box.set(task)
        let result = try await task.value
        #expect(result == .cancelled(rolledBack: true))
        #expect(w.rig.apps.terminated.isEmpty)
        #expect(await w.backend.state == w.current)
        #expect(w.prefValue("autohide") as? Bool == false)
    }

    // MARK: Snapshots

    @Test func snapshotWithoutPrefsStillRestores() async throws {
        let w = try World()
        defer { w.cleanup() }
        let snapshot = try await w.store.save(reason: "legacy")
        #expect(snapshot.prefsImage == nil)
        // On disk a snapshot without a pre-image has no such key, exactly like one from before this field.
        let json = try String(contentsOf: w.root.appendingPathComponent("snapshots/\(snapshot.id.uuidString).json"), encoding: .utf8)
        #expect(!json.contains("prefsImage"))
        w.prefsIO.setValue(true, forKey: "autohide")
        try await w.store.restore(id: snapshot.id, prefsWriter: w.writer)
        #expect(w.writer.rollbackCount == 0)
        #expect(w.prefValue("autohide") as? Bool == true) // untouched: nothing was recorded
    }

    @Test func restoreWritesTheRecordedPrefsBack() async throws {
        let w = try World()
        defer { w.cleanup() }
        let values: [DockPrefs.Key: DockPrefs.Value?] = [.tileSize: .double(48), .autohide: nil]
        let image = DockPrefsRollbackImage(previousValues: values)
        let snapshot = try await w.store.save(reason: "Before applying profile Work", prefsPreImage: image)
        w.prefsIO.setValue(90.0, forKey: "tilesize")
        w.prefsIO.setValue(true, forKey: "autohide")
        try await w.store.restore(id: snapshot.id, prefsWriter: w.writer)
        #expect(w.prefValue("tilesize") as? Double == 48)
        #expect(w.prefValue("autohide") == nil)
    }

    @Test func restoreWithoutAWriterIgnoresTheRecordedPrefs() async throws {
        let w = try World()
        defer { w.cleanup() }
        let values: [DockPrefs.Key: DockPrefs.Value?] = [.tileSize: .double(48)]
        let image = DockPrefsRollbackImage(previousValues: values)
        let snapshot = try await w.store.save(reason: "x", prefsPreImage: image)
        w.prefsIO.setValue(90.0, forKey: "tilesize")
        try await w.store.restore(id: snapshot.id)
        #expect(w.prefValue("tilesize") as? Double == 90)
    }

    // MARK: Options

    @Test func quitOptInIsWrittenOnlyWhenOnAndClearedOnImport() throws {
        let off = String(decoding: try Profile(name: "A").jsonData(), as: UTF8.self)
        #expect(!off.contains("quitOnAutomaticSwitch"))

        var on = Profile(name: "B")
        on.switching.quitOnAutomaticSwitch = true
        let data = try on.jsonData()
        #expect(String(decoding: data, as: UTF8.self).contains("\"quitOnAutomaticSwitch\" : true"))
        #expect(try Profile(jsonData: data).switching.quitOnAutomaticSwitch)

        let sanitized = try on.sanitizedForImport()
        #expect(!sanitized.profile.switching.quitOnAutomaticSwitch)
        #expect(sanitized.changes.contains(.clearedQuitOnAutomaticSwitch))
    }
}

private actor TaskBox {
    private var task: Task<ApplyResult, any Error>?
    func set(_ task: Task<ApplyResult, any Error>) { self.task = task }
    func cancel() { task?.cancel() }
}
