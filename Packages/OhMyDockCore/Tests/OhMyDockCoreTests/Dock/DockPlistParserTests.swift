import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockPlistParserTests {
    private let noop: @Sendable (URL) -> String? = { _ in nil }

    // MARK: Apps and files

    @Test func barePathAppUsesResolver() {
        let tile = fileTile(path: "/System/Applications/Calculator.app", stringType: 0, label: "Calculator")
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: { url in
            #expect(url == URL(fileURLWithPath: "/System/Applications/Calculator.app"))
            return "com.apple.calculator"
        })
        #expect(item == .app(AppRef(
            bundleId: "com.apple.calculator",
            name: "Calculator",
            path: "/System/Applications/Calculator.app"
        )))
    }

    @Test func fileURLAppDecodesAndStripsTrailingSlash() {
        let tile = fileTile(
            path: "file:///Applications/My%20App.app/",
            stringType: 15,
            label: "My App"
        )
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: { url in
            #expect(url.path == "/Applications/My App.app")
            return "com.example.my-app"
        })
        #expect(item == .app(AppRef(
            bundleId: "com.example.my-app",
            name: "My App",
            path: "/Applications/My App.app"
        )))
    }

    @Test func presentBundleIdentifierSkipsResolver() {
        let tile = fileTile(
            path: "file:///System/Applications/Messages.app/",
            stringType: 15,
            label: "Messages",
            bundleIdentifier: "com.apple.MobileSMS"
        )
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: { _ in
            "sentinel"
        })
        #expect(item == .app(AppRef(
            bundleId: "com.apple.MobileSMS",
            name: "Messages",
            path: "/System/Applications/Messages.app"
        )))
    }

    @Test func bundleIdentifierMakesNonAppPathAnApp() {
        let tile = fileTile(
            path: "/opt/tools/helper",
            stringType: 0,
            label: "Helper",
            bundleIdentifier: "com.example.helper"
        )
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: { _ in "sentinel" })
        #expect(item == .app(AppRef(bundleId: "com.example.helper", name: "Helper", path: "/opt/tools/helper")))
    }

    @Test func bundleIdentifierWithoutPathStillParses() {
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": ["bundle-identifier": "com.example.app"],
        ]
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .app(AppRef(bundleId: "com.example.app", name: "")))
    }

    @Test func unresolvableBundleIdentifierKeepsPath() {
        let tile = fileTile(path: "/Applications/Missing.app", stringType: 0, label: "Missing")
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .app(AppRef(bundleId: "", name: "Missing", path: "/Applications/Missing.app")))
    }

    @Test func emptyBundleIdentifierFallsThroughToResolver() {
        let tile = fileTile(
            path: "/Applications/Missing.app",
            stringType: 0,
            label: "Missing",
            bundleIdentifier: ""
        )
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: { _ in nil })
        #expect(item == .app(AppRef(bundleId: "", name: "Missing", path: "/Applications/Missing.app")))
    }

    @Test func missingAppLabelUsesFileName() {
        let tile = fileTile(path: "/Applications/Calculator.app", stringType: 0)
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .app(AppRef(bundleId: "", name: "Calculator", path: "/Applications/Calculator.app")))
    }

    @Test func plainFileIsNotAnApp() {
        let tile = fileTile(path: "/Users/tester/plain-file.txt", stringType: 0, label: "plain-file.txt")
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: { _ in "sentinel" })
        #expect(item == .file(FileItem(path: "/Users/tester/plain-file.txt", label: "plain-file.txt")))
    }

    @Test func barePathDoesNotPercentDecode() {
        let tile = fileTile(path: "/Users/tester/My%20File.txt", stringType: 0, label: "Literal")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .file(FileItem(path: "/Users/tester/My%20File.txt", label: "Literal")))
    }

    @Test func fileURLDecodesPercentEncoding() {
        let tile = fileTile(path: "file:///Users/tester/Notes%20File.txt", stringType: 15, label: "Notes File")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .file(FileItem(path: "/Users/tester/Notes File.txt", label: "Notes File")))
    }

    @Test func fileURLStripsDotSegments() {
        let tile = fileTile(path: "file:///Users/tester/../tester/Downloads/", stringType: 15, label: "Downloads")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .file(FileItem(path: "/Users/tester/Downloads", label: "Downloads")))
    }

    @Test func relativePathIsUnknown() {
        let tile = fileTile(path: "Applications/Foo.app", stringType: 0, label: "Foo")
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "file-tile", label: "Foo")))
    }

    @Test func nonFileURLOnFileTileIsUnknown() {
        let tile = fileTile(path: "https://example.com/App.app", stringType: 15, label: "App")
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "file-tile", label: "App")))
    }

    // MARK: Folders

    @Test(arguments: [
        (0, FolderView.auto),
        (1, FolderView.fan),
        (2, FolderView.grid),
        (3, FolderView.list),
    ])
    func mapsShowas(raw: Int, view: FolderView) {
        let item = folder(showas: raw, displayas: 1, arrangement: 1)
        #expect(item == .folder(FolderItem(path: "/Users/tester/Downloads", view: view, display: .folder, sort: .name, label: "Downloads")))
    }

    @Test(arguments: [
        (0, FolderDisplay.stack),
        (1, FolderDisplay.folder),
    ])
    func mapsDisplayas(raw: Int, display: FolderDisplay) {
        let item = folder(showas: 2, displayas: raw, arrangement: 1)
        #expect(item == .folder(FolderItem(path: "/Users/tester/Downloads", view: .grid, display: display, sort: .name, label: "Downloads")))
    }

    @Test(arguments: [
        (1, FolderSort.name),
        (2, FolderSort.dateAdded),
        (3, FolderSort.dateModified),
        (4, FolderSort.dateCreated),
        (5, FolderSort.kind),
    ])
    func mapsArrangement(raw: Int, sort: FolderSort) {
        let item = folder(showas: 2, displayas: 1, arrangement: raw)
        #expect(item == .folder(FolderItem(path: "/Users/tester/Downloads", view: .grid, display: .folder, sort: sort, label: "Downloads")))
    }

    @Test func folderFileURLDecodesPath() {
        let tile = directoryTile(
            path: "file:///Users/tester/My%20Documents/",
            stringType: 15,
            label: "My Documents",
            showas: 1,
            displayas: 0,
            arrangement: 5
        )
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .folder(FolderItem(
            path: "/Users/tester/My Documents",
            view: .fan,
            display: .stack,
            sort: .kind,
            label: "My Documents"
        )))
    }

    @Test func unrecognizedFolderIntIsUnknown() {
        let tile = directoryTile(path: "/Users/tester/Downloads", stringType: 0, label: "Downloads", showas: 9, displayas: 1, arrangement: 1)
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "directory-tile", label: "Downloads")))
    }

    @Test(arguments: ["showas", "displayas", "arrangement"])
    func missingFolderIntTakesTheDefault(_ key: String) throws {
        var tile = directoryTile(path: "/Users/tester/Downloads", stringType: 0, label: "Downloads", showas: 2, displayas: 1, arrangement: 3)
        var data = try #require(tile["tile-data"] as? [String: Any])
        data.removeValue(forKey: key)
        tile["tile-data"] = data
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        var expected = FolderItem(path: "/Users/tester/Downloads", view: .grid, display: .folder, sort: .dateModified, label: "Downloads")
        switch key {
        case "showas": expected.view = .auto
        case "displayas": expected.display = .stack
        default: expected.sort = .name
        }
        #expect(item == .folder(expected))
    }

    @Test func folderWithNoOptionsIsAutoStackName() throws {
        var tile = directoryTile(path: "/Users/tester/Downloads", stringType: 0, label: nil, showas: 0, displayas: 0, arrangement: 1)
        var data = try #require(tile["tile-data"] as? [String: Any])
        for key in ["showas", "displayas", "arrangement"] { data.removeValue(forKey: key) }
        tile["tile-data"] = data
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .folder(FolderItem(path: "/Users/tester/Downloads", view: .auto, display: .stack, sort: .name)))
    }

    @Test func folderIntOfTheWrongTypeIsStillUnknown() throws {
        var tile = directoryTile(path: "/Users/tester/Downloads", stringType: 0, label: "Downloads", showas: 2, displayas: 1, arrangement: 1)
        var data = try #require(tile["tile-data"] as? [String: Any])
        data["showas"] = "grid"
        tile["tile-data"] = data
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "directory-tile", label: "Downloads")))
    }

    // MARK: URLs and spacers

    @Test func urlTileKeepsLabel() {
        let tile = urlTile("https://example.com", label: "Example")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .url(URLItem(url: URL(string: "https://example.com")!, label: "Example")))
    }

    @Test func urlTileWithoutLabel() {
        let tile = urlTile("https://example.com/docs/")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .url(URLItem(url: URL(string: "https://example.com/docs/")!)))
    }

    @Test func emptyLabelsParseAsNoLabel() {
        let url = urlTile("https://example.com", label: "")
        #expect(DockPlistParser.parseTile(url, section: .others, resolvingBundleIdentifier: noop)
            == .url(URLItem(url: URL(string: "https://example.com")!)))

        // An empty `label` does not hide the `file-label`.
        let both: [String: Any] = [
            "tile-type": "url-tile",
            "tile-data": [
                "label": "",
                "file-label": "Docs",
                "url": ["_CFURLString": "https://example.com/docs", "_CFURLStringType": 15],
            ],
        ]
        #expect(DockPlistParser.parseTile(both, section: .others, resolvingBundleIdentifier: noop)
            == .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "Docs")))

        let folder = directoryTile(path: "/Users/tester/Downloads", stringType: 0, label: "", showas: 0, displayas: 0, arrangement: 1)
        #expect(DockPlistParser.parseTile(folder, section: .others, resolvingBundleIdentifier: noop)
            == .folder(FolderItem(path: "/Users/tester/Downloads")))

        let unknown: [String: Any] = ["tile-type": "mystery-tile", "tile-data": ["file-label": ""]]
        #expect(DockPlistParser.parseTile(unknown, section: .others, resolvingBundleIdentifier: noop)
            == .unknown(UnknownTile(tileType: "mystery-tile")))
    }

    @Test func urlTileFallsBackToFileLabel() {
        let tile: [String: Any] = [
            "tile-type": "url-tile",
            "tile-data": [
                "file-label": "Docs",
                "url": ["_CFURLString": "https://example.com/docs", "_CFURLStringType": 15],
            ],
        ]
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "Docs")))
    }

    @Test func malformedURLIsUnknown() {
        let tile = urlTile("not a url", label: "Broken")
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "url-tile", label: "Broken")))
    }

    @Test(arguments: [
        ("spacer-tile", SpacerKind.normal),
        ("small-spacer-tile", SpacerKind.small),
        ("flex-spacer-tile", SpacerKind.flex),
    ])
    func mapsSpacer(tileType: String, kind: SpacerKind) {
        let tile: [String: Any] = ["tile-type": tileType, "tile-data": [String: Any](), "GUID": 1]
        #expect(DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop) == .spacer(kind))
        #expect(DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop) == .spacer(kind))
    }

    // MARK: Malformed tiles stay in the list

    @Test func unknownTileTypeKeepsLabel() {
        let tile: [String: Any] = [
            "tile-type": "recents-tile",
            "tile-data": ["file-label": "Recent Applications"],
        ]
        let item = DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "recents-tile", label: "Recent Applications")))
    }

    @Test func missingTileTypeIsUnknown() {
        let tile: [String: Any] = ["tile-data": ["file-label": "Mystery"]]
        let item = DockPlistParser.parseTile(tile, section: .apps, resolvingBundleIdentifier: noop)
        #expect(item == .unknown(UnknownTile(tileType: "", label: "Mystery")))
    }

    @Test func malformedTileIsKeptBetweenNeighbors() {
        let domain: [String: Any] = [
            "persistent-apps": [
                fileTile(path: "/Applications/A.app", stringType: 0, label: "A", bundleIdentifier: "a.a"),
                ["tile-type": "file-tile", "tile-data": "bad"],
                "not-a-tile",
                ["no-type": true],
            ],
        ]
        let state = DockPlistParser.parse(domain: domain, resolvingBundleIdentifier: noop)
        #expect(state.apps == [
            .app(AppRef(bundleId: "a.a", name: "A", path: "/Applications/A.app")),
            .unknown(UnknownTile(tileType: "file-tile")),
            .unknown(UnknownTile(tileType: "")),
            .unknown(UnknownTile(tileType: "")),
        ])
        #expect(state.others.isEmpty)
    }

    @Test func missingSectionsAreEmpty() {
        #expect(DockPlistParser.parse(domain: [:], resolvingBundleIdentifier: noop) == DockState())
    }

    @Test func nonArraySectionIsEmpty() {
        let state = DockPlistParser.parse(domain: ["persistent-apps": "nope"], resolvingBundleIdentifier: noop)
        #expect(state == DockState())
    }

    @Test func parsesNestedPropertyListObjects() {
        let fileData: NSDictionary = [
            "_CFURLString": "file:///Applications/Nested.app/",
            "_CFURLStringType": NSNumber(value: 15),
        ]
        let data: NSDictionary = [
            "file-data": fileData,
            "file-label": "Nested",
            "bundle-identifier": "com.example.nested",
        ]
        let appTile: NSDictionary = ["tile-type": "file-tile", "tile-data": data, "GUID": NSNumber(value: 42)]
        let spacer: NSDictionary = ["tile-type": "small-spacer-tile", "tile-data": NSDictionary()]
        let domain: [String: Any] = [
            "persistent-apps": NSArray(objects: appTile, spacer),
            "persistent-others": NSArray(),
        ]
        let state = DockPlistParser.parse(domain: domain, resolvingBundleIdentifier: { _ in "sentinel" })
        #expect(state.apps == [
            .app(AppRef(bundleId: "com.example.nested", name: "Nested", path: "/Applications/Nested.app")),
            .spacer(.small),
        ])
        #expect(state.others.isEmpty)
    }

    // MARK: Builders

    private func fileTile(
        path: String,
        stringType: Int,
        label: String? = nil,
        bundleIdentifier: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [
            "file-data": [
                "_CFURLString": path,
                "_CFURLStringType": stringType,
            ],
        ]
        if let label { data["file-label"] = label }
        if let bundleIdentifier { data["bundle-identifier"] = bundleIdentifier }
        return ["tile-type": "file-tile", "tile-data": data, "GUID": 1]
    }

    private func directoryTile(
        path: String,
        stringType: Int,
        label: String?,
        showas: Int,
        displayas: Int,
        arrangement: Int
    ) -> [String: Any] {
        var data: [String: Any] = [
            "file-data": ["_CFURLString": path, "_CFURLStringType": stringType],
            "showas": showas,
            "displayas": displayas,
            "arrangement": arrangement,
        ]
        if let label { data["file-label"] = label }
        return ["tile-type": "directory-tile", "tile-data": data]
    }

    private func folder(showas: Int, displayas: Int, arrangement: Int) -> DockItem {
        let tile = directoryTile(
            path: "/Users/tester/Downloads",
            stringType: 0,
            label: "Downloads",
            showas: showas,
            displayas: displayas,
            arrangement: arrangement
        )
        return DockPlistParser.parseTile(tile, section: .others, resolvingBundleIdentifier: noop)
    }

    private func urlTile(_ url: String, label: String? = nil) -> [String: Any] {
        var data: [String: Any] = [
            "url": ["_CFURLString": url, "_CFURLStringType": 15],
        ]
        if let label { data["label"] = label }
        return ["tile-type": "url-tile", "tile-data": data]
    }
}

