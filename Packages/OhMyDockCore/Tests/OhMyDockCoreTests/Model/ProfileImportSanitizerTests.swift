import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct ProfileImportSanitizerTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func sanitize(_ profile: Profile) throws -> SanitizedProfile {
        try profile.sanitizedForImport(homeDirectory: home)
    }

    private func https(_ string: String) -> DockItem {
        .url(URLItem(url: URL(string: string)!))
    }

    @Test func safeProfilePassesThroughApartFromFreshID() throws {
        let original = Profile(
            name: "Work",
            apps: [.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Users/me/Apps/Safari.app", brewCask: "safari")), .spacer(.small)],
            others: [
                https("https://example.com/docs"),
                .folder(FolderItem(path: "/Users/me/Downloads", label: "DL")),
                .file(FileItem(path: "/Users/me/notes.txt")),
            ],
            switching: SwitchingOptions(quitScope: .none, launchHidden: true),
            hotkey: Hotkey(keyCode: 18, modifiers: [.command])
        )
        let result = try sanitize(original)
        #expect(result.changes == [.idReassigned])
        #expect(result.profile.id != original.id)
        var expected = original
        expected.id = result.profile.id
        #expect(result.profile == expected)
    }

    @Test func onlyHTTPSURLsSurvive() throws {
        let profile = Profile(name: "P", others: [
            https("https://ok.example.com/a"),
            https("HTTPS://UPPER.example.com/"),
            https("http://plain.example.com"),
            https("file:///etc/passwd"),
            https("javascript:alert(1)"),
            https("https://user:pw@evil.example.com/"),
            https("https://user@evil.example.com/"),
            https("https:///nohost"),
            https("ftp://x.example.com"),
        ])
        let result = try sanitize(profile)
        #expect(result.profile.others.count == 2)
        let dropped = result.changes.compactMap { change -> Int? in
            if case .droppedItem(.others, let i, .disallowedURL) = change { return i }
            return nil
        }
        #expect(dropped == [2, 3, 4, 5, 6, 7, 8])
    }

    @Test func pathsMustBeUnderHome() throws {
        let profile = Profile(name: "P", others: [
            .folder(FolderItem(path: "/Users/me/Documents")),
            .folder(FolderItem(path: "/Users/me")),
            .folder(FolderItem(path: "/Users/mehack/Documents")),
            .folder(FolderItem(path: "/etc")),
            .file(FileItem(path: "/Users/me/../root/secret")),
            .file(FileItem(path: "~/notes.txt")),
            .file(FileItem(path: "relative/notes.txt")),
            .file(FileItem(path: "/Users/me/./a.txt")),
            .file(FileItem(path: "/Users/me/a.txt")),
        ])
        let result = try sanitize(profile)
        #expect(result.profile.others == [
            .folder(FolderItem(path: "/Users/me/Documents")),
            .file(FileItem(path: "/Users/me/a.txt")),
        ])
        let dropped = result.changes.compactMap { change -> Int? in
            if case .droppedItem(.others, let i, .disallowedPath) = change { return i }
            return nil
        }
        #expect(dropped == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func homeWithTrailingSlashWorks() throws {
        let profile = Profile(name: "P", others: [.folder(FolderItem(path: "/Users/me/x"))])
        let result = try profile.sanitizedForImport(homeDirectory: URL(fileURLWithPath: "/Users/me/"))
        #expect(result.profile.others.count == 1)
    }

    @Test func appPathOutsideHomeIsClearedAppKept() throws {
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.a", name: "A", path: "/Applications/A.app")),
            .app(AppRef(bundleId: "", name: "B", path: "/Applications/B.app")),
            .app(AppRef(bundleId: "", name: "C", path: "/Users/me/C.app")),
        ])
        let result = try sanitize(profile)
        #expect(result.profile.apps == [
            .app(AppRef(bundleId: "com.a", name: "A")),
            .app(AppRef(bundleId: "", name: "C", path: "/Users/me/C.app")),
        ])
        #expect(result.changes.contains(.clearedAppPath(.apps, index: 0)))
        #expect(result.changes.contains(.clearedAppPath(.apps, index: 1)))
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .missingAppIdentity)))
    }

    @Test func switchingIsDefanged() throws {
        let profile = Profile(
            name: "P",
            apps: [.app(AppRef(bundleId: "com.a", name: "A", launchOnSwitch: true))],
            switching: SwitchingOptions(quitScope: .allNotInProfile, launchHidden: true, offerForceQuit: true)
        )
        let result = try sanitize(profile)
        #expect(result.profile.switching == SwitchingOptions(quitScope: .none, launchHidden: true, offerForceQuit: false))
        #expect(result.profile.apps == [.app(AppRef(bundleId: "com.a", name: "A", launchOnSwitch: false))])
        #expect(result.changes.contains(.forcedQuitScopeNone(was: .allNotInProfile)))
        #expect(result.changes.contains(.clearedOfferForceQuit))
        #expect(result.changes.contains(.clearedLaunchOnSwitch(.apps, index: 0)))
    }

    @Test func previousProfileAppsScopeIsAlsoForcedToNone() throws {
        let result = try sanitize(Profile(name: "P", switching: SwitchingOptions(quitScope: .previousProfileApps)))
        #expect(result.profile.switching.quitScope == .none)
        #expect(result.changes.contains(.forcedQuitScopeNone(was: .previousProfileApps)))
    }

    @Test func unknownTilesAreStripped() throws {
        let profile = Profile(
            name: "P",
            apps: [.unknown(UnknownTile(tileType: "recents-tile")), .spacer(.normal)],
            others: [.unknown(UnknownTile(tileType: "x-tile", label: "X"))]
        )
        let result = try sanitize(profile)
        #expect(result.profile.apps == [.spacer(.normal)])
        #expect(result.profile.others.isEmpty)
        #expect(result.changes.contains(.droppedItem(.apps, index: 0, reason: .unknownTile)))
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .unknownTile)))
    }

    @Test func itemCountIsCappedPerSection() throws {
        let cap = Profile.maxImportItemsPerSection
        let others = (0..<(cap + 5)).map { DockItem.file(FileItem(path: "/Users/me/f\($0).txt")) }
        let result = try sanitize(Profile(name: "P", others: others))
        #expect(result.profile.others.count == cap)
        #expect(result.profile.others.last == others[cap - 1])
        #expect(result.changes.contains(.droppedItemsOverLimit(.others, dropped: 5)))
    }

    @Test func invalidTilesDoNotUseUpTheCap() throws {
        let cap = Profile.maxImportItemsPerSection
        var others = (0..<10).map { _ in DockItem.unknown(UnknownTile(tileType: "x")) }
        others += (0..<cap).map { DockItem.file(FileItem(path: "/Users/me/f\($0).txt")) }
        let result = try sanitize(Profile(name: "P", others: others))
        #expect(result.profile.others.count == cap)
        #expect(!result.changes.contains { if case .droppedItemsOverLimit = $0 { true } else { false } })
    }

    @Test func oversizedLocationsDropTheTile() throws {
        let longPath = "/Users/me/" + String(repeating: "a", count: Profile.maxImportLocationLength)
        let longURL = "https://example.com/" + String(repeating: "a", count: Profile.maxImportLocationLength)
        let result = try sanitize(Profile(name: "P", others: [
            .folder(FolderItem(path: longPath)),
            .file(FileItem(path: longPath)),
            https(longURL),
            .file(FileItem(path: "/Users/me/ok")),
        ]))
        #expect(result.profile.others == [.file(FileItem(path: "/Users/me/ok"))])
        for index in 0..<3 {
            #expect(result.changes.contains(.droppedItem(.others, index: index, reason: .stringTooLong)))
        }
    }

    @Test func oversizedLocationAtTheLimitIsKept() throws {
        let path = "/Users/me/" + String(repeating: "a", count: Profile.maxImportLocationLength - 10)
        #expect(path.count == Profile.maxImportLocationLength)
        let result = try sanitize(Profile(name: "P", others: [.file(FileItem(path: path))]))
        #expect(result.profile.others.count == 1)
    }

    @Test func oversizedTextIsShortenedOrDropped() throws {
        let long = String(repeating: "x", count: Profile.maxImportTextLength + 50)
        let result = try sanitize(Profile(
            name: String(repeating: "n", count: Profile.maxNameLength + 20),
            apps: [
                .app(AppRef(bundleId: "com.a", name: long)),
                .app(AppRef(bundleId: long, name: "Big id")),
            ],
            others: [.file(FileItem(path: "/Users/me/a", label: String(repeating: "y", count: Profile.maxImportTextLength + 50)))]
        ))
        #expect(result.profile.name.count == Profile.maxNameLength)
        #expect(result.profile.apps.count == 1)
        guard case .app(let app) = result.profile.apps[0] else { Issue.record("not an app"); return }
        #expect(app.name.count == Profile.maxImportTextLength)
        guard case .file(let file) = result.profile.others[0] else { Issue.record("not a file"); return }
        #expect(file.label?.count == Profile.maxImportTextLength)
        #expect(result.changes.contains(.truncatedString(field: "name")))
        #expect(result.changes.contains(.truncatedString(field: "app name")))
        #expect(result.changes.contains(.truncatedString(field: "label")))
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .stringTooLong)))
    }

    @Test func suspiciousCaskNamesAreCleared() throws {
        let casks = ["firefox", "homebrew/cask-versions/firefox-beta", "-evil", "a b", "x;rm", "../x", "UPPER", ""]
        let apps = casks.enumerated().map { DockItem.app(AppRef(bundleId: "com.a\($0.offset)", name: "A\($0.offset)", brewCask: $0.element)) }
        let result = try sanitize(Profile(name: "P", apps: apps))
        let kept: [String?] = result.profile.apps.map { item in
            if case .app(let a) = item { return a.brewCask }
            return nil
        }
        #expect(kept == ["firefox", "homebrew/cask-versions/firefox-beta", nil, nil, nil, nil, nil, nil])
        #expect(result.changes.filter { if case .clearedBrewCask = $0 { true } else { false } }.count == 6)
    }

    @Test func duplicateLabelsAfterSanitizingAreDropped() throws {
        // The first app's path is cleared, so both now label as "Same".
        let result = try sanitize(Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.a", name: "Same", path: "/Applications/Other.app")),
            .app(AppRef(bundleId: "com.b", name: "Same")),
        ]))
        #expect(result.profile.apps.count == 1)
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .duplicateLabel)))
    }

    @Test func resultAlwaysValidatesWithoutUnknownTiles() throws {
        let result = try sanitize(ModelTestSupport.sampleProfile())
        try result.profile.validate()
    }

    @Test func emptyNameThrows() {
        #expect(throws: ImportSanitizationError.invalidProfile(.emptyName)) {
            try sanitize(Profile(name: "   "))
        }
    }

    @Test func invalidPrefsThrow() {
        let profile = Profile(name: "P", prefs: DockPrefs(tileSize: -1))
        #expect(throws: ImportSanitizationError.self) { try sanitize(profile) }
    }

    @Test func inputIsNotMutatedAndIDIsFreshEachTime() throws {
        let original = Profile(name: "P", switching: SwitchingOptions(quitScope: .allNotInProfile))
        let a = try sanitize(original)
        let b = try sanitize(original)
        #expect(original.switching.quitScope == .allNotInProfile)
        #expect(a.profile.id != b.profile.id)
        #expect(a.profile.id != original.id)
    }

    @Test func symlinkOutOfHomeIsRejectedWhenThePathExists() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanitizer-\(UUID().uuidString)", isDirectory: true)
        let homeDir = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let inside = homeDir.appendingPathComponent("real", isDirectory: true)
        for dir in [homeDir, outside, inside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let escape = homeDir.appendingPathComponent("escape").path
        let fine = homeDir.appendingPathComponent("fine").path
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: fine, withDestinationPath: inside.path)

        let profile = Profile(name: "P", others: [
            .folder(FolderItem(path: escape)),
            .folder(FolderItem(path: fine)),
        ])
        let result = try profile.sanitizedForImport(homeDirectory: homeDir)

        #expect(result.profile.others == [.folder(FolderItem(path: fine))])
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .disallowedPath)))
    }

    @Test func pathBelowAnEscapingSymlinkIsRejectedEvenWhenItDoesNotExistYet() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanitizer-\(UUID().uuidString)", isDirectory: true)
        let homeDir = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let inside = homeDir.appendingPathComponent("real", isDirectory: true)
        for dir in [homeDir, outside, inside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let escape = homeDir.appendingPathComponent("escape").path
        let fine = homeDir.appendingPathComponent("fine").path
        let dangling = homeDir.appendingPathComponent("dangling").path
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: fine, withDestinationPath: inside.path)
        try FileManager.default.createSymbolicLink(
            atPath: dangling, withDestinationPath: outside.appendingPathComponent("gone").path
        )

        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.example.a", name: "A", path: escape + "/not-yet/A.app")),
        ], others: [
            .folder(FolderItem(path: escape + "/not-yet")),
            .folder(FolderItem(path: dangling)),
            .folder(FolderItem(path: fine + "/not-yet")),
            .folder(FolderItem(path: homeDir.path + "/plain/other-new")),
        ])
        let result = try profile.sanitizedForImport(homeDirectory: homeDir)

        #expect(result.profile.others == [
            .folder(FolderItem(path: fine + "/not-yet")),
            .folder(FolderItem(path: homeDir.path + "/plain/other-new")),
        ])
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .disallowedPath)))
        #expect(result.changes.contains(.droppedItem(.others, index: 1, reason: .disallowedPath)))
        #expect(result.changes.contains(.clearedAppPath(.apps, index: 0)))
    }

    @Test func dotDotThroughASymlinkIsAppliedToTheRealDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanitizer-\(UUID().uuidString)", isDirectory: true)
        let homeDir = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for dir in [homeDir, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let escape = homeDir.appendingPathComponent("escape").path
        let trick = homeDir.appendingPathComponent("trick").path
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: outside.path)
        // Lexically `escape/..` is home; really it is `base`, outside home.
        try FileManager.default.createSymbolicLink(atPath: trick, withDestinationPath: "escape/..")

        let profile = Profile(name: "P", others: [
            .folder(FolderItem(path: trick + "/not-yet")),
            .folder(FolderItem(path: homeDir.path + "/plain/new")),
        ])
        let result = try profile.sanitizedForImport(homeDirectory: homeDir)

        #expect(result.profile.others == [.folder(FolderItem(path: homeDir.path + "/plain/new"))])
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .disallowedPath)))
    }

    @Test func symlinkLoopsAreRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanitizer-\(UUID().uuidString)", isDirectory: true)
        let homeDir = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let loop = homeDir.appendingPathComponent("loop").path
        try FileManager.default.createSymbolicLink(atPath: loop, withDestinationPath: loop)

        let profile = Profile(name: "P", others: [
            .folder(FolderItem(path: loop + "/x")),
            .folder(FolderItem(path: homeDir.path + "/fine")),
        ])
        let result = try profile.sanitizedForImport(homeDirectory: homeDir)

        #expect(result.profile.others == [.folder(FolderItem(path: homeDir.path + "/fine"))])
    }

    @Test func byteLengthIsCappedAsWellAsCharacterCount() throws {
        // One grapheme, but over 1 KiB of UTF-8.
        let heavy = "e" + String(repeating: "\u{0301}", count: 600)
        #expect(heavy.count == 1 && heavy.utf8.count > 4 * Profile.maxImportTextLength)
        let heavyPath = "/Users/me/" + "e" + String(repeating: "\u{0301}", count: 2_100)
        let heavyName = String(repeating: "x", count: Profile.maxImportTextLength - 1) + heavy
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.example.a", name: heavyName)),
            .app(AppRef(bundleId: heavy, name: "B")),
        ], others: [
            .folder(FolderItem(path: heavyPath)),
        ])

        let result = try sanitize(profile)

        guard case let .app(kept)? = result.profile.apps.first else {
            Issue.record("Expected the first app to stay")
            return
        }
        #expect(kept.name.utf8.count <= 4 * Profile.maxImportTextLength)
        #expect(result.changes.contains(.truncatedString(field: "app name")))
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .stringTooLong)))
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .stringTooLong)))
    }

    // MARK: Collisions after shortening

    @Test func nameShortenedToAnotherTilesBundleIdIsDropped() throws {
        let id = String(repeating: "x", count: Profile.maxImportTextLength)
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: id, name: "Real")),
            .app(AppRef(bundleId: "com.example.evil", name: id + "tail")),
        ])

        let result = try sanitize(profile)

        #expect(result.profile.apps == [.app(AppRef(bundleId: id, name: "Real"))])
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .labelCollision)))
    }

    @Test func shortenedTileGoesEvenWhenItComesFirst() throws {
        let id = String(repeating: "x", count: Profile.maxImportTextLength)
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.example.evil", name: id + "tail")),
            .app(AppRef(bundleId: id, name: "Real")),
        ])

        let result = try sanitize(profile)

        #expect(result.profile.apps == [.app(AppRef(bundleId: id, name: "Real"))])
        #expect(result.changes.contains(.droppedItem(.apps, index: 0, reason: .labelCollision)))
    }

    @Test func labelsThatCollideAcrossSectionsAreDropped() throws {
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.example.docs", name: "Docs")),
        ], others: [
            .folder(FolderItem(path: "/Users/me/Documents", label: "Docs")),
            .folder(FolderItem(path: "/Users/me/Other", label: "com.example.docs")),
            .folder(FolderItem(path: "/Users/me/Fine")),
        ])

        let result = try sanitize(profile)

        #expect(result.profile.others == [.folder(FolderItem(path: "/Users/me/Fine"))])
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .duplicateLabel)))
        #expect(result.changes.contains(.droppedItem(.others, index: 1, reason: .labelCollision)))
    }

    @Test func namesShortenedToNothingDropTheirPathlessApps() throws {
        let heavy = "e" + String(repeating: "\u{0301}", count: 600)
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: "com.example.a", name: heavy)),
            .app(AppRef(bundleId: "com.example.b", name: heavy + "x")),
            .app(AppRef(bundleId: "com.example.c", name: "Fine")),
            .app(AppRef(bundleId: "com.example.d", name: "")),
        ])

        let result = try sanitize(profile)

        #expect(result.profile.apps == [
            .app(AppRef(bundleId: "com.example.c", name: "Fine")),
            .app(AppRef(bundleId: "com.example.d", name: "")),
        ])
        #expect(result.changes.contains(.droppedItem(.apps, index: 0, reason: .emptyLabel)))
        #expect(result.changes.contains(.droppedItem(.apps, index: 1, reason: .emptyLabel)))
    }

    @Test func overlongBundleIdsAndPathsAreDroppedNotShortened() throws {
        let long = String(repeating: "x", count: Profile.maxImportTextLength + 1)
        let longPath = "/Users/me/" + String(repeating: "p", count: Profile.maxImportLocationLength)
        let profile = Profile(name: "P", apps: [
            .app(AppRef(bundleId: long, name: "A")),
            .app(AppRef(bundleId: "com.example.b", name: "B", path: longPath)),
        ], others: [.folder(FolderItem(path: longPath))])

        let result = try sanitize(profile)

        #expect(result.profile.apps == [.app(AppRef(bundleId: "com.example.b", name: "B"))])
        #expect(result.profile.others.isEmpty)
        #expect(result.changes.contains(.droppedItem(.apps, index: 0, reason: .stringTooLong)))
        #expect(result.changes.contains(.clearedAppPath(.apps, index: 1)))
        #expect(result.changes.contains(.droppedItem(.others, index: 0, reason: .stringTooLong)))
    }

    @Test func profileWhoseEveryTileIsDroppedThrows() throws {
        let profile = Profile(name: "P", apps: [
            .unknown(UnknownTile(tileType: "recents-tile")),
        ], others: [
            .folder(FolderItem(path: "/etc")),
        ])

        do {
            _ = try sanitize(profile)
            Issue.record("Expected everyTileDropped")
        } catch {
            guard let error = error as? ImportSanitizationError, case let .everyTileDropped(changes) = error else {
                Issue.record("Expected everyTileDropped, got \(error)")
                return
            }
            #expect(changes.contains(.droppedItem(.apps, index: 0, reason: .unknownTile)))
            #expect(changes.contains(.droppedItem(.others, index: 0, reason: .disallowedPath)))
        }
    }

    @Test func emptyProfileIsStillSanitized() throws {
        let result = try sanitize(Profile(name: "P"))
        #expect(result.profile.apps.isEmpty && result.profile.others.isEmpty)
    }
}
