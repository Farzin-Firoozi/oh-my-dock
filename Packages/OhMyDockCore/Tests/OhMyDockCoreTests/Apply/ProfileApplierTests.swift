import Foundation
import Testing
@testable import OhMyDockCore

// MARK: - Fakes

private struct RestartFailure: Error, Equatable {}
private struct ImportFailure: Error, Equatable {}

/// Stands in for the `com.apple.dock` domain: export hands out `data`, import records what it got.
private actor FakeDomainIO: DockDomainIO {
    private(set) var data: Data
    private(set) var imports: [Data] = []
    private var failImports = false

    init(data: Data) {
        self.data = data
    }

    func exportDomain(to url: URL) async throws {
        try data.write(to: url)
    }

    func importDomain(from url: URL) async throws {
        if failImports { throw ImportFailure() }
        let imported = try Data(contentsOf: url)
        imports.append(imported)
        data = imported
    }

    func failImports(_ fail: Bool) {
        failImports = fail
    }
}

/// Counts restarts; the calls whose 1-based numbers are in `failing` throw.
private actor CountingRestarter: DockRestarting {
    private(set) var count = 0
    private let failing: Set<Int>

    init(failing: Set<Int> = []) {
        self.failing = failing
    }

    func restart() async throws {
        count += 1
        if failing.contains(count) { throw RestartFailure() }
    }
}

/// Wraps a backend and runs a hook right after its Nth `read` returns (1-based), to simulate an
/// edit that lands between the read and whatever the caller does next.
private actor ReadHook: DockBackend {
    let inner: FakeDockBackend
    private var reads = 0
    private var hooks: [Int: @Sendable () async -> Void] = [:]

    init(inner: FakeDockBackend) {
        self.inner = inner
    }

    func onRead(_ number: Int, _ hook: @escaping @Sendable () async -> Void) {
        hooks[number] = hook
    }

    func read() async throws -> DockState {
        reads += 1
        let state = try await inner.read()
        if let hook = hooks[reads] { await hook() }
        return state
    }

    func apply(_ operations: [DockOperation]) async throws {
        try await inner.apply(operations)
    }
}

/// A backend that reports every batch as clearing the recent apps, as dockutil does when it has
/// to rewrite the whole Dock for an incremental plan.
private struct RewritingBackend: DockBackend {
    let inner: FakeDockBackend

    init(_ inner: FakeDockBackend) {
        self.inner = inner
    }

    func read() async throws -> DockState { try await inner.read() }
    func apply(_ operations: [DockOperation]) async throws { try await inner.apply(operations) }
    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight {
        DockWritePreflight(clearsRecentApps: true)
    }
}

/// A backend whose preflight refuses every batch, like dockutil's planner on a plan it cannot express.
private struct RefusingBackend: DockBackend {
    let inner: FakeDockBackend
    let refusal: DockBackendError

    init(_ inner: FakeDockBackend, refusal: DockBackendError) {
        self.inner = inner
        self.refusal = refusal
    }

    func read() async throws -> DockState { try await inner.read() }
    func apply(_ operations: [DockOperation]) async throws { try await inner.apply(operations) }
    func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight { throw refusal }
}

