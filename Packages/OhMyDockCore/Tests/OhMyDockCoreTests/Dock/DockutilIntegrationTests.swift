import Foundation
import Testing
@testable import OhMyDockCore

/// Runs the REAL bundled dockutil against temp plist FILES created from scratch. Every command
/// carries `--no-restart` and a canonical temp file path (the backend refuses anything else).
/// `LiveDockPlistGuard` fails any test that changes the live Dock plist or restarts the Dock.
///
/// Needs `App/Resources/Helpers/dockutil` (`make dockutil`); skipped with a message otherwise.
@Suite(
    .serialized,
    LiveDockPlistGuard(),
    .enabled(if: BundledDockutil.isAvailable, BundledDockutil.skipMessage)
)
struct DockutilIntegrationTests {
    /// A temp plist file target with a real folder and file to add.
    struct Fixture {
        let directory: URL
        let plist: URL
        let docsFolder: URL
        let notesFile: URL
        let backend: DockutilBackend

        init(apps: [[String: Any]] = [], others: [[String: Any]] = [], extra: [String: Any] = [:]) throws {
            directory = try makeTempDirectory("omd-integration")
            plist = directory.appendingPathComponent("dock.plist")
            try writeDockPlist(at: plist, apps: apps, others: others, extra: extra)
            docsFolder = directory.appendingPathComponent("Docs", isDirectory: true)
            try FileManager.default.createDirectory(at: docsFolder, withIntermediateDirectories: true)
            notesFile = directory.appendingPathComponent("todo.txt")
            try Data("todo".utf8).write(to: notesFile)
            backend = DockutilBackend(dockutilURL: BundledDockutil.url, target: .file(plist))
        }

        func cleanup() {
            // The read-only test leaves a 0444 file behind; its directory is still removable.
            try? FileManager.default.removeItem(at: directory)
        }

        func rawDomain() throws -> [String: Any] {
            let data = try Data(contentsOf: plist)
            return try #require(
                try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            )
        }

        var folder: DockItem {
            .folder(FolderItem(
                path: docsFolder.path, view: .grid, display: .folder, sort: .dateAdded, label: "Docs"
            ))
        }

