import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct FirstLaunchBootstrapperTests {
    @Test func createsDefaultProfilePinnedSnapshotAndMarker() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let safari = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let downloads = DockItem.folder(FolderItem(path: "/Users/me/Downloads"))
        let expectedState = DockState(apps: [safari], others: [downloads])

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(for: expectedState))
        )
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
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        let validApp = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let unknownApp = DockItem.unknown(UnknownTile(tileType: "mystery-tile", label: "Mystery"))
        let validOther = DockItem.url(URLItem(url: URL(string: "https://apple.com")!, label: "Apple"))
        let unknownOther = DockItem.unknown(UnknownTile(tileType: "recents-tile", label: "Recent"))

        let dockState = DockState(
            apps: [validApp, unknownApp],
            others: [unknownOther, validOther]
        )

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(for: dockState))
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

    @Test func readerFailureDoesNotWriteMarkerOrSnapshot() async throws {
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

        #expect(await snapshotStore.list().snapshots.isEmpty)
    }

    @Test func validationFailureDoesNotWriteMarkerOrSnapshot() async throws {
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

        #expect(await snapshotStore.list().snapshots.isEmpty)
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

    @Test func retryAfterFailureReusesSinglePinnedSnapshot() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profilesDir = tempDir.appendingPathComponent("profiles")
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")

        // Profiles root is a regular file, so saving the profile fails after the snapshot exists.
        try Data().write(to: profilesDir)
        let failing = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: ProfileStore(rootDirectory: profilesDir),
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )
        await #expect(throws: (any Error).self) { try await failing.runIfNeeded() }
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        let firstSnapshots = await snapshotStore.list().snapshots
        #expect(firstSnapshots.count == 1)

        try FileManager.default.removeItem(at: profilesDir)
        let retry = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: ProfileStore(rootDirectory: profilesDir),
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )
        let result = try await retry.runIfNeeded()
        guard case .created(_, let snapshot, _) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(snapshot.id == firstSnapshots[0].id)
        #expect(await snapshotStore.list().snapshots.count == 1)
    }

    @Test func unpinnedFirstLaunchSnapshotIsNotReused() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let unpinned = try await snapshotStore.save(reason: "First launch", pinned: false)
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles")),
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )
        let result = try await bootstrapper.runIfNeeded()
        guard case .created(_, let snapshot, _) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(snapshot.id != unpinned.id)
        #expect(snapshot.pinned)
    }

    @Test func pinnedSnapshotOfAnotherDockIsNotReusedAndIsUnpinned() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        // A leftover from an earlier attempt, taken when the Dock held an unrecognised tile.
        let leftoverStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(label: "Finder"))
        )
        let stale = try await leftoverStore.save(reason: "First launch", pinned: true)
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles")),
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(_, let snapshot, _) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(snapshot.id != stale.id)
        #expect(snapshot.pinned)
        let all = await snapshotStore.list().snapshots
        #expect(all.first { $0.id == stale.id }?.pinned == false)
        #expect(all.filter { $0.pinned && $0.reason == "First launch" }.map(\.id) == [snapshot.id])
    }

    @Test func everyStalePinnedSnapshotIsUnpinnedEvenWhenAnotherOneIsReused() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let snapshotsDir = tempDir.appendingPathComponent("snapshots")
        let snapshotStore = SnapshotStore(
            rootDirectory: snapshotsDir,
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let staleStore = SnapshotStore(
            rootDirectory: snapshotsDir,
            domainIO: FakeDockDomainIO(domainData: try dockPlist(label: "Finder"))
        )
        let staleA = try await staleStore.save(reason: "First launch", pinned: true)
        let matching = try await snapshotStore.save(reason: "First launch", pinned: true)
        let staleB = try await staleStore.save(reason: "First launch", pinned: true)
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { DockState() },
            profileStore: ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles")),
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(_, let snapshot, _) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(snapshot.id == matching.id)
        let all = await snapshotStore.list().snapshots
        #expect(all.filter { $0.pinned && $0.reason == "First launch" }.map(\.id) == [matching.id])
        #expect(all.first { $0.id == staleA.id }?.pinned == false)
        #expect(all.first { $0.id == staleB.id }?.pinned == false)
    }

    @Test func captureIsCheckedAgainstTheSnapshotWithoutReadingTheDockAgain() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let reads = ReadCounter()
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { _ = await reads.next(); return DockState() },
            profileStore: ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles")),
            snapshotStore: SnapshotStore(
                rootDirectory: tempDir.appendingPathComponent("snapshots"),
                domainIO: FakeDockDomainIO(domainData: try dockPlist())
            ),
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        _ = try await bootstrapper.runIfNeeded()

        #expect(await reads.next() == 2)
    }

    @Test func dockChangingDuringTheCaptureIsRetriedOnce() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let safari = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let notes = DockItem.app(AppRef(bundleId: "com.apple.Notes", name: "Notes"))
        // The Dock was edited right after the first read, so the snapshot holds the edited Dock.
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(for: DockState(apps: [safari, notes])))
        )
        let reads = ReadCounter()
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { await reads.next() == 1 ? DockState(apps: [safari]) : DockState(apps: [safari, notes]) },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(let profile, let snapshot, _) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(profile.apps == [safari, notes])
        // The snapshot taken around the edited read was thrown away.
        #expect(await snapshotStore.list().snapshots.map(\.id) == [snapshot.id])
    }

    @Test func dockThatKeepsChangingFailsWithoutSavingAnything() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist())
        )
        let markerURL = tempDir.appendingPathComponent(".first-launch-complete")
        let reads = ReadCounter()
        let bootstrapper = FirstLaunchBootstrapper(
            reader: {
                let n = await reads.next()
                return DockState(apps: [.app(AppRef(bundleId: "com.example.\(n)", name: "App \(n)"))])
            },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerURL
        )

        await #expect(throws: FirstLaunchError.dockChangedDuringCapture) {
            try await bootstrapper.runIfNeeded()
        }

        #expect(await snapshotStore.list().snapshots.isEmpty)
        #expect(await profileStore.list().profiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test func duplicateLabelsInTheLiveDockAreDisambiguated() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let state = DockState(
            apps: [
                .app(AppRef(bundleId: "com.example.a", name: "Same")),
                .app(AppRef(bundleId: "com.example.b", name: "Same")),
                .app(AppRef(bundleId: "com.example.c", name: "Same (2)")),
                .app(AppRef(bundleId: "com.example.d", name: "Pathed", path: "/Applications/Solo.app")),
                .app(AppRef(bundleId: "com.example.e", name: "Pathed", path: "/Other/Solo.app")),
            ],
            others: [
                .folder(FolderItem(path: "/Users/me/Documents/Docs")),
                .folder(FolderItem(path: "/Users/me/Work/Docs")),
                .folder(FolderItem(path: "/Users/me/Old/Docs")),
            ]
        )
        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(for: state))
        )
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { state },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(let profile, _, let dropped) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        try profile.validate()
        #expect(profile.others == [
            .folder(FolderItem(path: "/Users/me/Documents/Docs")),
            .folder(FolderItem(path: "/Users/me/Work/Docs", label: "Docs (2)")),
            .folder(FolderItem(path: "/Users/me/Old/Docs", label: "Docs (3)")),
        ])
        #expect(profile.apps == [
            .app(AppRef(bundleId: "com.example.a", name: "Same")),
            .app(AppRef(bundleId: "com.example.b", name: "Same (3)")),
            .app(AppRef(bundleId: "com.example.c", name: "Same (2)")),
            .app(AppRef(bundleId: "com.example.d", name: "Pathed", path: "/Applications/Solo.app")),
        ])
        // The second Solo.app cannot be relabelled.
        #expect(dropped == [.app(AppRef(bundleId: "com.example.e", name: "Pathed", path: "/Other/Solo.app"))])
    }

    @Test func relabelledTilesAvoidEveryKeyAnotherTileUses() async throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        // The pathless "Mail" collides with Mail.app and would become "Mail (2)", which the file
        // in the other section already has as its label.
        let state = DockState(
            apps: [
                .app(AppRef(bundleId: "com.apple.mail", name: "Mail", path: "/System/Applications/Mail.app")),
                .app(AppRef(bundleId: "com.example.mail", name: "Mail")),
            ],
            others: [
                .file(FileItem(path: "/Users/me/mail.txt", label: "Mail (2)")),
                .folder(FolderItem(path: "/Users/me/com.example.mail")),
            ]
        )
        let profileStore = ProfileStore(rootDirectory: tempDir.appendingPathComponent("profiles"))
        let snapshotStore = SnapshotStore(
            rootDirectory: tempDir.appendingPathComponent("snapshots"),
            domainIO: FakeDockDomainIO(domainData: try dockPlist(for: state))
        )
        let bootstrapper = FirstLaunchBootstrapper(
            reader: { state },
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: tempDir.appendingPathComponent(".first-launch-complete")
        )

        let result = try await bootstrapper.runIfNeeded()

        guard case .created(let profile, _, let dropped) = result else {
            Issue.record("Expected .created but got \(result)")
            return
        }
        #expect(dropped.isEmpty)
        #expect(profile.apps.count == 2 && profile.others.count == 2)
        // `DockutilPlanner.wouldReject` on a full rewrite (apps, then others): no tile's label may
        // be a match key of a tile added before it.
        var keys: Set<String> = []
        for item in profile.apps + profile.others {
            #expect(!keys.contains(DockutilPlanner.computedLabel(of: item)))
            keys.formUnion(DockutilPlanner.matchKeys(of: item))
        }
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

    /// The Dock domain a Dock holding `state` exports. Apps need a label to round-trip their name.
    private func dockPlist(for state: DockState) throws -> Data {
        func tile(_ item: DockItem) -> [String: Any] {
            func fileData(_ path: String) -> [String: Any] {
                ["_CFURLString": path, "_CFURLStringType": 0]
            }
            switch item {
            case let .app(app):
                var data: [String: Any] = ["bundle-identifier": app.bundleId, "file-label": app.name]
                if let path = app.path { data["file-data"] = fileData(path) }
                return ["tile-type": "file-tile", "tile-data": data]
            case let .file(file):
                var data: [String: Any] = ["file-data": fileData(file.path)]
                if let label = file.label { data["file-label"] = label }
                return ["tile-type": "file-tile", "tile-data": data]
            case let .folder(folder):
                var data: [String: Any] = ["file-data": fileData(folder.path)]
                if let label = folder.label { data["file-label"] = label }
                return ["tile-type": "directory-tile", "tile-data": data]
            case let .url(url):
                var data: [String: Any] = ["url": ["_CFURLString": url.url.absoluteString, "_CFURLStringType": 15]]
                if let label = url.label { data["label"] = label }
                return ["tile-type": "url-tile", "tile-data": data]
            case let .spacer(kind):
                return ["tile-type": kind.tileType]
            case let .unknown(unknown):
                var data: [String: Any] = [:]
                if let label = unknown.label { data["label"] = label }
                return ["tile-type": unknown.tileType, "tile-data": data]
            }
        }
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "persistent-apps": state.apps.map(tile),
                "persistent-others": state.others.map(tile),
            ],
            format: .binary,
            options: 0
        )
    }

    /// An empty Dock, or one with a single unrecognised tile labelled `label`.
    private func dockPlist(label: String? = nil) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "persistent-apps": label.map { [["tile-data": ["file-label": $0]]] } ?? [],
                "persistent-others": [],
            ],
            format: .binary,
            options: 0
        )
    }
}

private actor ReadCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
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
