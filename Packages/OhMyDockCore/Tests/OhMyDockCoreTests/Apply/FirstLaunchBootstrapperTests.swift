import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct FirstLaunchBootstrapperTests {
    @Test func createsDefaultProfilePinnedSnapshotAndMarker() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let safari = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let downloads = DockItem.folder(FolderItem(path: "/Users/me/Downloads"))
        let expectedState = DockState(apps: [safari], others: [downloads])

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { expectedState },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(let profile, let snapshot, let droppedItems) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }

        #expect(profile.name == "Default")
        #expect(profile.apps == [safari])
        #expect(profile.others == [downloads])
        #expect(droppedItems.isEmpty)

        #expect(snapshot.pinned)
        #expect(snapshot.reason == "First launch")
        #expect(snapshot.profileName == "Default")

        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        let loadedProfile = try await profileStore.load(id: profile.id)
        #expect(loadedProfile == profile)

        let snapshots = await snapshotStore.list().snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.id == snapshot.id)
    }

    @Test func secondRunReturnsAlreadyCompleted() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        let first = try await bootstrapper.runIfNeeded()
        guard case .created = first else {
            Issue.record("Expected first run to create profile")
            return
        }

        let second = try await bootstrapper.runIfNeeded()
        #expect(second == .alreadyCompleted)

        #expect(await profileStore.list().profiles.count == 1)
        #expect(await snapshotStore.list().snapshots.count == 1)
    }

    @Test func existingProfilesSkipsCreationAndWritesMarker() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let existingProfile = Profile(name: "Work")
        try await profileStore.save(existingProfile)

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let tracker = CallTracker()
        let bootstrapper = FirstLaunchBootstrapper(
            reader: {
                await tracker.markCalled()
                return DockState()
            },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        let result = try await bootstrapper.runIfNeeded()
        #expect(result == .alreadyCompleted)

        let called = await tracker.called
        #expect(!called)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(await profileStore.list().profiles.map(\.name) == ["Work"])
        #expect(await snapshotStore.list().snapshots.isEmpty)
    }

    @Test func unknownItemsDroppedAndReported() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let validApp = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let unknownApp = DockItem.unknown(UnknownTile(tileType: "mystery-tile", label: "Mystery"))
        let validOther = DockItem.url(URLItem(url: URL(string: "https://apple.com")!, label: "Apple"))
        let unknownOther = DockItem.unknown(UnknownTile(tileType: "recents-tile", label: "Recent"))

        let dockState = DockState(
            apps: [validApp, unknownApp],
            others: [unknownOther, validOther]
        )

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { dockState },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        let result = try await bootstrapper.runIfNeeded()
        guard case .created(let profile, _, let droppedItems) = result else {
            Issue.record("Expected .created")
            return
        }

        #expect(profile.apps == [validApp])
        #expect(profile.others == [validOther])
        #expect(droppedItems == [unknownApp, unknownOther])
        #expect(throws: Never.self) {
            try profile.validate()
        }
    }

    @Test func readerFailureDoesNotWriteMarkerKeepsSnapshot() async throws {
        struct ReaderError: Error, Equatable {}

        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { throw ReaderError() },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        await #expect(throws: ReaderError.self) {
            try await bootstrapper.runIfNeeded()
        }

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(await profileStore.list().profiles.isEmpty)

        let snapshots = await snapshotStore.list().snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.reason == "First launch")
        #expect(snapshots.first?.pinned == true)
    }

    @Test func validationFailureDoesNotWriteMarkerKeepsSnapshot() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        // An invalid app with empty bundleId and nil path will fail Profile.validate()
        let invalidApp = DockItem.app(AppRef(bundleId: "", name: "Broken", path: nil))
        let dockState = DockState(apps: [invalidApp], others: [])

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { dockState },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        await #expect(throws: ProfileValidationError.self) {
            try await bootstrapper.runIfNeeded()
        }

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(await profileStore.list().profiles.isEmpty)

        let snapshots = await snapshotStore.list().snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.reason == "First launch")
        #expect(snapshots.first?.pinned == true)
    }

    @Test func nameCollisionCreatesDefault2() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        try await profileStore.save(Profile(name: "Default"))

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL,
            skipIfProfilesExist: false
        )

        let result = try await bootstrapper.runIfNeeded()
        guard case .created(let profile, let snapshot, _) = result else {
            Issue.record("Expected .created")
            return
        }

        #expect(profile.name == "Default (2)")
        #expect(snapshot.profileName == "Default (2)")

        let list = await profileStore.list().profiles
        #expect(list.count == 2)
        #expect(Set(list.map(\.name)) == ["Default", "Default (2)"])
    }

    @Test func nameCollisionIsCaseInsensitiveAndIncrements() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        try await profileStore.save(Profile(name: "default"))
        try await profileStore.save(Profile(name: "Default (2)"))

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL,
            skipIfProfilesExist: false
        )

        let resolved = await bootstrapper.resolveProfileName(base: "Default")
        #expect(resolved == "Default (3)")

        let result = try await bootstrapper.runIfNeeded()
        guard case .created(let profile, _, _) = result else {
            Issue.record("Expected .created")
            return
        }
        #expect(profile.name == "Default (3)")
    }

    @Test func concurrentInvocationsAreSafeAndIdempotent() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let bootstrapper = FirstLaunchBootstrapper(
            reader: {
                try await Task.sleep(nanoseconds: 10_000_000)
                return DockState()
            },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        let count = 10
        let results = try await withThrowingTaskGroup(of: FirstLaunchBootstrapper.Result.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await bootstrapper.runIfNeeded()
                }
            }
            var collected: [FirstLaunchBootstrapper.Result] = []
            for try await res in group {
                collected.append(res)
            }
            return collected
        }

        #expect(results.count == count)

        let createdCount = results.filter {
            if case .created = $0 { return true }
            return false
        }.count
        let alreadyCompletedCount = results.filter { $0 == .alreadyCompleted }.count

        #expect(createdCount == 1)
        #expect(alreadyCompletedCount == count - 1)
        #expect(await profileStore.list().profiles.count == 1)
        #expect(await snapshotStore.list().snapshots.count == 1)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-launch-tests-\(UUID().uuidString)", isDirectory: true)
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
}

private actor CallTracker {
    var called = false
    func markCalled() {
        called = true
    }
}

private actor FakeDockDomainIO: DockDomainIO {
    private var domainData: Data

    init(domainData: Data) {
        self.domainData = domainData
    }

    func exportDomain(to url: URL) async throws {
        try domainData.write(to: url)
    }

    func importDomain(from url: URL) async throws {
        domainData = try Data(contentsOf: url)
    }
}
