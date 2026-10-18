import Foundation
import Testing
@testable import OhMyDockCore

/// Exact dockutil argument lists, driven through a recording runner. No process is started.
@Suite struct DockutilBackendTests {
    private let calc = Sample.calculator
    private let calendar = Sample.calendar
    private let notes = Sample.notes

    // MARK: - Insert

    @Test func insertAppAtStartOfApps() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(calc, section: .apps, index: 0)],
            to: DockState(apps: [notes])
        )

        #expect(calls == [h.full([
            "--add", "/System/Applications/Calculator.app",
            "--type", "file", "--section", "apps", "--position", "1",
        ])])
        #expect(h.runner.calls.allSatisfy { $0.executableURL == h.dockutil })
    }

    @Test func insertPositionIsIndexPlusOne() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(notes, section: .apps, index: 2)],
            to: DockState(apps: [calc, calendar])
        )

        #expect(calls.first?.contains("--position") == true)
        #expect(calls == [h.full([
            "--add", "/System/Applications/Notes.app",
            "--type", "file", "--section", "apps", "--position", "3",
        ])])
    }

    @Test func insertLabelledURLIntoOthers() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(Sample.example, section: .others, index: 0)],
            to: DockState()
        )

        #expect(calls == [h.full([
            "--add", "https://example.com",
            "--type", "url", "--section", "others", "--position", "1",
            "--label=Example",
        ])])
    }

    @Test func insertURLWithoutLabelOmitsLabel() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(Sample.unlabelledURL, section: .others, index: 0)],
            to: DockState()
        )

        #expect(calls == [h.full([
            "--add", "https://swift.org/blog",
            "--type", "url", "--section", "others", "--position", "1",
        ])])
    }

    @Test func insertFolderPassesViewDisplayAndSort() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(Sample.docs, section: .others, index: 0)],
            to: DockState()
        )

        #expect(calls == [h.full([
            "--add", "/Users/me/Docs",
            "--type", "directory", "--section", "others", "--position", "1",
            "--label=Docs", "--view", "grid", "--display", "folder", "--sort", "dateadded",
        ])])
    }

    @Test(arguments: [
        (FolderView.auto, FolderDisplay.stack, FolderSort.name, "auto", "stack", "name"),
        (.fan, .folder, .dateModified, "fan", "folder", "datemodified"),
        (.list, .stack, .dateCreated, "list", "stack", "datecreated"),
        (.grid, .folder, .kind, "grid", "folder", "kind"),
    ])
    func folderOptionRawValuesAreDockutilArguments(
        view: FolderView, display: FolderDisplay, sort: FolderSort,
        viewArgument: String, displayArgument: String, sortArgument: String
    ) async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let folder = DockItem.folder(FolderItem(path: "/Users/me/F", view: view, display: display, sort: sort))

        let calls = try await h.apply([.insert(folder, section: .others, index: 0)], to: DockState())

        #expect(calls == [h.full([
            "--add", "/Users/me/F", "--type", "directory", "--section", "others", "--position", "1",
            "--view", viewArgument, "--display", displayArgument, "--sort", sortArgument,
        ])])
    }

    @Test func insertPlainFile() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(Sample.plainFile, section: .others, index: 0)],
            to: DockState()
        )

        #expect(calls == [h.full([
            "--add", "/Users/me/notes.txt",
            "--type", "file", "--section", "others", "--position", "1",
            "--label=Todo",
        ])])
    }

    @Test(arguments: SpacerKind.allCases)
    func insertSpacerUsesKindAsType(kind: SpacerKind) async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.insert(.spacer(kind), section: .apps, index: 0)],
            to: DockState(apps: [calc])
        )

        #expect(calls == [h.full([
            "--add", "", "--type", kind.rawValue, "--section", "apps", "--position", "1",
            "--label=oh-my-dock-spacer",
        ])])
    }

    @Test func emptyLabelIsNotPassed() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let item = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: ""))

        let calls = try await h.apply([.insert(item, section: .others, index: 0)], to: DockState())

        #expect(calls.first?.contains { $0.hasPrefix("--label") } == false)
    }

    // MARK: - Remove and move

    @Test func removeAppAddressesItByPath() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.remove(section: .apps, index: 1)],
            to: DockState(apps: [calc, notes])
        )

        #expect(calls == [h.full(["--remove=/System/Applications/Notes.app"])])
    }

    @Test func removeURLAndFolderAddressByURLAndPath() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [
                .remove(section: .others, index: 1),
                .remove(section: .others, index: 0),
            ],
            to: DockState(others: [Sample.example, Sample.docs])
        )

        #expect(calls == [
            h.full(["--remove=/Users/me/Docs"]),
            h.full(["--remove=https://example.com"]),
        ])
    }

    @Test func moveUsesTargetIndexPlusOneAsPosition() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.move(section: .apps, from: 0, to: 2)],
            to: DockState(apps: [calc, calendar, notes])
        )

        #expect(calls == [h.full(["--move=/System/Applications/Calculator.app", "--position", "3"])])
    }

    @Test func moveToSameIndexRunsNothing() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.move(section: .apps, from: 1, to: 1)],
            to: DockState(apps: [calc, calendar])
        )

        #expect(calls.isEmpty)
    }

    @Test func emptyBatchRunsNothing() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        #expect(try await h.apply([], to: DockState(apps: [calc])).isEmpty)
    }

    @Test func addressStartingWithDashUsesEqualsForm() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let odd = DockItem.unknown(UnknownTile(tileType: "mystery-tile", label: "-odd"))

        let calls = try await h.apply([.remove(section: .others, index: 0)], to: DockState(others: [odd]))

        #expect(calls == [h.full(["--remove=-odd"])])
    }

    @Test func sequentialIndexesSeeEarlierOperations() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        // After the insert, index 1 is Notes, not Calendar.
        let calls = try await h.apply(
            [
                .insert(calc, section: .apps, index: 0),
                .remove(section: .apps, index: 1),
                .move(section: .apps, from: 1, to: 0),
            ],
            to: DockState(apps: [notes, calendar])
        )

        #expect(calls == [
            h.full([
                "--add", "/System/Applications/Calculator.app",
                "--type", "file", "--section", "apps", "--position", "1",
            ]),
            h.full(["--remove=/System/Applications/Notes.app"]),
            h.full(["--move=/System/Applications/Calendar.app", "--position", "1"]),
        ])
    }

    // MARK: - Full rewrite

    @Test func replaceAllRemovesEverythingThenAddsInOrder() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let target = DockState(
            apps: [calc, .spacer(.small), notes],
            others: [Sample.example, Sample.docs]
        )

        let calls = try await h.apply([.replaceAll(target)], to: DockState(apps: [calendar]))

        #expect(calls == [
            h.full(["--remove", "all"]),
            h.full(["--add", "/System/Applications/Calculator.app", "--type", "file", "--section", "apps"]),
            h.full([
                "--add", "", "--type", "small-spacer", "--section", "apps",
                "--label=oh-my-dock-spacer",
            ]),
            h.full(["--add", "/System/Applications/Notes.app", "--type", "file", "--section", "apps"]),
            h.full(["--add", "https://example.com", "--type", "url", "--section", "others", "--label=Example"]),
            h.full([
                "--add", "/Users/me/Docs", "--type", "directory", "--section", "others",
                "--label=Docs", "--view", "grid", "--display", "folder", "--sort", "dateadded",
            ]),
        ])
    }

    @Test func neverUsesRemoveSpacerTiles() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.remove(section: .apps, index: 1)],
            to: DockState(apps: [calc, .spacer(.normal), .spacer(.normal), notes])
        )

        #expect(!calls.joined().contains("spacer-tiles"))
        #expect(calls.first == h.full(["--remove", "all"]))
    }

    @Test func removingASpacerRewritesTheWholeDock() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.remove(section: .apps, index: 1)],
            to: DockState(apps: [calc, .spacer(.flex), notes], others: [Sample.example])
        )

        #expect(calls == [
            h.full(["--remove", "all"]),
            h.full(["--add", "/System/Applications/Calculator.app", "--type", "file", "--section", "apps"]),
            h.full(["--add", "/System/Applications/Notes.app", "--type", "file", "--section", "apps"]),
            h.full(["--add", "https://example.com", "--type", "url", "--section", "others", "--label=Example"]),
        ])
    }

    @Test func movingASpacerRewritesTheWholeDock() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.move(section: .apps, from: 1, to: 0)],
            to: DockState(apps: [calc, .spacer(.normal)])
        )

        #expect(calls.first == h.full(["--remove", "all"]))
        #expect(calls.count == 3)
        #expect(calls[1].contains("") && calls[1].contains("spacer"))
    }

    @Test func duplicateTilesRewriteTheWholeDock() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        // The same app twice: `--remove <path>` would hit whichever dockutil finds first.
        let calls = try await h.apply(
            [.remove(section: .apps, index: 1)],
            to: DockState(apps: [calc, calc, notes])
        )

        #expect(calls == [
            h.full(["--remove", "all"]),
            h.full(["--add", "/System/Applications/Calculator.app", "--type", "file", "--section", "apps"]),
            h.full(["--add", "/System/Applications/Notes.app", "--type", "file", "--section", "apps"]),
        ])
    }

    @Test func addressSharedAcrossSectionsRewritesTheWholeDock() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        // A URL tile labelled with the app's path: removing the app by path is ambiguous.
        let lookalike = DockItem.url(URLItem(
            url: URL(string: "https://example.com")!, label: "/System/Applications/Calculator.app"
        ))

        let calls = try await h.apply(
            [.remove(section: .apps, index: 0)],
            to: DockState(apps: [calc], others: [lookalike])
        )

        #expect(calls.first == h.full(["--remove", "all"]))
    }

    @Test func unlabelledUnknownTileRewrites() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let recents = DockItem.unknown(UnknownTile(tileType: "recents-tile"))

        let calls = try await h.apply(
            [.remove(section: .others, index: 0)],
            to: DockState(apps: [calc], others: [recents])
        )

        #expect(calls.first == h.full(["--remove", "all"]))
    }

    @Test func rewriteThatWouldDropUnknownTileIsRefusedBeforeAnyCommand() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let before = DockState(
            apps: [.spacer(.normal), calc],
            others: [.unknown(UnknownTile(tileType: "recents-tile"))]
        )
        let backend = h.backend(reading: [before])

        await #expect(throws: DockBackendError.self) {
            try await backend.apply([.remove(section: .apps, index: 0)])
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func labelCollisionOnInsertFallsBackToARewriteThatAvoidsIt() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let oldDocs = DockItem.folder(FolderItem(path: "/Users/me/Docs"))
        let newDocs = DockItem.folder(FolderItem(path: "/Volumes/Work/Docs"))

        // Inserting before removing would make dockutil refuse "Docs"; the rewrite never holds both.
        let calls = try await h.apply(
            [
                .insert(newDocs, section: .others, index: 0),
                .remove(section: .others, index: 1),
            ],
            to: DockState(others: [oldDocs])
        )

        #expect(calls.first == h.full(["--remove", "all"]))
        #expect(calls.count == 2)
        #expect(calls[1].contains("/Volumes/Work/Docs"))
    }

    @Test func unavoidableLabelCollisionIsRefusedBeforeAnyCommand() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let target = DockState(others: [
            .folder(FolderItem(path: "/Users/me/Docs")),
            .folder(FolderItem(path: "/Volumes/Work/Docs")),
        ])
        let backend = h.backend(reading: [DockState()])

        await #expect(throws: DockBackendError.self) {
            try await backend.apply([.replaceAll(target)])
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func spacersNeverCollide() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.replaceAll(DockState(apps: [.spacer(.normal), .spacer(.normal), .spacer(.normal)]))],
            to: DockState()
        )

        #expect(calls.count == 4)
    }

    // MARK: - Refused items

    @Test(arguments: [
        DockItem.folder(FolderItem(path: "~/Downloads")),
        .folder(FolderItem(path: "relative/Downloads")),
        .file(FileItem(path: "~/a.txt")),
        .app(AppRef(bundleId: "com.example.x", name: "X", path: "X.app")),
        .app(AppRef(bundleId: "com.example.x", name: "X", path: nil)),
        .url(URLItem(url: URL(string: "file:///Users/me/a.txt")!)),
        .unknown(UnknownTile(tileType: "recents-tile")),
    ])
    func invalidItemsAreRefusedBeforeAnyCommand(item: DockItem) async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let backend = h.backend(reading: [DockState()])

        await #expect(throws: DockBackendError.self) {
            try await backend.apply([.insert(item, section: .others, index: 0)])
        }
        await #expect(throws: DockBackendError.self) {
            try await backend.apply([.replaceAll(DockState(others: [item]))])
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func indexOutOfRangeIsRefusedBeforeAnyCommand() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let backend = h.backend(reading: [DockState(apps: [calc])])

        await #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 5)) {
            try await backend.apply([.remove(section: .apps, index: 5)])
        }
        #expect(h.runner.calls.isEmpty)
    }

    // MARK: - Failures

    @Test func nonZeroExitIsCommandFailedWithStderrAndStopsTheBatch() async throws {
        let h = try FakeDockHarness { number, _ in
            number == 1
                ? ProcessResult(terminationStatus: 1, standardError: "Add failed for /x in /tmp/dock.plist\n")
                : ProcessResult(terminationStatus: 0, standardError: "")
        }
        defer { h.cleanup() }
        let backend = h.backend(reading: [DockState(apps: [calc]), DockState()])

        let error = await #expect(throws: DockBackendError.self) {
            try await backend.apply([
                .insert(notes, section: .apps, index: 0),
                .insert(calendar, section: .apps, index: 0),
                .insert(Sample.docs, section: .others, index: 0),
            ])
        }

        guard case let .commandFailed(message)? = error else {
            Issue.record("Expected commandFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("exited with status 1"))
        #expect(message.contains("Add failed for /x in /tmp/dock.plist"))
        #expect(message.contains("command 2 of 3"))
        #expect(h.runner.calls.count == 2)
    }

    @Test func launchFailureIsCommandFailed() async throws {
        let h = try FakeDockHarness { _, _ in throw ScriptedProcessRunner.LaunchError() }
        defer { h.cleanup() }
        let backend = h.backend(reading: [DockState()])

        let error = await #expect(throws: DockBackendError.self) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }

        guard case let .commandFailed(message)? = error else {
            Issue.record("Expected commandFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Could not run dockutil"))
    }

    @Test func mismatchAfterZeroExitIsVerificationFailed() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let before = DockState(apps: [notes])
        // dockutil "succeeded" (exit 0) but the plist never changed.
        let backend = h.backend(reading: [before, before])

        await #expect(
            throws: DockBackendError.verificationFailed(
                expected: DockState(apps: [calc, notes]),
                actual: before
            )
        ) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }
        #expect(h.runner.calls.count == 1)
    }

    @Test func extraItemAfterWriteIsVerificationFailed() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let backend = h.backend(reading: [
            DockState(apps: [notes]),
            DockState(apps: [calc, notes, .spacer(.small)]),
        ])

        await #expect(throws: DockBackendError.self) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }
    }

    @Test func readFailureBeforeWritingRunsNothing() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let backend = DockutilBackend(
            dockutilURL: h.dockutil,
            target: .file(h.plist),
            runner: h.runner,
            reader: { throw DockReadError.unreadableFile("/nope") },
            liveDockPlistURLs: { [] }
        )

        await #expect(throws: DockReadError.unreadableFile("/nope")) {
            try await backend.apply([.insert(calc, section: .apps, index: 0)])
        }
        #expect(h.runner.calls.isEmpty)
    }

    @Test func readReturnsTheReadersState() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let state = DockState(apps: [calc], others: [Sample.example])

        #expect(try await h.backend(reading: [state]).read() == state)
        #expect(h.runner.calls.isEmpty)
    }

    // MARK: - Location argument

    @Test func locationIsTheCanonicalPathEvenWhenGivenThroughASymlinkAndDotDot() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }
        let sub = h.directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = h.directory.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.plist)
        let indirect = sub.appendingPathComponent("../link.plist")
        let after = DockState(apps: [calc])
        let sequence = StateSequence([DockState(), after])
        let backend = DockutilBackend(
            dockutilURL: h.dockutil,
            target: .file(indirect),
            runner: h.runner,
            reader: { sequence.next() },
            liveDockPlistURLs: { [] }
        )

        try await backend.apply([.insert(calc, section: .apps, index: 0)])

        #expect(h.runner.argumentLists.first?.last == h.location)
        #expect(h.runner.argumentLists.first?.dropLast().last == "--no-restart")
    }

    @Test func everyCommandEndsWithNoRestartAndTheLocation() async throws {
        let h = try FakeDockHarness()
        defer { h.cleanup() }

        let calls = try await h.apply(
            [.replaceAll(DockState(apps: [calc, notes], others: [Sample.docs]))],
            to: DockState()
        )

        #expect(!calls.isEmpty)
        for arguments in calls {
            #expect(Array(arguments.suffix(2)) == ["--no-restart", h.location])
            #expect(arguments.filter { $0 == "--no-restart" }.count == 1)
            #expect(!arguments.contains { $0.hasPrefix("~") })
        }
    }
}