/// One-shot latch: `wait()` returns once `open()` has been called (before or after).
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Wraps a backend. The first `apply` goes through, signals `entered`, and then blocks until its
/// task is cancelled (or a safety deadline passes), like a long dockutil batch.
private actor SlowBackend: DockBackend {
    let inner: FakeDockBackend
    let entered = Gate()
    private var slowCallsLeft = 1

    init(_ inner: FakeDockBackend) {
        self.inner = inner
    }

    func read() async throws -> DockState {
        try await inner.read()
    }

    func apply(_ operations: [DockOperation]) async throws {
        try await inner.apply(operations)
        guard slowCallsLeft > 0 else { return }
        slowCallsLeft -= 1
        await entered.open()
        let deadline = ContinuousClock.now + .seconds(10)
        while !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Environment

private let calculator = Sample.calculator
private let calendarApp = Sample.calendar
private let notes = Sample.notes

private func dockPlistData() throws -> Data {
    let domain: [String: Any] = ["persistent-apps": [Any](), "persistent-others": [Any]()]
    return try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
}

private func profile(_ name: String = "Work", apps: [DockItem] = [], others: [DockItem] = []) -> Profile {
    Profile(name: name, apps: apps, others: others)
}

private let pathAsGiven: ProfileApplier.AppPathResolver = { $0.path }

private struct Env {
    let root: URL
    let io: FakeDomainIO
    let store: SnapshotStore
    let backend: FakeDockBackend
    let restarter: CountingRestarter

    init(current: DockState = DockState(), failingRestarts: Set<Int> = []) throws {
        root = try makeTempDirectory("omd-applier")
        io = FakeDomainIO(data: try dockPlistData())
        store = SnapshotStore(rootDirectory: root.appendingPathComponent("snapshots"), domainIO: io)
        backend = FakeDockBackend(state: current)
        restarter = CountingRestarter(failing: failingRestarts)
    }

    func applier(
        backend override: (any DockBackend)? = nil,
        resolvePath: @escaping ProfileApplier.AppPathResolver = pathAsGiven
    ) -> ProfileApplier {
        ProfileApplier(
            backend: override ?? backend,
            snapshots: store,
            restarter: restarter,
            resolvePath: resolvePath
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    var snapshots: [Snapshot] {
        get async { await store.list().snapshots }
    }
}

/// The thrown `ApplyError`, or nil when `body` returned. Fails the test on any other error.
private func applyError(_ body: () async throws -> ApplyResult) async -> ApplyError? {
    do {
        _ = try await body()
        return nil
    } catch let error as ApplyError {
        return error
    } catch {
        Issue.record("Expected an ApplyError, got \(error)")
        return nil
    }
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1)))
struct ProfileApplierTests {
    // MARK: Happy path

    @Test func appliesSnapshotsAndRestartsOnce() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let target = DockState(apps: [calculator, notes], others: [Sample.example])

        let result = try await env.applier().apply(profile(apps: target.apps, others: target.others))

        guard case let .applied(report) = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(await env.backend.state == target)
        #expect(await env.backend.appliedBatches.count == 1)
        #expect(await env.restarter.count == 1)
        #expect(report.restarted)
        #expect(!report.clearsRecentApps)
        #expect(report.skipped.isEmpty)
        #expect(!report.plan.isEmpty)

        let snapshots = await env.snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.id == report.snapshotID)
        #expect(snapshots.first?.reason == "Before applying profile Work")
        #expect(snapshots.first?.profileName == "Work")
        #expect(await env.io.imports.isEmpty)
    }

    @Test func appliesFullRewriteAndReportsRecentAppsCleared() async throws {
        let env = try Env(current: DockState(apps: [calculator, .spacer(.normal), notes]))
        defer { env.cleanup() }
        let applier = env.applier()
        let wanted = profile(apps: [calculator, notes])

        let preview = try await applier.preview(wanted)
        #expect(preview.plan.requiresFullRewrite)
        #expect(preview.clearsRecentApps)

        let result = try await applier.apply(wanted)
        guard case let .applied(report) = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(report.clearsRecentApps)
        #expect(await env.backend.state == DockState(apps: [calculator, notes]))
    }

    @Test func previewWarnsWhenTheBackendTurnsAnIncrementalPlanIntoARewrite() async throws {
        let env = try Env(current: DockState(apps: [calculator, notes]))
        defer { env.cleanup() }
        let rewriting = RewritingBackend(env.backend)
        let applier = env.applier(backend: rewriting)
        let wanted = profile(apps: [calculator])

        let preview = try await applier.preview(wanted)
        #expect(!preview.plan.requiresFullRewrite)
        #expect(preview.clearsRecentApps)

        let result = try await applier.apply(wanted)
        guard case let .applied(report) = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(report.clearsRecentApps)
    }

    // MARK: Preview

    @Test func previewWritesNothing() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }

        let preview = try await env.applier().preview(profile(apps: [calculator]))

        #expect(preview.current == DockState(apps: [calendarApp]))
        #expect(preview.target == DockState(apps: [calculator]))
        #expect(!preview.plan.isEmpty)
        #expect(!preview.clearsRecentApps)
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func previewReportsUnsatisfiablePlanWithoutThrowing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let issue = DockPlanIssue.unknownTileNotInsertable(section: .apps, index: 0)
        let applier = ProfileApplier(
            backend: env.backend,
            snapshots: env.store,
            restarter: env.restarter,
            resolvePath: pathAsGiven,
            planner: { _, _ in DockPlan(operations: [], issues: [issue], summary: "") }
        )

        let preview = try await applier.preview(profile(apps: [calculator]))

        #expect(preview.plan.issues == [issue])
    }

    // MARK: No changes

    @Test func identicalDockIsNoChangesWithoutSnapshotOrRestart() async throws {
        let current = DockState(apps: [calculator, .spacer(.small)], others: [Sample.example])
        let env = try Env(current: current)
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: current.apps, others: current.others))

        guard case let .noChanges(preview) = result else {
            Issue.record("Expected .noChanges, got \(result)")
            return
        }
        #expect(preview.plan.isEmpty)
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func fieldsTheDockCannotStoreDoNotCountAsChanges() async throws {
        // As read back from the Dock: no brew cask, launch flag or profile name.
        let current = DockState(apps: [calculator], others: [.url(URLItem(url: URL(string: "https://example.com")!, label: "Example"))])
        let env = try Env(current: current)
        defer { env.cleanup() }
        let profileApp = DockItem.app(AppRef(
            bundleId: "com.apple.calculator",
            name: "Calc",
            path: "/System/Applications/Calculator.app",
            brewCask: "calc",
            launchOnSwitch: true
        ))
        let profileURL = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: nil))

        let result = try await env.applier().apply(profile(apps: [profileApp], others: [profileURL]))

        guard case .noChanges = result else {
            Issue.record("Expected .noChanges, got \(result)")
            return
        }
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
    }

    // MARK: Refusals

    @Test func invalidProfileIsRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }

        let error = await applyError { try await env.applier().apply(profile("  ", apps: [calculator])) }

        guard case .invalidProfile(.emptyName)? = error else {
            Issue.record("Expected invalidProfile(.emptyName), got \(String(describing: error))")
            return
        }
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
    }

    @Test func unsatisfiablePlanThrowsWithoutWritingOrSnapshot() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let issues = [
            DockPlanIssue.unknownTileNotInsertable(section: .apps, index: 0),
            .fullRewriteCannotCarryUnknown(section: .others, index: 2),
        ]
        let applier = ProfileApplier(
            backend: env.backend,
            snapshots: env.store,
            restarter: env.restarter,
            resolvePath: pathAsGiven,
            planner: { _, _ in DockPlan(operations: [], issues: issues, summary: "Cannot apply") }
        )

        let error = await applyError { try await applier.apply(profile(apps: [calculator])) }

        guard case let .unsatisfiable(thrown)? = error else {
            Issue.record("Expected unsatisfiable, got \(String(describing: error))")
            return
        }
        #expect(thrown == issues)
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func backendRefusingBeforeWritingDoesNotRestoreOrRestart() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let refusal = DockBackendError.invalidOperation("dockutil cannot add this")
        let applier = env.applier(backend: RefusingBackend(env.backend, refusal: refusal))

        let error = await applyError { try await applier.apply(profile(apps: [calculator])) }

        guard case let .rejectedByBackend(original)? = error else {
            Issue.record("Expected rejectedByBackend, got \(String(describing: error))")
            return
        }
        #expect(original as? DockBackendError == refusal)
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.io.imports.isEmpty)
        #expect(await env.restarter.count == 0)

        let previewError = await applyError { _ = try await applier.preview(profile(apps: [calculator])); return .cancelled(rolledBack: false) }
        guard case .rejectedByBackend? = previewError else {
            Issue.record("Expected preview to throw rejectedByBackend, got \(String(describing: previewError))")
            return
        }
    }

    // MARK: Unknown tiles

    private let mystery = DockItem.unknown(UnknownTile(tileType: "mystery-tile", label: "Mystery"))

    @Test func unknownTilesStayInPlaceWhileTheRestIsApplied() async throws {
        let env = try Env(current: DockState(apps: [calendarApp, mystery, calculator]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [mystery, calculator, notes]))

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(await env.backend.state == DockState(apps: [mystery, calculator, notes]))
        // The unknown tile is never re-inserted.
        let operations = await env.backend.appliedBatches.flatMap { $0 }
        #expect(!operations.contains(.insert(mystery, section: .apps, index: 0)))
    }

    @Test func unknownTileAlreadyInPlaceIsNoChange() async throws {
        let env = try Env(current: DockState(apps: [calculator], others: [mystery]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [calculator], others: [mystery]))

        guard case .noChanges = result else {
            Issue.record("Expected .noChanges, got \(result)")
            return
        }
    }

    @Test func unknownTileTheDockLacksCannotBeCreated() async throws {
        let env = try Env(current: DockState(apps: [calculator]))
        defer { env.cleanup() }

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator, mystery])) }

        guard case let .unsatisfiable(issues)? = error else {
            Issue.record("Expected unsatisfiable, got \(String(describing: error))")
            return
        }
        #expect(issues == [.unknownTileNotInsertable(section: .apps, index: 1)])
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
    }

    // MARK: Confirm

    @Test func declinedConfirmationCancelsWithoutWriting() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let seen = PreviewBox()

        let result = try await env.applier().apply(profile(apps: [calculator])) { preview in
            await seen.set(preview)
            return false
        }

        #expect(result == .cancelled(rolledBack: false))
        #expect(await seen.value?.target == DockState(apps: [calculator]))
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func acceptedConfirmationApplies() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [calculator])) { _ in true }

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(await env.backend.state == DockState(apps: [calculator]))
    }

    @Test func confirmationIsNotAskedWhenThereIsNothingToDo() async throws {
        let env = try Env(current: DockState(apps: [calculator]))
        defer { env.cleanup() }
        let asked = Counter()

        let result = try await env.applier().apply(profile(apps: [calculator])) { _ in
            await asked.increment()
            return true
        }

        guard case .noChanges = result else {
            Issue.record("Expected .noChanges, got \(result)")
            return
        }
        #expect(await asked.value == 0)
    }

    @Test func confirmationThatIgnoresCancellationDoesNotBlockTheNextApply() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let applier = env.applier()
        let dialogOpen = Gate()
        let userNeverAnswers = Gate()
        let targetB = DockState(apps: [notes])

        // A dialog that is left open and does not react to cancellation.
        let first = Task {
            try await applier.apply(profile("A", apps: [calculator])) { _ in
                await dialogOpen.open()
                await userNeverAnswers.wait()
                return true
            }
        }
        await dialogOpen.wait()
        let second = Task { try await applier.apply(profile("B", apps: targetB.apps)) }

        #expect(try await first.value == .cancelled(rolledBack: false))
        guard case .applied = try await second.value else {
            Issue.record("Expected the second apply to be applied")
            return
        }
        #expect(await env.backend.state == targetB)
        #expect(await env.backend.appliedBatches.count == 1)

        // The abandoned dialog answering later changes nothing.
        await userNeverAnswers.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await env.backend.appliedBatches.count == 1)
        #expect(await env.snapshots.count == 1)
    }

    @Test func cancellingTheCallerReturnsWhileTheDialogIsStillOpen() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let applier = env.applier()
        let dialogOpen = Gate()
        let userNeverAnswers = Gate()

        let task = Task {
            try await applier.apply(profile(apps: [calculator])) { _ in
                await dialogOpen.open()
                await userNeverAnswers.wait()
                return true
            }
        }
        await dialogOpen.wait()
        task.cancel()

        #expect(try await task.value == .cancelled(rolledBack: false))
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        await userNeverAnswers.open()
    }

    // MARK: Skipped apps

    @Test func unresolvedAppsAreSkippedAndReported() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")
        let resolver: ProfileApplier.AppPathResolver = { $0.bundleId == missing.bundleId ? nil : $0.path }
        let applier = env.applier(resolvePath: resolver)
        let wanted = profile(apps: [calculator, .app(missing), notes], others: [Sample.example])

        let preview = try await applier.preview(wanted)
        #expect(preview.skipped == [SkippedItem(section: .apps, index: 1, app: missing)])
        #expect(preview.target == DockState(apps: [calculator, notes], others: [Sample.example]))

        let result = try await applier.apply(wanted) { _ in true }
        guard case let .applied(report) = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(report.skipped == preview.skipped)
        #expect(await env.backend.state == DockState(apps: [calculator, notes], others: [Sample.example]))
    }

    @Test func appResolvedToANewPathReplacesTheStaleTileInTheDock() async throws {
        let stale = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: "/Users/me/Old/One.app"))
        let env = try Env(current: DockState(apps: [stale]))
        defer { env.cleanup() }
        let wanted = DockItem.app(AppRef(bundleId: "com.x.one", name: "One"))
        let resolver: ProfileApplier.AppPathResolver = { _ in "/Applications/One.app" }

        let result = try await env.applier(resolvePath: resolver).apply(profile(apps: [wanted]))

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        let expected = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: "/Applications/One.app"))
        #expect(await env.backend.state == DockState(apps: [expected]))
    }

    @Test func resolvedPathReplacesTheHintInTheTarget() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let hinted = AppRef(bundleId: "com.apple.calculator", name: "Calculator", path: "/old/Calculator.app")
        let resolver: ProfileApplier.AppPathResolver = { _ in "/System/Applications/Calculator.app" }

        let preview = try await env.applier(resolvePath: resolver).preview(profile(apps: [.app(hinted)]))

        var resolved = hinted
        resolved.path = "/System/Applications/Calculator.app"
        #expect(preview.target.apps == [.app(resolved)])
    }

    @Test func skippingAppsRequiresAConfirmation() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")
        let resolver: ProfileApplier.AppPathResolver = { $0.bundleId == missing.bundleId ? nil : $0.path }
        let applier = env.applier(resolvePath: resolver)
        let wanted = profile(apps: [calculator, .app(missing)])

        let error = await applyError { try await applier.apply(wanted) }

        guard case let .confirmationRequired(skipped)? = error else {
            Issue.record("Expected confirmationRequired, got \(String(describing: error))")
            return
        }
        #expect(skipped == [SkippedItem(section: .apps, index: 1, app: missing)])
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func declinedConfirmationLeavesSkippedAppsUnapplied() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")
        let resolver: ProfileApplier.AppPathResolver = { $0.bundleId == missing.bundleId ? nil : $0.path }
        let seen = PreviewBox()

        let result = try await env.applier(resolvePath: resolver)
            .apply(profile(apps: [calculator, .app(missing)])) { preview in
                await seen.set(preview)
                return false
            }

        #expect(result == .cancelled(rolledBack: false))
        #expect(await seen.value?.skipped.count == 1)
        #expect(await env.backend.appliedBatches.isEmpty)
    }

    @Test func noConfirmationIsNeededWhenNothingIsSkipped() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [calculator]))

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
    }

    @Test func ifEveryAppIsMissingTheSectionIsNeverEmptied() async throws {
        let env = try Env(current: DockState(apps: [calculator], others: [Sample.example]))
        defer { env.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")
        let applier = env.applier(resolvePath: { _ in nil })
        let wanted = profile(apps: [.app(missing)], others: [Sample.example])

        let preview = try await applier.preview(wanted)
        #expect(preview.emptiedSections == [.apps])

        // Not even a confirmation unlocks it.
        let error = await applyError { try await applier.apply(wanted) { _ in true } }

        guard case let .wouldEmptySection(section, skipped)? = error else {
            Issue.record("Expected wouldEmptySection, got \(String(describing: error))")
            return
        }
        #expect(section == .apps)
        #expect(skipped.map(\.app) == [missing])
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.backend.state == DockState(apps: [calculator], others: [Sample.example]))
    }

    @Test func aSectionTheProfileLeavesEmptyOnPurposeStillClears() async throws {
        let env = try Env(current: DockState(apps: [calculator], others: [Sample.example]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [calculator]))

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(await env.backend.state == DockState(apps: [calculator]))
    }

    @Test func missingAppsInAnAlreadyEmptySectionAreJustSkipped() async throws {
        let env = try Env(current: DockState())
        defer { env.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")

        let result = try await env.applier(resolvePath: { _ in nil })
            .apply(profile(apps: [.app(missing)], others: [Sample.example])) { _ in true }

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(await env.backend.state == DockState(others: [Sample.example]))
    }

    // MARK: Path resolution

    @Test func pathHintIsUsedOnlyForTheAppItBelongsTo() throws {
        let root = try makeTempDirectory("omd-resolve")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Fig.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let path = bundle.path(percentEncoded: false)

        func resolve(_ app: AppRef, installed: @escaping (String) -> URL? = { _ in nil }, id: String?) -> String? {
            ProfileApplier.resolvePath(app, installedURL: installed, bundleIdentifier: { _ in id })
        }

        let app = AppRef(bundleId: "com.example.fig", name: "Fig", path: path)
        #expect(resolve(app, id: "com.example.fig") == path)
        // Something else lives at the old path.
        #expect(resolve(app, id: "com.example.other") == nil)
        #expect(resolve(app, id: nil) == nil)
        // No bundle identifier to check against: the existing path is all there is.
        #expect(resolve(AppRef(bundleId: "", name: "Fig", path: path), id: "com.example.other") == path)
        // A missing path is no path.
        #expect(resolve(AppRef(bundleId: "com.example.fig", name: "Fig", path: path + "x"), id: "com.example.fig") == nil)
        #expect(resolve(AppRef(bundleId: "com.example.fig", name: "Fig"), id: "com.example.fig") == nil)
        // The installed app wins over the hint.
        let installed = URL(fileURLWithPath: "/Applications/Fig.app")
        #expect(resolve(app, installed: { _ in installed }, id: "com.example.other") == "/Applications/Fig.app")
    }

    // MARK: Rollback

    @Test func backendFailureRollsBackAndRestartsOnce() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        await env.backend.failNextApply(with: DockBackendError.commandFailed("boom"))

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator])) }

        guard case let .failedAndRolledBack(original)? = error else {
            Issue.record("Expected failedAndRolledBack, got \(String(describing: error))")
            return
        }
        #expect(original as? DockBackendError == .commandFailed("boom"))
        try await expectRestoredFromTheOnlySnapshot(env)
        #expect(await env.restarter.count == 1)
    }

    @Test func verificationFailureRollsBack() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        await env.backend.corruptNextWrite()

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator])) }

        guard case let .failedAndRolledBack(original)? = error else {
            Issue.record("Expected failedAndRolledBack, got \(String(describing: error))")
            return
        }
        guard case .verificationFailed? = original as? DockBackendError else {
            Issue.record("Expected verificationFailed, got \(original)")
            return
        }
        try await expectRestoredFromTheOnlySnapshot(env)
        #expect(await env.restarter.count == 1)
    }

    @Test func restartFailureAfterWritingRollsBack() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]), failingRestarts: [1])
        defer { env.cleanup() }

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator])) }

        guard case let .failedAndRolledBack(original)? = error else {
            Issue.record("Expected failedAndRolledBack, got \(String(describing: error))")
            return
        }
        #expect(original as? RestartFailure == RestartFailure())
        try await expectRestoredFromTheOnlySnapshot(env)
        // The failed restart plus the one after the rollback.
        #expect(await env.restarter.count == 2)
    }

    @Test func failedRestoreReportsTheSnapshotAndDoesNotRestart() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        await env.backend.failNextApply(with: DockBackendError.commandFailed("boom"))
        await env.io.failImports(true)

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator])) }

        guard case let .rollbackFailed(original, rollback, snapshotID)? = error else {
            Issue.record("Expected rollbackFailed, got \(String(describing: error))")
            return
        }
        #expect(original as? DockBackendError == .commandFailed("boom"))
        #expect(rollback as? ImportFailure == ImportFailure())
        #expect(await env.snapshots.map(\.id) == [snapshotID])
        #expect(await env.restarter.count == 0)
    }

    @Test func failedRestartDuringRollbackReportsTheSnapshot() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]), failingRestarts: [1])
        defer { env.cleanup() }
        await env.backend.failNextApply(with: DockBackendError.commandFailed("boom"))

        let error = await applyError { try await env.applier().apply(profile(apps: [calculator])) }

        guard case let .rollbackFailed(original, rollback, snapshotID)? = error else {
            Issue.record("Expected rollbackFailed, got \(String(describing: error))")
            return
        }
        #expect(original as? DockBackendError == .commandFailed("boom"))
        #expect(rollback as? RestartFailure == RestartFailure())
        #expect(await env.snapshots.map(\.id) == [snapshotID])
        #expect(await env.io.imports.count == 1)
    }

    @Test func rollbackFailureMessageNamesTheSnapshot() {
        let id = UUID()
        let error = ApplyError.rollbackFailed(original: RestartFailure(), rollback: ImportFailure(), snapshotID: id)
        #expect(error.localizedDescription.contains(id.uuidString))
    }

    // MARK: Dock changed meanwhile

    @Test func dockChangedWhileConfirmingIsRefused() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let backend = env.backend
        let target = DockState(apps: [calculator, notes])

        let error = await applyError {
            try await env.applier().apply(profile(apps: target.apps)) { _ in
                // Someone edits the Dock while the sheet is open.
                try? await backend.apply([.insert(notes, section: .apps, index: 1)])
                return true
            }
        }

        guard case .dockChanged? = error else {
            Issue.record("Expected dockChanged, got \(String(describing: error))")
            return
        }
        // Only the concurrent edit was written; the stale plan never ran.
        #expect(await env.backend.appliedBatches.count == 1)
        #expect(await env.backend.state == DockState(apps: [calendarApp, notes]))
        #expect(await env.restarter.count == 0)
        #expect(await env.io.imports.isEmpty)
    }

    @Test func dockChangedToTheTargetWhileConfirmingIsAlsoRefused() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let backend = env.backend

        let error = await applyError {
            try await env.applier().apply(profile(apps: [calculator])) { _ in
                try? await backend.apply([.remove(section: .apps, index: 0), .insert(calculator, section: .apps, index: 0)])
                return true
            }
        }

        guard case .dockChanged? = error else {
            Issue.record("Expected dockChanged, got \(String(describing: error))")
            return
        }
        #expect(await env.backend.appliedBatches.count == 1)   // only the concurrent edit
        #expect(await env.restarter.count == 0)
    }

    @Test func dockChangedAfterTheSnapshotIsRefusedWithoutWriting() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let backend = env.backend
        let reads = ReadHook(inner: backend)
        // Reads: plan, early check, late check. An edit after the early check lands before the late one.
        await reads.onRead(2) { try? await backend.apply([.insert(notes, section: .apps, index: 1)]) }

        let error = await applyError {
            try await env.applier(backend: reads).apply(profile(apps: [calculator]))
        }

        guard case .dockChanged? = error else {
            Issue.record("Expected dockChanged, got \(String(describing: error))")
            return
        }
        #expect(await env.backend.appliedBatches.count == 1)   // only the concurrent edit
        #expect(await env.restarter.count == 0)
        #expect(await env.io.imports.isEmpty)
        // The backup of a Dock that was never written is not kept.
        #expect(await env.snapshots.isEmpty)
    }

    @Test func cancellationAfterTheSnapshotDiscardsItAndWritesNothing() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let reads = ReadHook(inner: env.backend)
        let applier = env.applier(backend: reads)
        let handle = TaskBox()
        // Reads: plan, early check, late check. Cancelling after the early check is noticed
        // once the snapshot exists, before anything is written.
        await reads.onRead(2) { await handle.cancel() }

        let task = Task { try await applier.apply(profile(apps: [calculator])) }
        await handle.set(task)

        #expect(try await task.value == .cancelled(rolledBack: false))
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func noChangesLeavesNoSnapshotEvenAfterAConfirmation() async throws {
        let env = try Env(current: DockState(apps: [calculator]))
        defer { env.cleanup() }

        let result = try await env.applier().apply(profile(apps: [calculator])) { _ in true }

        guard case .noChanges = result else {
            Issue.record("Expected .noChanges, got \(result)")
            return
        }
        #expect(await env.snapshots.isEmpty)
    }

    // MARK: Cancellation and concurrency

    @Test func cancellationBeforeWritingTakesNoSnapshotAndWritesNothing() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let applier = env.applier()
        let confirming = Gate()
        let proceed = Gate()

        let task = Task {
            try await applier.apply(profile(apps: [calculator])) { _ in
                await confirming.open()
                await proceed.wait()
                return true
            }
        }
        await confirming.wait()
        task.cancel()
        await proceed.open()

        #expect(try await task.value == .cancelled(rolledBack: false))
        #expect(await env.backend.appliedBatches.isEmpty)
        #expect(await env.snapshots.isEmpty)
        #expect(await env.restarter.count == 0)
    }

    @Test func newerApplyCancelsTheOneInFlightAndWins() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let applier = env.applier()
        let firstConfirming = Gate()
        let targetB = DockState(apps: [notes])

        let first = Task {
            try await applier.apply(profile("A", apps: [calculator])) { _ in
                await firstConfirming.open()
                // Stay in confirm until the newer apply has cancelled this one.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return true
            }
        }
        await firstConfirming.wait()
        let second = Task { try await applier.apply(profile("B", apps: targetB.apps)) }

        #expect(try await first.value == .cancelled(rolledBack: false))
        guard case let .applied(report) = try await second.value else {
            Issue.record("Expected the second apply to be applied")
            return
        }
        #expect(await env.backend.state == targetB)
        #expect(await env.backend.appliedBatches.count == 1)
        #expect(await env.restarter.count == 1)
        #expect(await env.snapshots.map(\.id) == [report.snapshotID])
    }

    @Test func cancellationDuringWritingRollsBackBeforeReturning() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let slow = SlowBackend(env.backend)
        let applier = env.applier(backend: slow)

        let task = Task { try await applier.apply(profile(apps: [calculator])) }
        await slow.entered.wait()
        task.cancel()

        #expect(try await task.value == .cancelled(rolledBack: true))
        // By the time the caller hears back, the snapshot is restored and the Dock restarted.
        let snapshot = try #require(await env.snapshots.first)
        #expect(await env.io.imports == [try await env.store.load(id: snapshot.id)])
        #expect(await env.restarter.count == 1)
    }

    @Test func newerApplyCancelsAWriteInFlightAndRunsAfterTheRollback() async throws {
        let env = try Env(current: DockState(apps: [calendarApp]))
        defer { env.cleanup() }
        let slow = SlowBackend(env.backend)
        let applier = env.applier(backend: slow)
        let targetB = DockState(apps: [notes])

        let first = Task { try await applier.apply(profile("A", apps: [calculator])) }
        await slow.entered.wait()
        let second = Task { try await applier.apply(profile("B", apps: targetB.apps)) }

        #expect(try await first.value == .cancelled(rolledBack: true))
        guard case .applied = try await second.value else {
            Issue.record("Expected the second apply to be applied")
            return
        }
        #expect(await env.backend.state == targetB)
        #expect(await env.io.imports.count == 1)       // only the first was rolled back
        #expect(await env.restarter.count == 2)        // rollback, then the second apply
        #expect(await env.snapshots.count == 2)
    }

    // MARK: Helpers

    /// Exactly one snapshot exists and it was imported back once, byte for byte.
    private func expectRestoredFromTheOnlySnapshot(_ env: Env) async throws {
        let snapshots = await env.snapshots
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        let imports = await env.io.imports
        #expect(imports == [try await env.store.load(id: snapshot.id)])
    }
}

