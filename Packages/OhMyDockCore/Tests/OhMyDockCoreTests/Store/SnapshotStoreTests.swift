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
        ])
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

    private func dockPlist(label: String = "Finder") throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "persistent-apps": [
                    ["tile-data": ["file-label": label]],
                ],
                "persistent-others": [],
            ],
            format: .binary,
            options: 0
        )
    }

    private func fileMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        return permissions & 0o777
    }
}

private actor FakeDockDomainIO: DockDomainIO {
    private var domainData: Data
    private(set) var importedData: Data?
    private(set) var exportCount = 0

    init(domainData: Data) {
        self.domainData = domainData
    }

    func setDomainData(_ data: Data) {
        domainData = data
    }

    func exportDomain(to url: URL) async throws {
        exportCount += 1
        try domainData.write(to: url)
    }

    func importDomain(from url: URL) async throws {
        importedData = try Data(contentsOf: url)
        domainData = importedData!
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