        var file: DockItem {
            .file(FileItem(path: notesFile.path, label: "Todo"))
        }
    }

    private let calc = Sample.calculator
    private let calendar = Sample.calendar
    private let notes = Sample.notes

    private func appTile(_ path: String, label: String) -> [String: Any] {
        [
            "GUID": 1_234_567_890,
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": path, "_CFURLStringType": 0],
                "file-label": label,
                "file-type": 41,
            ] as [String: Any],
        ]
    }

    // MARK: - Insert

    @Test func insertsEveryKindAtGivenPositions() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let operations: [DockOperation] = [
            .insert(calc, section: .apps, index: 0),
            .insert(notes, section: .apps, index: 1),
            .insert(calendar, section: .apps, index: 1),          // between the two
            .insert(.spacer(.normal), section: .apps, index: 1),
            .insert(.spacer(.small), section: .apps, index: 3),
            .insert(.spacer(.flex), section: .apps, index: 5),    // == count: append
            .insert(Sample.example, section: .others, index: 0),
            .insert(f.folder, section: .others, index: 0),         // before the URL
            .insert(Sample.unlabelledURL, section: .others, index: 2),
            .insert(f.file, section: .others, index: 1),
        ]
        let expected = try DockState().applying(operations)

        try await f.backend.apply(operations)

        let actual = try await f.backend.read()
        #expect(expected.matchesAfterWrite(actual))
        #expect(actual.apps.map(\.itemType) == [.app, .spacer, .app, .spacer, .app, .spacer])
        #expect(actual.apps.compactMap(Self.spacerKind) == [.normal, .small, .flex])
        #expect(actual.others.map(\.itemType) == [.folder, .file, .url, .url])
        guard case let .folder(folder) = actual.others[0] else { return }
        #expect(folder.view == .grid)
        #expect(folder.display == .folder)
        #expect(folder.sort == .dateAdded)
        #expect(folder.label == "Docs")
        guard case let .app(app) = actual.apps[0] else { return }
        #expect(app.path == "/System/Applications/Calculator.app")
        #expect(app.bundleId == "com.apple.calculator")
    }

    @Test(arguments: [
        (FolderView.auto, FolderDisplay.stack, FolderSort.name),
        (.fan, .folder, .dateModified),
        (.list, .stack, .dateCreated),
        (.grid, .folder, .kind),
    ])
    func folderViewDisplayAndSortRoundTrip(view: FolderView, display: FolderDisplay, sort: FolderSort) async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let folder = DockItem.folder(FolderItem(path: f.docsFolder.path, view: view, display: display, sort: sort))

        try await f.backend.apply([.insert(folder, section: .others, index: 0)])

        guard case let .folder(actual)? = try await f.backend.read().others.first else {
            Issue.record("No folder read back")
            return
        }
        #expect(actual.view == view)
        #expect(actual.display == display)
        #expect(actual.sort == sort)
        #expect(actual.label == "Docs")
    }

    @Test func labelsStartingWithADashAreWritten() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let item = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: "-dash"))

        try await f.backend.apply([.insert(item, section: .others, index: 0)])

        guard case let .url(actual)? = try await f.backend.read().others.first else {
            Issue.record("No URL read back")
            return
        }
        #expect(actual.label == "-dash")
    }

    @Test func spacerIsNotRefusedBecauseOfAFolderNamedLikeTheWorkingDirectory() async throws {
        // Without `--label`, dockutil labels a spacer add with the working directory's name
        // and refuses it when a tile in the section carries that label.
        let f = try Fixture()
        defer { f.cleanup() }
        let cwdName = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        let sameName = f.directory.appendingPathComponent(cwdName, isDirectory: true)
        try FileManager.default.createDirectory(at: sameName, withIntermediateDirectories: true)
        let folder = DockItem.folder(FolderItem(path: sameName.path))

        try await f.backend.apply([
            .insert(folder, section: .others, index: 0),
            .insert(.spacer(.normal), section: .others, index: 1),
        ])

        #expect(try await f.backend.read().others.map(\.itemType) == [.folder, .spacer])
    }

    // MARK: - Move and remove

    @Test func movesWithinASection() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .insert(calc, section: .apps, index: 0),
            .insert(calendar, section: .apps, index: 1),
            .insert(notes, section: .apps, index: 2),
        ])

        try await f.backend.apply([
            .move(section: .apps, from: 0, to: 2),   // calendar, notes, calc
            .move(section: .apps, from: 1, to: 0),   // notes, calendar, calc
            .move(section: .apps, from: 2, to: 1),   // notes, calc, calendar
        ])

        #expect(try await f.backend.read().apps.compactMap(Self.appName) == ["Notes", "Calculator", "Calendar"])
    }

    @Test func movesOnlyTheNamedTileWhenOthersHoldDifferentKinds() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .insert(f.folder, section: .others, index: 0),
            .insert(Sample.example, section: .others, index: 1),
            .insert(f.file, section: .others, index: 2),
        ])

        try await f.backend.apply([.move(section: .others, from: 2, to: 0)])

        #expect(try await f.backend.read().others.map(\.itemType) == [.file, .folder, .url])
    }

    @Test func removesAppsURLsFoldersAndFiles() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .insert(calc, section: .apps, index: 0),
            .insert(notes, section: .apps, index: 1),
            .insert(f.folder, section: .others, index: 0),
            .insert(Sample.example, section: .others, index: 1),
            .insert(f.file, section: .others, index: 2),
        ])

        try await f.backend.apply([
            .remove(section: .apps, index: 0),
            .remove(section: .others, index: 2),
            .remove(section: .others, index: 0),
        ])

        let actual = try await f.backend.read()
        #expect(actual.apps.compactMap(Self.appName) == ["Notes"])
        #expect(actual.others.map(\.itemType) == [.url])
    }

    // MARK: - Full rewrite

    @Test func replaceAllRebuildsTheDock() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .insert(calc, section: .apps, index: 0),
            .insert(Sample.example, section: .others, index: 0),
        ])
        let target = DockState(
            apps: [notes, .spacer(.flex), calendar, .spacer(.normal), .spacer(.normal)],
            others: [f.folder, .spacer(.small), Sample.unlabelledURL]
        )

        try await f.backend.apply([.replaceAll(target)])

        let actual = try await f.backend.read()
        #expect(target.matchesAfterWrite(actual))
        #expect(actual.apps.count == 5)
        #expect(actual.others.count == 3)
    }

    @Test func replaceAllWithAnEmptyDockEmptiesBothSections() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .insert(calc, section: .apps, index: 0),
            .insert(f.folder, section: .others, index: 0),
        ])

        try await f.backend.apply([.replaceAll(DockState())])

        #expect(try await f.backend.read() == DockState())
    }

    @Test func removingAndMovingSpacersRewritesTheDock() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.backend.apply([
            .replaceAll(DockState(
                apps: [calc, .spacer(.small), .spacer(.small), notes, .spacer(.flex)],
                others: [Sample.example]
            )),
        ])

        // Spacers have no address, so both of these need a full rewrite.
        try await f.backend.apply([.remove(section: .apps, index: 1)])
        try await f.backend.apply([.move(section: .apps, from: 3, to: 0)])

        let actual = try await f.backend.read()
        #expect(actual.apps.map(\.itemType) == [.spacer, .app, .spacer, .app])
        #expect(actual.apps.compactMap(Self.spacerKind) == [.flex, .small])
        #expect(actual.others.map(\.itemType) == [.url])
    }

    @Test func duplicateTilesAreHandledByARewrite() async throws {
        let calcTile = appTile("/System/Applications/Calculator.app", label: "Calculator")
        let f = try Fixture(apps: [calcTile, calcTile, appTile("/System/Applications/Notes.app", label: "Notes")])
        defer { f.cleanup() }
        #expect(try await f.backend.read().apps.count == 3)

        try await f.backend.apply([.remove(section: .apps, index: 1)])

        #expect(try await f.backend.read().apps.compactMap(Self.appName) == ["Calculator", "Notes"])
    }

    @Test func unlabelledUnknownTileThatIsRemovedViaRewrite() async throws {
        let recents: [String: Any] = ["GUID": 7, "tile-type": "recents-tile", "tile-data": ["list-type": 1] as [String: Any]]
        let f = try Fixture(apps: [appTile("/System/Applications/Calculator.app", label: "Calculator")], others: [recents])
        defer { f.cleanup() }
        #expect(try await f.backend.read().others.map(\.itemType) == [.unknown])

        try await f.backend.apply([.remove(section: .others, index: 0)])

        #expect(try await f.backend.read().others.isEmpty)
    }

    @Test func labelledUnknownTileStartingWithADashIsRemovedByEqualsForm() async throws {
        let odd: [String: Any] = [
            "GUID": 8, "tile-type": "odd-tile", "tile-data": ["label": "-odd"] as [String: Any],
        ]
        let f = try Fixture(others: [odd])
        defer { f.cleanup() }

        try await f.backend.apply([.remove(section: .others, index: 0)])

        #expect(try await f.backend.read().others.isEmpty)
    }

    @Test func rewriteClearsRecentAppsAndKeepsOtherPreferences() async throws {
        let f = try Fixture(
            apps: [appTile("/System/Applications/Calculator.app", label: "Calculator")],
            extra: [
                "tilesize": 48,
                "recent-apps": [appTile("/System/Applications/Notes.app", label: "Notes")],
            ]
        )
        defer { f.cleanup() }

        try await f.backend.apply([.replaceAll(DockState(apps: [notes]))])

        let domain = try f.rawDomain()
        #expect((domain["recent-apps"] as? [Any])?.isEmpty == true)
        #expect(domain["tilesize"] as? Int == 48)
    }

    @Test func incrementalEditsLeaveRecentAppsAlone() async throws {
        let recent = appTile("/System/Applications/Notes.app", label: "Notes")
        let f = try Fixture(extra: ["recent-apps": [recent]])
        defer { f.cleanup() }

        try await f.backend.apply([.insert(calc, section: .apps, index: 0)])

        #expect((try f.rawDomain()["recent-apps"] as? [Any])?.count == 1)
    }

    // MARK: - Verification and failure

    @Test func exitZeroWithoutAWriteIsCaughtByVerification() async throws {
        let f = try Fixture()
        // dockutil exits 0 although `defaults import` cannot replace the plist when the plist and
        // its directory are read-only (spike 0.4 caveat 1). Only the re-read can tell.
        let before = try Data(contentsOf: f.plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.plist.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
            f.cleanup()
        }

        let error = await #expect(throws: DockBackendError.self) {
            try await f.backend.apply([.insert(calc, section: .apps, index: 0)])
        }

        guard case .verificationFailed? = error else {
            Issue.record("Expected verificationFailed, got \(String(describing: error))")
            return
        }
        #expect(try Data(contentsOf: f.plist) == before)
    }

    @Test func missingDockutilBinaryIsCommandFailed() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let backend = DockutilBackend(
            dockutilURL: f.directory.appendingPathComponent("no-such-dockutil"),
            target: .file(f.plist)
        )

        let error = await #expect(throws: DockBackendError.self) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }

        guard case .commandFailed? = error else {
            Issue.record("Expected commandFailed, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Target safety

    @Test func aSymlinkToTheLivePlistIsRefusedBeforeDockutilRuns() async throws {
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard FileManager.default.fileExists(atPath: live.path) else {
            Issue.record("No live Dock plist at \(live.path); cannot check the alias refusal on this machine")
            return
        }
        let f = try Fixture()
        defer { f.cleanup() }
        let alias = f.directory.appendingPathComponent("innocent.plist")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live)
        let backend = DockutilBackend(dockutilURL: BundledDockutil.url, target: .file(alias))

        let error = await #expect(throws: DockutilBackendError.self) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }

        guard case .targetIsLiveDockPlist? = error else {
            Issue.record("Expected targetIsLiveDockPlist, got \(String(describing: error))")
            return
        }
        // The suite guard additionally proves the live plist is byte-for-byte unchanged.
    }

    @Test func aDirectoryTargetIsRefusedBeforeDockutilRuns() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let backend = DockutilBackend(dockutilURL: BundledDockutil.url, target: .file(f.directory))

        await #expect(throws: DockutilBackendError.targetIsDirectory(path: f.directory.path)) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }
    }

    // MARK: - Helpers

    private static func spacerKind(_ item: DockItem) -> SpacerKind? {
        guard case let .spacer(kind) = item else { return nil }
        return kind
    }

    private static func appName(_ item: DockItem) -> String? {
        guard case let .app(app) = item else { return nil }
        return app.name
    }
}
