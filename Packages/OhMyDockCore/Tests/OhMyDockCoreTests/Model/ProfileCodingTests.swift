import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct ProfileCodingTests {
    static let minimalJSON = """
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Minimal", "schemaVersion": 1}
        """

    @Test func roundTripsFullProfile() throws {
        let profile = ModelTestSupport.sampleProfile()
        #expect(try Profile(jsonData: profile.jsonData()) == profile)
    }

    @Test func roundTripsMinimalProfile() throws {
        let profile = Profile(name: "Empty")
        #expect(try Profile(jsonData: profile.jsonData()) == profile)
    }

    @Test func encodingIsDeterministic() throws {
        let profile = ModelTestSupport.sampleProfile()
        #expect(try profile.jsonData() == profile.jsonData())
    }

    @Test func jsonShape() throws {
        let object = try ModelTestSupport.jsonObject(ModelTestSupport.sampleProfile())
        #expect(Set(object.keys) == ["id", "name", "schemaVersion", "apps", "others", "prefs", "switching", "hotkey"])
        #expect(object["id"] as? String == ModelTestSupport.sampleProfileID.uuidString)
        #expect(object["name"] as? String == "Work")
        #expect(object["schemaVersion"] as? Int == 1)

        let apps = try #require(object["apps"] as? [[String: Any]])
        #expect(apps.map { $0["type"] as? String } == ["app", "spacer", "app"])
        #expect(apps[0]["bundleId"] as? String == "com.figma.Desktop")
        #expect(apps[0]["launchOnSwitch"] as? Bool == true)
        #expect(apps[1]["kind"] as? String == "small-spacer")
        #expect(apps[2]["appStoreId"] == nil)

        let others = try #require(object["others"] as? [[String: Any]])
        #expect(others.map { $0["type"] as? String } == ["folder", "url", "file", "spacer"])
        #expect(others[0]["sort"] as? String == "dateadded")
        #expect(others[1]["url"] as? String == "https://example.com/docs")
        #expect(others[2]["path"] as? String == "/Users/me/notes.txt")
        #expect(others[3]["kind"] as? String == "flex-spacer")

        let prefs = try #require(object["prefs"] as? [String: Any])
        #expect(Set(prefs.keys) == ["tileSize", "magnification", "largeSize", "orientation", "autohideDelay"])
        #expect(prefs["tileSize"] as? Double == 48)
        #expect(prefs["orientation"] as? String == "left")

        let switching = try #require(object["switching"] as? [String: Any])
        #expect(switching["quitScope"] as? String == "allNotInProfile")
        #expect(switching["launchHidden"] as? Bool == true)
        #expect(switching["offerForceQuit"] as? Bool == false)

        let hotkey = try #require(object["hotkey"] as? [String: Any])
        #expect(hotkey["keyCode"] as? Int == 18)
        #expect(hotkey["modifiers"] as? [String] == ["command", "option"])
    }

    @Test func decodesHandWrittenProfile() throws {
        let json = """
            {
              "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
              "name": "Dev",
              "schemaVersion": 1,
              "apps": [
                {"type": "app", "name": "Figma", "bundleId": "com.figma.Desktop",
                 "brewCask": "figma", "appStoreId": null, "path": "/Applications/Figma.app"}
              ],
              "others": [{"type": "url", "url": "https://swift.org", "label": "Swift"}],
              "prefs": {"autohide": true, "minimizeEffect": "scale"},
              "hotkey": {"keyCode": 2, "modifiers": ["shift", "control"]}
            }
            """
        let profile = try Profile(jsonData: Data(json.utf8))
        #expect(profile.apps == [.app(AppRef(bundleId: "com.figma.Desktop", name: "Figma",
                                             path: "/Applications/Figma.app", brewCask: "figma"))])
        #expect(profile.others == [.url(URLItem(url: URL(string: "https://swift.org")!, label: "Swift"))])
        #expect(profile.prefs == DockPrefs(autohide: true, minimizeEffect: .scale))
        #expect(profile.hotkey == Hotkey(keyCode: 2, modifiers: [.control, .shift]))
    }

    // MARK: Defaults

    @Test func defaultsWhenOptionalFieldsMissing() throws {
        let profile = try Profile(jsonData: Data(Self.minimalJSON.utf8))
        #expect(profile.id == ModelTestSupport.sampleProfileID)
        #expect(profile.apps.isEmpty)
        #expect(profile.others.isEmpty)
        #expect(profile.prefs == nil)
        #expect(profile.hotkey == nil)
        #expect(profile.switching == SwitchingOptions())
        #expect(profile.switching.quitScope == .previousProfileApps)
        #expect(profile.switching.launchHidden == false)
        #expect(profile.switching.offerForceQuit == false)
    }

    @Test func switchingDefaultsPerField() throws {
        let options = try ModelTestSupport.decode(SwitchingOptions.self, #"{"launchHidden": true}"#)
        #expect(options == SwitchingOptions(quitScope: .previousProfileApps, launchHidden: true, offerForceQuit: false))
    }

    @Test func emptyPrefsObjectMeansNoChanges() throws {
        let prefs = try ModelTestSupport.decode(DockPrefs.self, "{}")
        #expect(prefs.isEmpty)
        #expect(prefs == DockPrefs())
    }

    @Test func hotkeyModifiersDefaultToEmpty() throws {
        #expect(try ModelTestSupport.decode(Hotkey.self, #"{"keyCode": 1}"#) == Hotkey(keyCode: 1, modifiers: []))
    }

    // MARK: Strict decoding

    @Test func rejectsNewerSchemaVersion() {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":2,"newField":1}"#
        #expect(throws: ProfileDecodingError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try Profile(jsonData: Data(json.utf8))
        }
    }

    @Test func rejectsZeroSchemaVersion() {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":0}"#
        #expect(throws: ProfileDecodingError.unsupportedSchemaVersion(found: 0, supported: 1)) {
            try Profile(jsonData: Data(json.utf8))
        }
    }

    @Test func requiresSchemaVersion() {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X"}"#
        #expect(throws: DecodingError.self) { try Profile(jsonData: Data(json.utf8)) }
    }

    @Test func rejectsUnknownTopLevelKey() {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":1,"triggers":[]}"#
        #expect(throws: ProfileDecodingError.unknownKeys(["triggers"], codingPath: "")) {
            try Profile(jsonData: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownNestedKeys() {
        let cases: [(String, ProfileDecodingError)] = [
            (#""prefs":{"tilesize":48}"#, .unknownKeys(["tilesize"], codingPath: "prefs")),
            (#""switching":{"quitAll":true}"#, .unknownKeys(["quitAll"], codingPath: "switching")),
            (#""hotkey":{"keyCode":1,"global":true}"#, .unknownKeys(["global"], codingPath: "hotkey")),
            (#""others":[{"type":"file","path":"/x","exec":"y"}]"#, .unknownKeys(["exec"], codingPath: "others.Index 0")),
        ]
        for (fragment, expected) in cases {
            let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":1,"# + fragment + "}"
            #expect(throws: expected) { try Profile(jsonData: Data(json.utf8)) }
        }
    }

    @Test func rejectsUnknownItemTypeInProfile() {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X","schemaVersion":1,"apps":[{"type":"script","cmd":"x"}]}"#
        #expect(throws: ProfileDecodingError.unknownItemType("script", codingPath: "apps.Index 0")) {
            try Profile(jsonData: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownHotkeyModifier() {
        #expect(throws: ProfileDecodingError.unknownHotkeyModifier("hyper", codingPath: "modifiers")) {
            try ModelTestSupport.decode(Hotkey.self, #"{"keyCode": 1, "modifiers": ["hyper"]}"#)
        }
    }

    @Test func rejectsInvalidEnumInPrefs() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockPrefs.self, #"{"orientation":"top"}"#)
        }
    }

    @Test func rejectsNonObjectRoot() {
        #expect(throws: DecodingError.self) { try Profile(jsonData: Data("[]".utf8)) }
    }
}
