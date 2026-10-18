import Foundation
import Testing
@testable import OhMyDockCore

enum ModelTestSupport {
    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try Profile.makeJSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Encodes `value` and returns it as a JSON object for shape assertions.
    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try Profile.makeJSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static let sampleProfileID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    static func sampleProfile() -> Profile {
        Profile(
            id: sampleProfileID,
            name: "Work",
            apps: [
                .app(AppRef(
                    bundleId: "com.figma.Desktop",
                    name: "Figma",
                    path: "/Applications/Figma.app",
                    brewCask: "figma",
                    launchOnSwitch: true
                )),
                .spacer(.small),
                .app(AppRef(bundleId: "com.apple.Safari", name: "Safari", appStoreId: nil)),
            ],
            others: [
                .folder(FolderItem(path: "/Users/me/Downloads", view: .grid, display: .folder, sort: .dateAdded, label: "Downloads")),
                .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "Docs")),
                .file(FileItem(path: "/Users/me/notes.txt")),
                .spacer(.flex),
            ],
            prefs: DockPrefs(tileSize: 48, magnification: true, largeSize: 96, orientation: .left, autohideDelay: 0),
            switching: SwitchingOptions(quitScope: .allNotInProfile, launchHidden: true),
            hotkey: Hotkey(keyCode: 18, modifiers: [.command, .option])
        )
    }
}
