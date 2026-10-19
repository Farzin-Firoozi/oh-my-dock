import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct ProfileExchangeTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func importProfile(_ data: Data) throws -> SanitizedProfile {
        try ProfileExchange.importProfile(from: data, homeDirectory: home)
    }

    // MARK: - Export

    @Test func exportWrapsProfileJSONData() throws {
        let profile = Self.safeProfile
        let data = try ProfileExchange.export(profile)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == Self.envelope(around: try profile.jsonData()))
        #expect(try ProfileExchange.export(profile) == data)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "profile", "version"])
        #expect(object["format"] as? String == ProfileExchange.formatIdentifier)
        #expect(object["version"] as? Int == ProfileExchange.currentVersion)
        let profileObject = try #require(object["profile"])
        let reencoded = try JSONSerialization.data(withJSONObject: profileObject)
        #expect(try Profile(jsonData: reencoded) == profile)
    }

    @Test func exportKeepsUnsafeFieldsForTheImporterToStrip() throws {
        let profile = ModelTestSupport.sampleProfile()
        let data = try ProfileExchange.export(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profileObject = try JSONSerialization.data(withJSONObject: try #require(object["profile"]))
        let decoded = try Profile(jsonData: profileObject)
        #expect(decoded == profile)
        #expect(decoded.switching.quitScope == .allNotInProfile)
    }

    // MARK: - Round trip and sanitizer

    @Test func roundTripPreservesAGallerySafeProfileExceptID() throws {
        let original = Self.safeProfile
        let imported = try importProfile(ProfileExchange.export(original))
        #expect(imported.changes == [.idReassigned])
        #expect(imported.profile.id != original.id)
        var expected = original
        expected.id = imported.profile.id
        #expect(imported.profile == expected)
    }

    @Test func importAlwaysSanitizes() throws {
        let original = ModelTestSupport.sampleProfile()
        let imported = try importProfile(ProfileExchange.export(original))
        let direct = try original.sanitizedForImport(homeDirectory: home)
        #expect(imported.changes == direct.changes)
        #expect(Self.normalizingID(imported.profile) == Self.normalizingID(direct.profile))

        #expect(imported.changes.contains(.idReassigned))
        #expect(imported.changes.contains(.forcedQuitScopeNone(was: .allNotInProfile)))
        #expect(imported.changes.contains(.clearedLaunchOnSwitch(.apps, index: 0)))
        #expect(imported.changes.contains(.clearedAppPath(.apps, index: 0)))
        #expect(imported.profile.switching.quitScope == .none)
        #expect(imported.profile.switching.offerForceQuit == false)
        guard case .app(let app) = imported.profile.apps[0] else {
            Issue.record("expected the Figma app to survive")
            return
        }
        #expect(app.bundleId == "com.figma.Desktop")
        #expect(app.path == nil)
        #expect(app.launchOnSwitch == false)
    }

    @Test func minimalDocumentForcesQuitScopeOff() throws {
        let imported = try importProfile(Self.document(profile: Self.minimalProfileJSON))
        #expect(imported.changes == [
            .idReassigned,
            .forcedQuitScopeNone(was: .previousProfileApps),
        ])
        #expect(imported.profile.name == "Minimal")
        #expect(imported.profile.apps.isEmpty)
        #expect(imported.profile.switching.quitScope == .none)
        #expect(imported.profile.switching.offerForceQuit == false)
    }

    @Test func dropsEveryTileInsteadOfReturningAnEmptyDock() {
        let data = Self.document(profile: """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":1,
         "others":[{"type":"url","url":"http://plain.example.com"}]}
        """)
        #expect(throws: ProfileExchangeError.sanitization(.everyTileDropped(changes: [
            .idReassigned,
            .droppedItem(.others, index: 0, reason: .disallowedURL),
        ]))) {
            try importProfile(data)
        }
    }

    @Test func rejectsAProfileThatIsStillInvalidAfterSanitizing() {
        #expect(throws: ProfileExchangeError.sanitization(.invalidProfile(.emptyName))) {
            try importProfile(Self.document(profile: """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":" ","schemaVersion":1}
            """))
        }
        #expect(throws: ProfileExchangeError.sanitization(.invalidProfile(
            .invalidPrefs(.outOfRange(.tileSize, value: -1, allowed: 16...128))
        ))) {
            try importProfile(Self.document(profile: """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":1,
             "prefs":{"tileSize":-1}}
            """))
        }
    }

    // MARK: - Schema

    @Test func rejectsOversizedInputBeforeParsing() {
        let maximum = ProfileExchange.maximumDocumentBytes
        var data = Data(#"{"version":2}"#.utf8)
        data.append(Data(count: maximum))
        #expect(throws: ProfileExchangeError.tooLarge(bytes: data.count, maximum: maximum)) {
            try importProfile(data)
        }
    }

    @Test func documentAtTheSizeCapIsParsed() {
        let data = Data(repeating: 0x20, count: ProfileExchange.maximumDocumentBytes)
        #expect(throws: ProfileExchangeError.malformed) {
            try importProfile(data)
        }
    }

    @Test(arguments: ["", "{", "[]", "null", "\"hi\"", "{\"version\":"])
    func rejectsMalformedJSON(text: String) {
        #expect(throws: ProfileExchangeError.malformed) {
            try importProfile(Data(text.utf8))
        }
    }

    @Test func rejectsAVersionThatIsNotAnInteger() {
        #expect(throws: ProfileExchangeError.malformed) {
            try importProfile(Data(#"{"format":"oh-my-dock-profile","version":"1","profile":{}}"#.utf8))
        }
    }

    @Test(arguments: [0, 2, -1])
    func rejectsOldAndFutureVersions(version: Int) {
        let json = """
        {"format":"oh-my-dock-profile","version":\(version),"profile":{"not":"decoded"},"extra":true}
        """
        #expect(throws: ProfileExchangeError.unsupportedVersion(found: version, supported: 1)) {
            try importProfile(Data(json.utf8))
        }
    }

    @Test func rejectsAnUnknownFormatBeforeUnknownKeys() {
        let json = """
        {"format":"dock-profile","version":1,"profile":{},"extra":true}
        """
        #expect(throws: ProfileExchangeError.unsupportedFormat(found: "dock-profile")) {
            try importProfile(Data(json.utf8))
        }
    }

    @Test func missingVersionWinsOverUnknownKeys() {
        let json = #"{"format":"oh-my-dock-profile","profile":{},"extra":1}"#
        #expect(throws: ProfileExchangeError.missingKey("version")) {
            try importProfile(Data(json.utf8))
        }
    }

    @Test func missingFormatAndProfileAreReported() throws {
        #expect(throws: ProfileExchangeError.missingKey("format")) {
            try importProfile(Data(#"{"version":1,"profile":{}}"#.utf8))
        }
        #expect(throws: ProfileExchangeError.missingKey("profile")) {
            try importProfile(Data(#"{"format":"oh-my-dock-profile","version":1}"#.utf8))
        }
    }

    @Test func rejectsUnknownEnvelopeKeys() {
        let json = """
        {"format":"oh-my-dock-profile","version":1,"profile":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":1},"author":"x","note":1}
        """
        #expect(throws: ProfileExchangeError.unknownKeys(["author", "note"])) {
            try importProfile(Data(json.utf8))
        }
    }

    @Test func rejectsUnknownKeysInsideTheProfile() {
        let data = Self.document(profile: """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":1,"note":"no"}
        """)
        do {
            _ = try importProfile(data)
            Issue.record("expected unknown keys")
        } catch ProfileExchangeError.profileDecoding(.unknownKeys(let keys, _)) {
            #expect(keys == ["note"])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(arguments: [0, 2])
    func rejectsOldAndFutureProfileSchemaVersions(schemaVersion: Int) {
        let data = Self.document(profile: """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":\(schemaVersion),"future":true}
        """)
        #expect(throws: ProfileExchangeError.profileDecoding(
            .unsupportedSchemaVersion(found: schemaVersion, supported: Profile.currentSchemaVersion)
        )) {
            try importProfile(data)
        }
    }

    @Test func rejectsAnUnknownTileType() {
        let data = Self.document(profile: """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"P","schemaVersion":1,
         "apps":[{"type":"widget"}]}
        """)
        do {
            _ = try importProfile(data)
            Issue.record("expected an unknown tile type")
        } catch ProfileExchangeError.profileDecoding(.unknownItemType(let type, _)) {
            #expect(type == "widget")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

extension ProfileExchangeTests {
    fileprivate static let safeProfile = Profile(
        id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
        name: "Work \"it's\" 文档",
        apps: [
            .app(AppRef(
                bundleId: "com.apple.Safari",
                name: "Safari",
                path: "/Users/me/Apps/Safari.app",
                brewCask: "safari"
            )),
            .spacer(.small),
        ],
        others: [
            .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "Docs")),
            .folder(FolderItem(path: "/Users/me/Downloads", view: .grid, display: .folder, sort: .dateAdded, label: "DL")),
            .file(FileItem(path: "/Users/me/notes.txt")),
        ],
        prefs: DockPrefs(tileSize: 48, autohide: true, minimizeEffect: .scale),
        switching: SwitchingOptions(quitScope: .none, launchHidden: true),
        hotkey: Hotkey(keyCode: 18, modifiers: [.command])
    )

    fileprivate static let minimalProfileJSON = """
    {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Minimal", "schemaVersion": 1}
    """

    fileprivate static func document(profile: String) -> Data {
        Data("""
        {"format":"oh-my-dock-profile","version":1,"profile":\(profile)}
        """.utf8)
    }

    /// The bytes `export` must produce: `profile.jsonData()` indented under `profile`.
    fileprivate static func envelope(around profileJSON: Data) -> String {
        var text = String(decoding: profileJSON, as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        let indented = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            index == 0 ? String(line) : "  " + line
        }.joined(separator: "\n")
        return """
        {
          "format" : "\(ProfileExchange.formatIdentifier)",
          "profile" : \(indented),
          "version" : \(ProfileExchange.currentVersion)
        }
        """ + "\n"
    }

    fileprivate static func normalizingID(_ profile: Profile) -> Profile {
        var copy = profile
        copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return copy
    }
}
