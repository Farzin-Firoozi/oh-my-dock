import Foundation

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxNameLength = 100

    public var id: UUID
    public var name: String
    public var schemaVersion: Int
    /// `persistent-apps` section.
    public var apps: [DockItem]
    /// `persistent-others` section.
    public var others: [DockItem]
    /// `nil` = don't touch Dock preferences.
    public var prefs: DockPrefs?
    public var switching: SwitchingOptions
    public var hotkey: Hotkey?

    public init(
        id: UUID = UUID(),
        name: String,
        schemaVersion: Int = Profile.currentSchemaVersion,
        apps: [DockItem] = [],
        others: [DockItem] = [],
        prefs: DockPrefs? = nil,
        switching: SwitchingOptions = SwitchingOptions(),
        hotkey: Hotkey? = nil
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
        self.apps = apps
        self.others = others
        self.prefs = prefs
        self.switching = switching
        self.hotkey = hotkey
    }

    public func items(in section: DockSection) -> [DockItem] {
        switch section {
        case .apps: apps
        case .others: others
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, schemaVersion, apps, others, prefs, switching, hotkey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Checked before unknown keys so a newer file reports its version, not its new fields.
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw ProfileDecodingError.unsupportedSchemaVersion(found: version, supported: Self.currentSchemaVersion)
        }
        try decoder.rejectUnknownKeys(CodingKeys.self)
        schemaVersion = version
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([DockItem].self, forKey: .apps) ?? []
        others = try c.decodeIfPresent([DockItem].self, forKey: .others) ?? []
        prefs = try c.decodeIfPresent(DockPrefs.self, forKey: .prefs)
        switching = try c.decodeIfPresent(SwitchingOptions.self, forKey: .switching) ?? SwitchingOptions()
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
    }
}

// MARK: - JSON

extension Profile {
    /// Pretty-printed, sorted-key encoder for stable, diff-friendly files.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func jsonData() throws -> Data {
        try Self.makeJSONEncoder().encode(self)
    }

    /// Decodes strictly. Does not call `validate()`.
    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Profile.self, from: jsonData)
    }
}

// MARK: - Validation

public enum ProfileValidationError: Error, Hashable, Sendable {
    case emptyName
    case nameTooLong(length: Int, maximum: Int)
    case unknownItem(DockSection, index: Int, tileType: String)
    case appMissingIdentity(DockSection, index: Int)
    case pathNotAbsolute(DockSection, index: Int, path: String)
    case unsupportedURLScheme(DockSection, index: Int, url: String)
    case invalidPrefs(DockPrefsValidationError)
    /// Two tiles of one section get the same label from dockutil, which refuses to add the second.
    /// `index` is the later tile.
    case duplicateLabel(DockSection, index: Int, label: String)
}

extension Profile {
    public func validate() throws(ProfileValidationError) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .emptyName
        }
        if name.count > Self.maxNameLength {
            throw .nameTooLong(length: name.count, maximum: Self.maxNameLength)
        }
        for section in DockSection.allCases {
            var labels: Set<String> = []
            for (index, item) in items(in: section).enumerated() {
                try Self.validate(item, in: section, at: index)
                // dockutil refuses to add a tile whose computed label is already used in the
                // section (spacers are never stored, so they never collide).
                guard !item.isSpacer else { continue }
                let label = DockutilPlanner.computedLabel(of: item)
                if !label.isEmpty, !labels.insert(label).inserted {
                    throw .duplicateLabel(section, index: index, label: label)
                }
            }
        }
        do {
            try prefs?.validate()
        } catch {
            throw .invalidPrefs(error)
        }
    }

    private static func validate(_ item: DockItem, in section: DockSection, at index: Int) throws(ProfileValidationError) {
        switch item {
        case .unknown(let tile):
            throw .unknownItem(section, index: index, tileType: tile.tileType)
        case .app(let ref):
            if ref.bundleId.isEmpty, (ref.path ?? "").isEmpty {
                throw .appMissingIdentity(section, index: index)
            }
            if let path = ref.path, !isAbsolutePath(path) {
                throw .pathNotAbsolute(section, index: index, path: path)
            }
        case .url(let item):
            let scheme = item.url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https", !(item.url.host() ?? "").isEmpty else {
                throw .unsupportedURLScheme(section, index: index, url: item.url.absoluteString)
            }
        case .folder(let item):
            if !isAbsolutePath(item.path) {
                throw .pathNotAbsolute(section, index: index, path: item.path)
            }
        case .file(let item):
            if !isAbsolutePath(item.path) {
                throw .pathNotAbsolute(section, index: index, path: item.path)
            }
        case .spacer:
            break
        }
    }

    /// Starts with `/` and has no `.` / `..` components. `~` is rejected because
    /// dockutil expands it relative to the plist path, not the home directory.
    private static func isAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }
}
