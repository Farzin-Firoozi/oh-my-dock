import CryptoKit
import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct SnapshotStoreTests {
    @Test func saveListAndLoadRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let plist = try dockPlist(label: "Original")
        let io = FakeDockDomainIO(domainData: plist)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            now: { date }
        )

        let saved = try await store.save(
            reason: "Before applying profile Work",
            profileName: "Work",
            pinned: true
        )

        #expect(saved.createdAt == date)
        #expect(saved.reason == "Before applying profile Work")
        #expect(saved.profileName == "Work")
        #expect(saved.byteSize == plist.count)
        #expect(saved.sha256.count == 64)
        #expect(saved.pinned)
        #expect(try await store.load(id: saved.id) == plist)

        let result = await store.list()
        #expect(result.failures.isEmpty)
        #expect(result.snapshots == [saved])
    }

    @Test func listOrdersNewestFirst() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let io = FakeDockDomainIO(domainData: try dockPlist(label: "Dock"))
        let clock = TestClock([
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 200),
        ])
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            now: { clock.next() }
        )

        try await store.save(reason: "Old")
        try await store.save(reason: "Newest")
        try await store.save(reason: "Middle")

        #expect(await store.list().snapshots.map(\.reason) == ["Newest", "Middle", "Old"])
    }

    @Test func directoryAndSnapshotFilesUsePrivatePermissions() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        try await store.save(reason: "Manual")

        #expect(try fileMode(at: root) == 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 2)
        for file in files {
            #expect(try fileMode(at: file) == 0o600)
        }
    }

    @Test func checksumMismatchBlocksRestore() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let original = try dockPlist(label: "A")
        let io = FakeDockDomainIO(domainData: original)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let snapshot = try await store.save(reason: "Manual")
        let plistURL = root.appendingPathComponent("\(snapshot.id.uuidString).plist")
        let tampered = try dockPlist(label: "B")
        #expect(tampered.count == original.count)
        try tampered.write(to: plistURL)

        do {
            try await store.restore(id: snapshot.id)
            Issue.record("Restore unexpectedly accepted a modified plist")
        } catch let SnapshotStoreError.checksumMismatch(id, _, _) {
            #expect(id == snapshot.id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await io.importedData == nil)
        #expect(await io.exportCount == 1)
    }

    @Test func restoreImportsExactBytesAndCreatesSafetySnapshot() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let current = try dockPlist(label: "Current")
        let io = FakeDockDomainIO(domainData: target)
        let restoreDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            now: { restoreDate }
        )
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(current)

        try await store.restore(id: targetSnapshot.id)

        #expect(await io.importedData == target)
        let result = await store.list()
        #expect(result.failures.isEmpty)
        #expect(result.snapshots.count == 2)
        let safetySnapshot = try #require(
            result.snapshots.first { $0.id != targetSnapshot.id }
        )
        #expect(safetySnapshot.reason.hasPrefix("Before restoring "))
        #expect(try await store.load(id: safetySnapshot.id) == current)
    }

    @Test func restoreDeletesKeysAbsentFromSnapshot() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let current = try dockPlist(
            label: "Current",
            additionalValues: ["recent-apps": [["tile-data": ["file-label": "Extra"]]]]
        )
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(current)

        try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)

        #expect(await io.deletedKeys == ["recent-apps"])
        #expect(try plistDictionary(await io.domainData) == plistDictionary(target))
    }

    @Test func restoreFailsWhenReadBackDoesNotMatchSnapshot() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(try dockPlist(label: "Current"))
        await io.setDomainDataAfterImport(try dockPlist(label: "Rewritten by macOS"))

        await #expect(
            throws: SnapshotStoreError.restoreVerificationFailed(targetSnapshot.id)
        ) {
            try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)
        }
    }

    @Test func restoreRollsBackToPreviousDomainWhenDeleteFailsMidway() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let current = try dockPlist(
            label: "Current",
            additionalValues: ["extra-a": 1, "extra-b": 2]
        )
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(current)
        await io.failDelete(onCall: 2)

        await #expect(throws: FakeDockDomainIO.Injected.self) {
            try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)
        }
        #expect(try plistDictionary(await io.domainData) == plistDictionary(current))
    }

    @Test func restoreRollsBackToPreviousDomainWhenImportFails() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let current = try dockPlist(label: "Current", additionalValues: ["extra-a": 1])
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(current)
        await io.failNextImport()

        await #expect(throws: FakeDockDomainIO.Injected.self) {
            try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)
        }
        #expect(try plistDictionary(await io.domainData) == plistDictionary(current))
    }

    @Test func restoreRollsBackToPreviousDomainWhenVerificationFails() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let current = try dockPlist(label: "Current", additionalValues: ["extra-a": 1])
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(current)
        await io.setDomainDataAfterImport(try dockPlist(label: "Rewritten by macOS"))

        await #expect(
            throws: SnapshotStoreError.restoreVerificationFailed(targetSnapshot.id)
        ) {
            try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)
        }
        #expect(try plistDictionary(await io.domainData) == plistDictionary(current))
    }

    @Test func restoreToleratesDockRewritingVolatileKeys() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let target = try dockPlist(label: "Target")
        let io = FakeDockDomainIO(domainData: target)
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        let targetSnapshot = try await store.save(reason: "Target")
        await io.setDomainData(try dockPlist(label: "Current", additionalValues: ["mod-count": 1]))
        await io.setDomainDataAfterImport(try dockPlist(
            label: "Target",
            additionalValues: ["mod-count": 7, "recent-apps": [["tile-data": ["file-label": "X"]]]]
        ))

        try await store.restore(id: targetSnapshot.id, createSafetySnapshot: false)
    }

    @Test func safetySnapshotPruneNeverDeletesSnapshotBeingRestored() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let io = FakeDockDomainIO(domainData: try dockPlist(label: "Target"))
        let clock = TestClock((1...5).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            retentionLimit: 1,
            now: { clock.next() }
        )
        let target = try await store.save(reason: "Target")
        await io.setDomainData(try dockPlist(label: "Current"))

        try await store.restore(id: target.id)

        let ids = await store.list().snapshots.map(\.id)
        #expect(ids.contains(target.id))
        #expect(ids.count == 2)
    }

    @Test func pruneKeepsRequestedUnpinnedSnapshotsAndPinnedSnapshots() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let io = FakeDockDomainIO(domainData: try dockPlist())
        let clock = TestClock((1...6).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            now: { clock.next() }
        )

        var saved: [Snapshot] = []
        for index in 1...6 {
            saved.append(try await store.save(reason: "\(index)"))
        }
        try await store.pin(id: saved[1].id)

        try await store.prune(keep: 2)

        var result = await store.list()
        #expect(result.failures.isEmpty)
        #expect(Set(result.snapshots.map(\.id)) == Set([saved[5].id, saved[4].id, saved[1].id]))
        #expect(result.snapshots.first { $0.id == saved[1].id }?.pinned == true)

        try await store.unpin(id: saved[1].id)
        try await store.prune(keep: 0)
        result = await store.list()
        #expect(result.snapshots.map(\.id) == [saved[5].id])
    }

    @Test func saveAutomaticallyPrunesToConfiguredRetentionAndKeepsPinned() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let io = FakeDockDomainIO(domainData: try dockPlist())
        let clock = TestClock((1...4).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: io,
            retentionLimit: 2,
            now: { clock.next() }
        )

        let pinned = try await store.save(reason: "Pinned", pinned: true)
        let old = try await store.save(reason: "Old")
        let newer = try await store.save(reason: "Newer")
        let newest = try await store.save(reason: "Newest")

        let snapshots = await store.list().snapshots
        #expect(Set(snapshots.map(\.id)) == Set([pinned.id, newer.id, newest.id]))
        #expect(!snapshots.contains { $0.id == old.id })
    }

    @Test func corruptSidecarIsReportedAndPreserved() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let snapshot = try await store.save(reason: "Manual")
        let sidecarURL = root.appendingPathComponent("\(snapshot.id.uuidString).json")
        try Data("{not json".utf8).write(to: sidecarURL)

        let result = await store.list()
        #expect(result.snapshots.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].url == sidecarURL)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func rejectsExportWhoseTopLevelValueIsNotDictionary() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let invalid = try PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "dictionary"],
            format: .binary,
            options: 0
        )
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: invalid)
        )

        await #expect(throws: SnapshotStoreError.invalidExport(.expectedDictionary)) {
            try await store.save(reason: "Invalid")
        }
        #expect(await store.list().snapshots.isEmpty)
    }

    @Test func rejectsExportMissingPersistentAppsArray() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let invalid = try PropertyListSerialization.data(
            fromPropertyList: ["persistent-others": []],
            format: .binary,
            options: 0
        )
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: invalid)
        )

        await #expect(throws: SnapshotStoreError.invalidExport(.missingPersistentAppsArray)) {
            try await store.save(reason: "Invalid")
        }
    }

    @Test func rejectsExportMissingPersistentOthersArray() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let invalid = try PropertyListSerialization.data(
            fromPropertyList: ["persistent-apps": []],
            format: .binary,
            options: 0
        )
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: invalid)
        )

        await #expect(throws: SnapshotStoreError.invalidExport(.missingPersistentOthersArray)) {
            try await store.save(reason: "Invalid")
        }
    }

    @Test func rejectsRestoreMissingPersistentOthersArray() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let io = FakeDockDomainIO(domainData: try dockPlist())
        let store = SnapshotStore(rootDirectory: root, domainIO: io)
        var snapshot = try await store.save(reason: "Legacy")
        let invalid = try PropertyListSerialization.data(
            fromPropertyList: ["persistent-apps": []],
            format: .binary,
            options: 0
        )
        try invalid.write(
            to: root.appendingPathComponent("\(snapshot.id.uuidString).plist")
        )
        snapshot.byteSize = invalid.count
        snapshot.sha256 = SHA256.hash(data: invalid)
            .map { String(format: "%02x", $0) }
            .joined()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: root.appendingPathComponent("\(snapshot.id.uuidString).json")
        )

        await #expect(throws: SnapshotStoreError.invalidExport(.missingPersistentOthersArray)) {
            try await store.restore(id: snapshot.id, createSafetySnapshot: false)
        }
    }

    @Test func rejectsMalformedPlistExport() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: Data("not a plist".utf8))
        )

        await #expect(throws: SnapshotStoreError.invalidExport(.malformedPlist)) {
            try await store.save(reason: "Invalid")
        }
    }

    @Test func refusesExportsLargerThanTenMegabytes() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let size = SnapshotStore.maximumSnapshotBytes + 1
        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: Data(repeating: 0, count: size))
        )

        await #expect(
            throws: SnapshotStoreError.exportTooLarge(
                actualBytes: size,
                maximumBytes: SnapshotStore.maximumSnapshotBytes
            )
        ) {
            try await store.save(reason: "Too large")
        }
    }

    @Test func deleteRemovesPlistAndSidecar() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = SnapshotStore(
            rootDirectory: root,
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let snapshot = try await store.save(reason: "Delete me")

        try await store.delete(id: snapshot.id)

        #expect(await store.list().snapshots.isEmpty)
        await #expect(throws: SnapshotStoreError.snapshotNotFound(snapshot.id)) {
            try await store.load(id: snapshot.id)
        }
    }

    @Test func liveDockDomainIOBuildsExpectedDefaultsArguments() async throws {
        let runner = RecordingProcessRunner()
        let io = LiveDockDomainIO(processRunner: runner)
        let exportURL = URL(fileURLWithPath: "/tmp/export.plist")
        let importURL = URL(fileURLWithPath: "/tmp/import.plist")

        try await io.exportDomain(to: exportURL)
        try await io.importDomain(from: importURL)
        try await io.deleteKey("recent-apps")

        let invocations = await runner.invocations
        #expect(invocations == [
            .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/defaults"),
                arguments: ["export", "com.apple.dock", "/tmp/export.plist"]
            ),
            .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/defaults"),
                arguments: ["import", "com.apple.dock", "/tmp/import.plist"]
            ),
            .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/defaults"),
                arguments: ["delete", "com.apple.dock", "recent-apps"]
            ),
        ])
    }

    @Test func foundationProcessRunnerDrainsLargeOutputAndErrorWithoutDeadlock() async throws {
        let result = try await FoundationProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "yes o | head -c 200000; yes e | head -c 200000 >&2",
            ]
        )

        #expect(result.terminationStatus == 0)
        #expect(result.stdout.utf8.count == 200_000)
        #expect(result.standardError.utf8.count == 200_000)
    }

    @Test func foundationProcessRunnerPreservesStdoutOnlyFailureDiagnosis() async throws {
        let result = try await FoundationProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'already exists in dock'; exit 1"]
        )

        #expect(result.terminationStatus == 1)
        #expect(result.stdout == "already exists in dock")
        #expect(result.standardError == result.stdout)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func dockPlist(
        label: String = "Finder",
        additionalValues: [String: Any] = [:]
    ) throws -> Data {
        var dictionary: [String: Any] = [
            "persistent-apps": [
                ["tile-data": ["file-label": label]],
            ],
            "persistent-others": [],
        ]
        dictionary.merge(additionalValues) { _, new in new }
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    private func plistDictionary(_ data: Data) throws -> NSDictionary {
        try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        )
    }

    private func fileMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        return permissions & 0o777
    }
}