/// Lets a hook cancel the task that is only created after the hook was registered.
private actor TaskBox {
    private var task: Task<ApplyResult, any Error>?
    private var cancelRequested = false

    func set(_ task: Task<ApplyResult, any Error>) {
        self.task = task
        if cancelRequested { task.cancel() }
    }

    func cancel() {
        cancelRequested = true
        task?.cancel()
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor PreviewBox {
    private(set) var value: ApplyPreview?

    func set(_ preview: ApplyPreview) {
        value = preview
    }
}

// MARK: - Integration (real dockutil, temp plist file)

/// Applies only the first operation through `inner`, then fails.
private actor FailAfterFirstOperationBackend: DockBackend {
    private let inner: any DockBackend
    private(set) var partialWriteLanded = false

    init(_ inner: any DockBackend) {
        self.inner = inner
    }

    func read() async throws -> DockState {
        try await inner.read()
    }

    func apply(_ operations: [DockOperation]) async throws {
        let before = try await inner.read()
        try await inner.apply(Array(operations.prefix(1)))
        partialWriteLanded = try await inner.read() != before
        throw DockBackendError.commandFailed("half way")
    }
}

/// Export/import against one plist FILE, in place of `defaults export/import com.apple.dock`.
private struct FileDomainIO: DockDomainIO {
    let plist: URL

    func exportDomain(to url: URL) async throws {
        try Data(contentsOf: plist).write(to: url)
    }

    func importDomain(from url: URL) async throws {
        try Data(contentsOf: url).write(to: plist, options: .atomic)
    }

    func deleteKey(_ key: String) async throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        var dictionary = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist),
            options: [],
            format: &format
        ) as? [String: Any] ?? [:]
        dictionary.removeValue(forKey: key)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            .write(to: plist, options: .atomic)
    }
}

