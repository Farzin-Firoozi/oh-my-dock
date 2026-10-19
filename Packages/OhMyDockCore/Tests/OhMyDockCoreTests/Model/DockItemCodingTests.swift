import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockItemCodingTests {
    static let allCases: [DockItem] = [
        .app(AppRef(bundleId: "com.figma.Desktop", name: "Figma", path: "/Applications/Figma.app",
                    brewCask: "figma", appStoreId: 123, launchOnSwitch: true)),
        .app(AppRef(bundleId: "com.apple.Safari", name: "Safari")),
        .url(URLItem(url: URL(string: "https://example.com/a?b=c")!, label: "Example")),
        .url(URLItem(url: URL(string: "http://example.com")!)),
        .folder(FolderItem(path: "/Users/me/Downloads", view: .grid, display: .folder, sort: .dateAdded, label: "DL")),
        .folder(FolderItem(path: "/Applications", view: .list, display: .stack, sort: .kind)),
        .file(FileItem(path: "/Users/me/notes.txt", label: "Notes")),
        .file(FileItem(path: "/Users/me/todo.md")),
        .spacer(.normal),
        .spacer(.small),
        .spacer(.flex),
        .unknown(UnknownTile(tileType: "recents-tile", label: "Recent")),
        .unknown(UnknownTile(tileType: "mystery-tile")),
    ]

    @Test func emptyLabelIsNilEverywhere() throws {
        let url = URL(string: "https://example.com")!
        #expect(URLItem(url: url, label: "") == URLItem(url: url))
        #expect(FolderItem(path: "/a", label: "") == FolderItem(path: "/a"))
        #expect(FileItem(path: "/a", label: "").label == nil)
        #expect(UnknownTile(tileType: "t", label: "") == UnknownTile(tileType: "t"))

        var mutated = FileItem(path: "/a", label: "Named")
        mutated.label = ""
        #expect(mutated.label == nil)

        // And so does JSON: the same tile written either way decodes to the same item.
        let empty = try ModelTestSupport.decode(DockItem.self, #"{"type":"file","path":"/a","label":""}"#)
        let absent = try ModelTestSupport.decode(DockItem.self, #"{"type":"file","path":"/a"}"#)
        #expect(empty == absent)
        let emptyUnknown = try ModelTestSupport.decode(DockItem.self, #"{"type":"unknown","tileType":"t","label":""}"#)
        #expect(emptyUnknown.identity == DockItem.unknown(UnknownTile(tileType: "t")).identity)
    }

    @Test(arguments: allCases)
    func roundTrips(_ item: DockItem) throws {
        #expect(try ModelTestSupport.roundTrip(item) == item)
    }

    @Test(arguments: allCases)
    func encodesTypeDiscriminator(_ item: DockItem) throws {
        let object = try ModelTestSupport.jsonObject(item)
        #expect(object["type"] as? String == item.itemType.rawValue)
    }

    @Test func appShape() throws {
        let object = try ModelTestSupport.jsonObject(Self.allCases[0])
        #expect(object["type"] as? String == "app")
        #expect(object["bundleId"] as? String == "com.figma.Desktop")
        #expect(object["name"] as? String == "Figma")
        #expect(object["path"] as? String == "/Applications/Figma.app")
        #expect(object["brewCask"] as? String == "figma")
        #expect(object["appStoreId"] as? Int == 123)
        #expect(object["launchOnSwitch"] as? Bool == true)
        #expect(object.count == 7)
    }

    @Test func folderShapeUsesDockutilValues() throws {
        let object = try ModelTestSupport.jsonObject(Self.allCases[4])
        #expect(object["type"] as? String == "folder")
        #expect(object["path"] as? String == "/Users/me/Downloads")
        #expect(object["view"] as? String == "grid")
        #expect(object["display"] as? String == "folder")
        #expect(object["sort"] as? String == "dateadded")
        #expect(object["label"] as? String == "DL")
    }

    @Test func spacerShapeUsesDockutilValues() throws {
        #expect(try ModelTestSupport.jsonObject(DockItem.spacer(.small))["kind"] as? String == "small-spacer")
        #expect(try ModelTestSupport.jsonObject(DockItem.spacer(.flex))["kind"] as? String == "flex-spacer")
        #expect(try ModelTestSupport.jsonObject(DockItem.spacer(.normal))["kind"] as? String == "spacer")
    }

    @Test func urlEncodesAsString() throws {
        let object = try ModelTestSupport.jsonObject(Self.allCases[2])
        #expect(object["url"] as? String == "https://example.com/a?b=c")
    }

    @Test func nilOptionalsAreOmitted() throws {
        let object = try ModelTestSupport.jsonObject(DockItem.file(FileItem(path: "/x")))
        #expect(Set(object.keys) == ["type", "path"])
    }

    @Test func dockutilRawValues() {
        #expect(FolderView.allCases.map(\.rawValue) == ["grid", "fan", "list", "auto"])
        #expect(FolderDisplay.allCases.map(\.rawValue) == ["folder", "stack"])
        #expect(FolderSort.allCases.map(\.rawValue) == ["name", "dateadded", "datemodified", "datecreated", "kind"])
        #expect(SpacerKind.allCases.map(\.rawValue) == ["spacer", "small-spacer", "flex-spacer"])
        #expect(SpacerKind.allCases.map(\.tileType) == ["spacer-tile", "small-spacer-tile", "flex-spacer-tile"])
    }

    @Test func sectionPlistKeys() {
        #expect(DockSection.apps.plistKey == "persistent-apps")
        #expect(DockSection.others.plistKey == "persistent-others")
    }

    // MARK: Defaults

    @Test func appDefaults() throws {
        let item = try ModelTestSupport.decode(DockItem.self, #"{"type":"app","bundleId":"a.b","name":"B"}"#)
        #expect(item == .app(AppRef(bundleId: "a.b", name: "B")))
        guard case .app(let ref) = item else { Issue.record("not an app"); return }
        #expect(ref.launchOnSwitch == false)
        #expect(ref.path == nil && ref.brewCask == nil && ref.appStoreId == nil)
    }

    @Test func explicitNullsDecodeAsNil() throws {
        let json = #"{"type":"app","bundleId":"a.b","name":"B","appStoreId":null,"path":null}"#
        #expect(try ModelTestSupport.decode(DockItem.self, json) == .app(AppRef(bundleId: "a.b", name: "B")))
    }

    @Test func folderDefaults() throws {
        let item = try ModelTestSupport.decode(DockItem.self, #"{"type":"folder","path":"/Applications"}"#)
        #expect(item == .folder(FolderItem(path: "/Applications", view: .auto, display: .stack, sort: .name)))
    }

    @Test func spacerDefaultsToNormal() throws {
        #expect(try ModelTestSupport.decode(DockItem.self, #"{"type":"spacer"}"#) == .spacer(.normal))
    }

    // MARK: Strict decoding

    @Test func rejectsUnknownType() {
        #expect(throws: ProfileDecodingError.unknownItemType("widget", codingPath: "")) {
            try ModelTestSupport.decode(DockItem.self, #"{"type":"widget","path":"/x"}"#)
        }
    }

    @Test func rejectsMissingType() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockItem.self, #"{"bundleId":"a.b","name":"B"}"#)
        }
    }

    @Test(arguments: [
        #"{"type":"app","bundleId":"a.b","name":"B","script":"rm -rf /"}"#,
        #"{"type":"url","url":"https://x.com","onClick":"x"}"#,
        #"{"type":"folder","path":"/x","color":"red"}"#,
        #"{"type":"file","path":"/x","bundleId":"a.b"}"#,
        #"{"type":"spacer","kind":"spacer","label":"x"}"#,
        #"{"type":"unknown","tileType":"t","path":"/x"}"#,
    ])
    func rejectsUnknownKeys(_ json: String) {
        #expect {
            try ModelTestSupport.decode(DockItem.self, json)
        } throws: { error in
            guard case ProfileDecodingError.unknownKeys(let keys, _) = error else { return false }
            return keys.count == 1
        }
    }

    @Test func standalonePayloadRejectsTypeKey() {
        #expect(throws: ProfileDecodingError.unknownKeys(["type"], codingPath: "")) {
            try ModelTestSupport.decode(AppRef.self, #"{"type":"app","bundleId":"a.b","name":"B"}"#)
        }
    }

    @Test(arguments: [
        #"{"type":"folder","path":"/x","view":"tiles"}"#,
        #"{"type":"folder","path":"/x","sort":"dateAdded"}"#,
        #"{"type":"spacer","kind":"normal"}"#,
    ])
    func rejectsInvalidEnumValues(_ json: String) {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockItem.self, json)
        }
    }

    @Test func rejectsWrongValueType() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockItem.self, #"{"type":"app","bundleId":42,"name":"B"}"#)
        }
    }
}