private actor FakeDockDomainIO: DockDomainIO {
    private(set) var domainData: Data
    private(set) var importedData: Data?
    private(set) var exportCount = 0
    private(set) var deletedKeys: [String] = []
    private var domainDataAfterImport: Data?
    private var failDeleteCall: Int?
    private var deleteCalls = 0
    private var shouldFailNextImport = false

    struct Injected: Error {}

    func failDelete(onCall call: Int) { failDeleteCall = call }
    func failNextImport() { shouldFailNextImport = true }

    init(domainData: Data) {
        self.domainData = domainData
    }

    func setDomainData(_ data: Data) {
        domainData = data
    }

    func setDomainDataAfterImport(_ data: Data) {
        domainDataAfterImport = data
    }

    func exportDomain(to url: URL) async throws {
        exportCount += 1
        try domainData.write(to: url)
    }

    func importDomain(from url: URL) async throws {
        if shouldFailNextImport {
            shouldFailNextImport = false
            throw Injected()
        }
        importedData = try Data(contentsOf: url)
        var current = try Self.dictionary(from: domainData)
        let imported = try Self.dictionary(from: importedData!)
        current.merge(imported) { _, new in new }
        domainData = try PropertyListSerialization.data(
            fromPropertyList: current,
            format: .binary,
            options: 0
        )
        if let domainDataAfterImport {
            domainData = domainDataAfterImport
            self.domainDataAfterImport = nil
        }
    }

    func deleteKey(_ key: String) async throws {
        deleteCalls += 1
        if deleteCalls == failDeleteCall { throw Injected() }
        deletedKeys.append(key)
        var current = try Self.dictionary(from: domainData)
        current.removeValue(forKey: key)
        domainData = try PropertyListSerialization.data(
            fromPropertyList: current,
            format: .binary,
            options: 0
        )
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}

private actor RecordingProcessRunner: ProcessRunner {
    struct Invocation: Equatable, Sendable {
        var executableURL: URL
        var arguments: [String]
    }

    private(set) var invocations: [Invocation] = []

    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        invocations.append(Invocation(executableURL: executableURL, arguments: arguments))
        return ProcessResult(terminationStatus: 0, standardError: "")
    }
}
