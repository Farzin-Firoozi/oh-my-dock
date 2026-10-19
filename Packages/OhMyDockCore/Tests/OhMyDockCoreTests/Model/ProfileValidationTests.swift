import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct ProfileValidationTests {
    private func profile(apps: [DockItem] = [], others: [DockItem] = [], prefs: DockPrefs? = nil) -> Profile {
        Profile(name: "P", apps: apps, others: others, prefs: prefs)
    }

    @Test func sampleProfileIsValid() throws {
        try ModelTestSupport.sampleProfile().validate()
    }

    @Test func emptyProfileIsValid() throws {
        try Profile(name: "Empty").validate()
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func rejectsEmptyName(_ name: String) {
        #expect(throws: ProfileValidationError.emptyName) { try Profile(name: name).validate() }
    }

    @Test func nameLengthLimit() throws {
        try Profile(name: String(repeating: "a", count: 100)).validate()
        #expect(throws: ProfileValidationError.nameTooLong(length: 101, maximum: 100)) {
            try Profile(name: String(repeating: "a", count: 101)).validate()
        }
    }

    @Test func nameLengthCountsCharacters() throws {
        try Profile(name: String(repeating: "👩‍💻", count: 100)).validate()
    }

    @Test(arguments: DockSection.allCases)
    func rejectsUnknownItems(_ section: DockSection) {
        let item = DockItem.unknown(UnknownTile(tileType: "recents-tile"))
        let profile = section == .apps ? profile(apps: [.spacer(.normal), item]) : profile(others: [item])
        let index = section == .apps ? 1 : 0
        #expect(throws: ProfileValidationError.unknownItem(section, index: index, tileType: "recents-tile")) {
            try profile.validate()
        }
    }

    @Test func rejectsTheSameAppTwiceInASection() {
        let app = DockItem.app(AppRef(bundleId: "a.b", name: "B", path: "/Applications/B.app"))
        #expect(throws: ProfileValidationError.duplicateLabel(.apps, index: 2, label: "B")) {
            try profile(apps: [app, .spacer(.normal), app]).validate()
        }
    }

    @Test func rejectsDifferentTilesWithTheSameLabel() {
        let folder = DockItem.folder(FolderItem(path: "/Users/me/Docs"))
        let file = DockItem.file(FileItem(path: "/Users/me/Other/Docs"))
        #expect(throws: ProfileValidationError.duplicateLabel(.others, index: 1, label: "Docs")) {
            try profile(others: [folder, file]).validate()
        }
        let first = DockItem.url(URLItem(url: URL(string: "https://a.example")!, label: "Site"))
        let second = DockItem.url(URLItem(url: URL(string: "https://b.example")!, label: "Site"))
        #expect(throws: ProfileValidationError.duplicateLabel(.others, index: 1, label: "Site")) {
            try profile(others: [first, second]).validate()
        }
    }

    @Test func appLabelComesFromThePathNotTheName() {
        let one = DockItem.app(AppRef(bundleId: "a.one", name: "Same", path: "/Applications/One.app"))
        let two = DockItem.app(AppRef(bundleId: "a.two", name: "Same", path: "/Applications/Two.app"))
        #expect(throws: Never.self) { try profile(apps: [one, two]).validate() }
    }

    @Test func spacersAndSameLabelsInDifferentSectionsAreFine() throws {
        let app = DockItem.app(AppRef(bundleId: "a.b", name: "Docs", path: "/Applications/Docs.app"))
        let folder = DockItem.folder(FolderItem(path: "/Users/me/Docs"))
        try profile(
            apps: [.spacer(.normal), .spacer(.normal), .spacer(.small), app],
            others: [folder]
        ).validate()
    }

    @Test(arguments: ["~/Downloads", "Downloads", "./Downloads", "/Users/me/../other", "/Users/./me", ""])
    func rejectsNonAbsoluteFolderPaths(_ path: String) {
        #expect(throws: ProfileValidationError.pathNotAbsolute(.others, index: 0, path: path)) {
            try profile(others: [.folder(FolderItem(path: path))]).validate()
        }
    }

    @Test(arguments: ["~/notes.txt", "notes.txt", "/a/../b"])
    func rejectsNonAbsoluteFilePaths(_ path: String) {
        #expect(throws: ProfileValidationError.pathNotAbsolute(.others, index: 0, path: path)) {
            try profile(others: [.file(FileItem(path: path))]).validate()
        }
    }

    @Test func rejectsRelativeAppPathHint() {
        let app = DockItem.app(AppRef(bundleId: "a.b", name: "B", path: "~/Applications/B.app"))
        #expect(throws: ProfileValidationError.pathNotAbsolute(.apps, index: 0, path: "~/Applications/B.app")) {
            try profile(apps: [app]).validate()
        }
    }

    @Test func acceptsAbsolutePaths() throws {
        try profile(
            apps: [.app(AppRef(bundleId: "", name: "B", path: "/Applications/B.app"))],
            others: [.folder(FolderItem(path: "/Users/me/My Folder/")), .file(FileItem(path: "/tmp/a~b.txt"))]
        ).validate()
    }

    @Test func rejectsAppWithoutBundleIdOrPath() {
        #expect(throws: ProfileValidationError.appMissingIdentity(.apps, index: 0)) {
            try profile(apps: [.app(AppRef(bundleId: "", name: "Ghost"))]).validate()
        }
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "vnc://host.local", "ftp://example.com",
        "x-apple.systempreferences:com.apple.Security", "https://", "relative/path",
    ])
    func rejectsUnsupportedURLs(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(throws: ProfileValidationError.unsupportedURLScheme(.others, index: 0, url: url.absoluteString)) {
            try profile(others: [.url(URLItem(url: url))]).validate()
        }
    }

    @Test(arguments: ["https://example.com", "http://example.com/path?q=1", "HTTPS://EXAMPLE.COM"])
    func acceptsHTTPURLs(_ string: String) throws {
        try profile(others: [.url(URLItem(url: URL(string: string)!))]).validate()
    }

    @Test func spacersAndAppsAllowedInBothSections() throws {
        let app = DockItem.app(AppRef(bundleId: "a.b", name: "B"))
        try profile(apps: [app, .spacer(.flex)], others: [app, .spacer(.small)]).validate()
    }

    @Test func wrapsPrefsErrors() {
        #expect(throws: ProfileValidationError.invalidPrefs(.outOfRange(.tileSize, value: 200, allowed: 16...128))) {
            try profile(prefs: DockPrefs(tileSize: 200)).validate()
        }
    }

    @Test func decodedButInvalidProfileFailsValidation() throws {
        let json = """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":1,
             "others":[{"type":"unknown","tileType":"recents-tile"}]}
            """
        let decoded = try Profile(jsonData: Data(json.utf8))
        #expect(throws: ProfileValidationError.unknownItem(.others, index: 0, tileType: "recents-tile")) {
            try decoded.validate()
        }
    }
}