/// Runs the real bundled dockutil through `DockutilBackend(.file(temp plist))`, with snapshots
/// exported from and restored into that same file and no Dock restart. `LiveDockPlistGuard` fails
/// the suite if the live Dock plist changes or the Dock restarts.
///
/// Needs `App/Resources/Helpers/dockutil` (`make dockutil`); skipped with a message otherwise.
@Suite(
    .serialized,
    LiveDockPlistGuard(),
    .enabled(if: BundledDockutil.isAvailable, BundledDockutil.skipMessage),
    .timeLimit(.minutes(2))
)
struct ProfileApplierIntegrationTests {
    private struct Fixture {
        let directory: URL
        let plist: URL
        let backend: DockutilBackend
        let store: SnapshotStore
        let docs: DockItem

        init() throws {
            directory = try makeTempDirectory("omd-applier-int")
            plist = directory.appendingPathComponent("dock.plist")
            try writeEmptyDockPlist(at: plist)
            let folder = directory.appendingPathComponent("Docs", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            docs = .folder(FolderItem(path: folder.path, view: .grid, display: .folder, sort: .name, label: "Docs"))
            backend = DockutilBackend(dockutilURL: BundledDockutil.url, target: .file(plist))
            store = SnapshotStore(
                rootDirectory: directory.appendingPathComponent("snapshots"),
                domainIO: FileDomainIO(plist: plist)
            )
        }

        func applier(
            restarter: any DockRestarting = NoopDockRestarter(),
            resolvePath: @escaping ProfileApplier.AppPathResolver = pathAsGiven
        ) -> ProfileApplier {
            ProfileApplier(backend: backend, snapshots: store, restarter: restarter, resolvePath: resolvePath)
        }

        func dock() throws -> DockState {
            try DockPlistReader(.file(plist)).read()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func expectDock(
        _ fixture: Fixture,
        matches expected: DockState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try fixture.dock()
        #expect(expected.matchesAfterWrite(actual), "Dock is \(actual), expected \(expected)", sourceLocation: sourceLocation)
    }

    @Test func appliesProfilesInTurnAndRollsBackFailures() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let applier = f.applier()

        // A: from empty. B: reorder, swap, a spacer and a different Others section.
        let a = DockState(apps: [calculator, calendarApp], others: [Sample.example, f.docs])
        let b = DockState(apps: [notes, calculator, .spacer(.small)], others: [f.docs])

        guard case .applied = try await applier.apply(profile("A", apps: a.apps, others: a.others)) else {
            Issue.record("Expected A to be applied")
            return
        }
        try expectDock(f, matches: a)

        guard case let .applied(reportB) = try await applier.apply(profile("B", apps: b.apps, others: b.others)) else {
            Issue.record("Expected B to be applied")
            return
        }
        try expectDock(f, matches: b)
        #expect(await f.store.list().snapshots.count == 2)

        // Applying B again is a no-op: no new snapshot.
        guard case .noChanges = try await applier.apply(profile("B", apps: b.apps, others: b.others)) else {
            Issue.record("Expected B again to be .noChanges")
            return
        }
        #expect(await f.store.list().snapshots.count == 2)

        // Forced failure after the write succeeded: the restart fails, so Dock must be back to B.
        let dockBeforeFailure = try f.dock()
        let failing = f.applier(restarter: CountingRestarter(failing: [1]))
        let error = await applyError {
            try await failing.apply(profile("C", apps: [calendarApp, notes], others: [Sample.example]))
        }
        guard case let .failedAndRolledBack(original)? = error else {
            Issue.record("Expected failedAndRolledBack, got \(String(describing: error))")
            return
        }
        #expect(original is RestartFailure)
        #expect(try f.dock() == dockBeforeFailure)
        try expectDock(f, matches: b)

        // The snapshot taken for B can still bring back the earlier state (A) on demand.
        try await f.store.restore(id: reportB.snapshotID, createSafetySnapshot: false)
        try expectDock(f, matches: a)
    }

    @Test func midBatchFailureRollsBackThePartiallyWrittenDock() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let start = DockState(apps: [calculator], others: [f.docs])
        guard case .applied = try await f.applier().apply(profile("Start", apps: start.apps, others: start.others)) else {
            Issue.record("Expected Start to be applied")
            return
        }
        let before = try f.dock()

        // Writes the first operation for real, then fails: a dockutil batch dying half way.
        let flaky = FailAfterFirstOperationBackend(f.backend)
        let applier = ProfileApplier(
            backend: flaky,
            snapshots: f.store,
            restarter: NoopDockRestarter(),
            resolvePath: pathAsGiven
        )
        let error = await applyError {
            try await applier.apply(profile("Broken", apps: [calculator, notes, calendarApp], others: start.others))
        }

        guard case let .failedAndRolledBack(original)? = error else {
            Issue.record("Expected failedAndRolledBack, got \(String(describing: error))")
            return
        }
        #expect(original as? DockBackendError == .commandFailed("half way"))
        #expect(await flaky.partialWriteLanded, "The test must really have written something before failing")
        #expect(try f.dock() == before)
        try expectDock(f, matches: start)
    }

    @Test func unresolvedAppsAreSkippedWhenWritingForReal() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let missing = AppRef(bundleId: "com.example.missing", name: "Missing")
        let resolver: ProfileApplier.AppPathResolver = { $0.bundleId == missing.bundleId ? nil : $0.path }

        let result = try await f.applier(resolvePath: resolver)
            .apply(profile(apps: [calculator, .app(missing), notes])) { _ in true }

        guard case let .applied(report) = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }
        #expect(report.skipped.map(\.app) == [missing])
        try expectDock(f, matches: DockState(apps: [calculator, notes]))
    }
}