@Suite struct DockPlistReaderTests {
    @Test func readsDockutilFixture() throws {
        let url = try fixture("dockutil-tiles")
        let state = try DockPlistReader(.file(url), resolvingBundleIdentifier: { resolved in
            #expect(resolved.path == "/System/Applications/Calculator.app")
            return "com.apple.calculator"
        }).read()
        #expect(state == DockState(
            apps: [
                .app(AppRef(
                    bundleId: "com.apple.calculator",
                    name: "Calculator",
                    path: "/System/Applications/Calculator.app"
                )),
                .spacer(.normal),
                .spacer(.small),
                .spacer(.flex),
            ],
            others: [
                .url(URLItem(url: URL(string: "https://example.com")!, label: "Example")),
                .folder(FolderItem(
                    path: "/Users/tester/Downloads",
                    view: .grid,
                    display: .folder,
                    sort: .dateAdded,
                    label: "Downloads"
                )),
                .folder(FolderItem(
                    path: "/Users/tester/FanFolder",
                    view: .fan,
                    display: .stack,
                    sort: .name,
                    label: "FanFolder"
                )),
                .file(FileItem(path: "/Users/tester/plain-file.txt", label: "plain-file.txt")),
            ]
        ))
    }

    @Test func readsFileURLFixture() throws {
        let url = try fixture("macos-file-url-tiles")
        let state = try DockPlistReader(.file(url), resolvingBundleIdentifier: { resolved in
            resolved.path == "/Applications/My App.app" ? "com.example.my-app" : "sentinel"
        }).read()
        #expect(state == DockState(
            apps: [
                .app(AppRef(
                    bundleId: "com.apple.MobileSMS",
                    name: "Messages",
                    path: "/System/Applications/Messages.app"
                )),
                .app(AppRef(
                    bundleId: "com.example.my-app",
                    name: "My App",
                    path: "/Applications/My App.app"
                )),
                .unknown(UnknownTile(tileType: "file-tile")),
            ],
            others: [
                .folder(FolderItem(
                    path: "/Users/tester/My Documents",
                    view: .fan,
                    display: .stack,
                    sort: .kind,
                    label: "My Documents"
                )),
                .file(FileItem(path: "/Users/tester/Notes File.txt", label: "Notes File")),
                .unknown(UnknownTile(tileType: "recents-tile", label: "Recent Applications")),
                .unknown(UnknownTile(tileType: "", label: "Mystery")),
            ]
        ))
    }

    @Test func defaultResolverReadsBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyDockCoreTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Widget.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "app.ohmydock.widget", "CFBundleName": "Widget"]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = root.appendingPathComponent("dock.plist")
        let domain: [String: Any] = [
            "persistent-apps": [[
                "tile-type": "file-tile",
                "tile-data": [
                    "file-label": "Widget",
                    "file-data": [
                        "_CFURLString": app.path,
                        "_CFURLStringType": 0,
                    ],
                ],
            ]],
            "persistent-others": [Any](),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        try data.write(to: plist)

        let state = try DockPlistReader(.file(plist)).read()
        #expect(state.apps == [
            .app(AppRef(bundleId: "app.ohmydock.widget", name: "Widget", path: app.path)),
        ])
    }

    @Test func readsThroughSymlinkAndDotDots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyDockCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("dock.plist")
        let domain: [String: Any] = [
            "persistent-apps": [["tile-type": "flex-spacer-tile", "tile-data": [String: Any]()]],
            "persistent-others": [Any](),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        try data.write(to: real)
        let link = root.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let dotted = root
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("..")
            .appendingPathComponent("dock.plist")

        let expected = DockState(apps: [.spacer(.flex)])
        #expect(try DockPlistReader(.file(link), resolvingBundleIdentifier: { _ in nil }).read() == expected)
        #expect(try DockPlistReader(.file(dotted), resolvingBundleIdentifier: { _ in nil }).read() == expected)
    }

    @Test func missingFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/oh-my-dock-missing-\(UUID().uuidString).plist")
        #expect(throws: DockReadError.unreadableFile(url.resolvingSymlinksInPath().standardized.path(percentEncoded: false))) {
            try DockPlistReader(.file(url)).read()
        }
    }

    @Test func invalidPlistThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyDockCoreTests-\(UUID().uuidString).plist")
        try Data("not a plist".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DockReadError.unreadableFile(url.resolvingSymlinksInPath().standardized.path(percentEncoded: false))) {
            try DockPlistReader(.file(url)).read()
        }
    }

    @Test func nonDictionaryPlistThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyDockCoreTests-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dict"], format: .xml, options: 0)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DockReadError.self) {
            try DockPlistReader(.file(url)).read()
        }
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"))
    }
}
