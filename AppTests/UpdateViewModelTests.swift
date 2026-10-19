import Foundation
import OhMyDockCore
import Testing

private actor FakeChecker: UpdateChecking {
    private(set) var calls: [String] = []
    var result: Result<UpdateCheckResult, any Error>

    init(_ result: Result<UpdateCheckResult, any Error>) { self.result = result }

    func check(currentVersion: String) async throws -> UpdateCheckResult {
        calls.append(currentVersion)
        return try result.get()
    }
}

@MainActor
private final class RecordingOpener: ReleasePageOpening {
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private func makeInfo() throws -> ReleaseInfo {
    ReleaseInfo(
        version: try #require(SemVer("0.2.0")),
        pageURL: try #require(URL(string: "https://github.com/Farzin-Firoozi/oh-my-dock/releases/tag/v0.2.0")),
        notes: ""
    )
}

private func makeDefaults() throws -> UserDefaults {
    let suite = "UpdateViewModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
private func makeModel(
    _ checker: FakeChecker,
    defaults: UserDefaults,
    clock: Clock = Clock(),
    opener: RecordingOpener = RecordingOpener()
) -> UpdateViewModel {
    UpdateViewModel(checker: checker, defaults: defaults, currentVersion: "0.1.0", opener: opener, now: { clock.date })
}

@MainActor
@Suite struct UpdateViewModelTests {
    @Test func autoCheckDefaultsToOn() throws {
        let model = makeModel(FakeChecker(.success(.upToDate)), defaults: try makeDefaults())
        #expect(model.autoCheckEnabled)
    }

    @Test func toggleIsPersisted() throws {
        let defaults = try makeDefaults()
        makeModel(FakeChecker(.success(.upToDate)), defaults: defaults).autoCheckEnabled = false
        #expect(makeModel(FakeChecker(.success(.upToDate)), defaults: defaults).autoCheckEnabled == false)
    }

    @Test func toggleOffMeansNoNetwork() async throws {
        let checker = FakeChecker(.success(.upToDate))
        let model = makeModel(checker, defaults: try makeDefaults())
        model.autoCheckEnabled = false
        await model.checkIfDue()
        #expect(await checker.calls.isEmpty)
        #expect(model.lastCheckDate == nil)
    }

    @Test func firstCheckRunsAndRecordsTime() async throws {
        let checker = FakeChecker(.success(.available(try makeInfo())))
        let clock = Clock()
        let model = makeModel(checker, defaults: try makeDefaults(), clock: clock)
        await model.checkIfDue()
        #expect(await checker.calls == ["0.1.0"])
        #expect(model.availableUpdate?.version == SemVer("0.2.0"))
        #expect(model.lastCheckDate == clock.date)
    }

    @Test func throttlesWithin24Hours() async throws {
        let checker = FakeChecker(.success(.upToDate))
        let clock = Clock()
        let model = makeModel(checker, defaults: try makeDefaults(), clock: clock)
        await model.checkIfDue()
        clock.date.addTimeInterval(24 * 3600 - 1)
        await model.checkIfDue()
        #expect(await checker.calls.count == 1)
        clock.date.addTimeInterval(1)
        await model.checkIfDue()
        #expect(await checker.calls.count == 2)
    }

    @Test func throttleSurvivesRelaunch() async throws {
        let defaults = try makeDefaults()
        let clock = Clock()
        let first = FakeChecker(.success(.upToDate))
        await makeModel(first, defaults: defaults, clock: clock).checkIfDue()
        let second = FakeChecker(.success(.upToDate))
        await makeModel(second, defaults: defaults, clock: clock).checkIfDue()
        #expect(await second.calls.isEmpty)
    }

    @Test func futureLastCheckCountsAsDue() async throws {
        let defaults = try makeDefaults()
        let clock = Clock()
        defaults.set(clock.date.addingTimeInterval(3600), forKey: UpdateViewModel.lastCheckKey)
        let checker = FakeChecker(.success(.upToDate))
        await makeModel(checker, defaults: defaults, clock: clock).checkIfDue()
        #expect(await checker.calls.count == 1)
    }

    @Test func backgroundFailureIsSilentAndStillThrottled() async throws {
        let checker = FakeChecker(.failure(UpdateCheckError.network("offline")))
        let model = makeModel(checker, defaults: try makeDefaults())
        await model.checkIfDue()
        #expect(model.manualMessage == nil)
        #expect(model.availableUpdate == nil)
        await model.checkIfDue()
        #expect(await checker.calls.count == 1)
    }

    @Test func manualCheckIgnoresToggleAndThrottle() async throws {
        let checker = FakeChecker(.success(.upToDate))
        let model = makeModel(checker, defaults: try makeDefaults())
        model.autoCheckEnabled = false
        await model.checkNow()
        await model.checkNow()
        #expect(await checker.calls.count == 2)
        #expect(model.manualMessage?.contains("up to date") == true)
    }

    @Test func manualFailureShowsShortMessage() async throws {
        let model = makeModel(FakeChecker(.failure(UpdateCheckError.network("offline"))), defaults: try makeDefaults())
        await model.checkNow()
        #expect(model.manualMessage == UpdateCheckError.network("offline").errorDescription)
    }

    @Test func manualAvailableReportsVersion() async throws {
        let model = makeModel(FakeChecker(.success(.available(try makeInfo()))), defaults: try makeDefaults())
        await model.checkNow()
        #expect(model.manualMessage?.contains("0.2.0") == true)
        #expect(model.availableUpdate != nil)
    }

    @Test func upToDateClearsEarlierUpdate() async throws {
        let checker = FakeChecker(.success(.available(try makeInfo())))
        let model = makeModel(checker, defaults: try makeDefaults())
        await model.checkNow()
        await checker.set(.success(.upToDate))
        await model.checkNow()
        #expect(model.availableUpdate == nil)
    }

    @Test func failureKeepsEarlierUpdate() async throws {
        let checker = FakeChecker(.success(.available(try makeInfo())))
        let model = makeModel(checker, defaults: try makeDefaults())
        await model.checkNow()
        await checker.set(.failure(UpdateCheckError.network("offline")))
        await model.checkNow()
        #expect(model.availableUpdate != nil)
    }

    @Test func openReleasePageOpensOnlyWhenAvailable() async throws {
        let opener = RecordingOpener()
        let checker = FakeChecker(.success(.available(try makeInfo())))
        let model = makeModel(checker, defaults: try makeDefaults(), opener: opener)
        model.openReleasePage()
        #expect(opener.opened.isEmpty)
        await model.checkNow()
        model.openReleasePage()
        #expect(opener.opened == [try makeInfo().pageURL])
    }
}

private extension FakeChecker {
    func set(_ new: Result<UpdateCheckResult, any Error>) { result = new }
}
