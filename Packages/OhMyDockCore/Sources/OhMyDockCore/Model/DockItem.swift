import Foundation

/// One tile in the Dock.
///
/// JSON form is a flat object discriminated by `type`, for example
/// `{"type": "folder", "path": "/Users/me/Downloads", "view": "grid", ...}`.
public enum DockItem: Hashable, Sendable {
    case app(AppRef)
    case url(URLItem)
    case folder(FolderItem)
    case file(FileItem)
    case spacer(SpacerKind)
    /// Read-only passthrough for tile types the model doesn't cover, so reading the
    /// live Dock never silently drops items. Rejected by `Profile.validate()` unless it allows unknown tiles (local profiles).
    case unknown(UnknownTile)
}

/// The two persistent sections of the Dock.
public enum DockSection: String, Codable, Hashable, Sendable, CaseIterable {
    case apps
    case others

    /// Array key in the `com.apple.dock` domain.
    public var plistKey: String {
        switch self {
        case .apps: "persistent-apps"
        case .others: "persistent-others"
        }
    }
}

// MARK: - Payloads

/// Labels use one convention everywhere: nil means "no label, let dockutil derive one", and an
/// empty string is the same thing, so it is stored as nil. Without this a tile read from the
/// Dock with `""` and the same tile in a profile with nil would differ for the diff, the
/// equality and the identity of unknown tiles while meaning the same to dockutil.
func normalizedLabel(_ label: String?) -> String? {
    guard let label, !label.isEmpty else { return nil }
    return label
}

public struct URLItem: Codable, Hashable, Sendable {
    public var url: URL
    /// Nil when absent or empty (see `normalizedLabel`).
    public var label: String? {
        didSet { label = normalizedLabel(label) }
    }

    public init(url: URL, label: String? = nil) {
        self.url = url
        self.label = normalizedLabel(label)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case url, label
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, alsoAllowing: [])
    }

    init(from decoder: any Decoder, alsoAllowing extra: Set<String>) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, alsoAllowing: extra)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let string = try c.decode(String.self, forKey: .url)
        guard let url = URL(string: string) else {
            throw ProfileDecodingError.invalidURL(string, codingPath: (c.codingPath + [CodingKeys.url]).pathString)
        }
        self.url = url
        label = normalizedLabel(try c.decodeIfPresent(String.self, forKey: .label))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url.absoluteString, forKey: .url)
        try c.encodeIfPresent(label, forKey: .label)
    }
}

/// Raw values are dockutil's `--view` arguments.
public enum FolderView: String, Codable, Hashable, Sendable, CaseIterable {
    case grid, fan, list, auto
}

/// Raw values are dockutil's `--display` arguments.
public enum FolderDisplay: String, Codable, Hashable, Sendable, CaseIterable {
    case folder, stack
}

/// Raw values are dockutil's `--sort` arguments.
public enum FolderSort: String, Codable, Hashable, Sendable, CaseIterable {
    case name
    case dateAdded = "dateadded"
    case dateModified = "datemodified"
    case dateCreated = "datecreated"
    case kind
}

public struct FolderItem: Codable, Hashable, Sendable {
    /// Absolute path. Never `~`-relative: dockutil expands `~` relative to the plist path.
    public var path: String
    public var view: FolderView
    public var display: FolderDisplay
    public var sort: FolderSort
    /// Nil when absent or empty (see `normalizedLabel`).
    public var label: String? {
        didSet { label = normalizedLabel(label) }
    }

    public init(
        path: String,
        view: FolderView = .auto,
        display: FolderDisplay = .stack,
        sort: FolderSort = .name,
        label: String? = nil
    ) {
        self.path = path
        self.view = view
        self.display = display
        self.sort = sort
        self.label = normalizedLabel(label)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case path, view, display, sort, label
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, alsoAllowing: [])
    }

    init(from decoder: any Decoder, alsoAllowing extra: Set<String>) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, alsoAllowing: extra)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        view = try c.decodeIfPresent(FolderView.self, forKey: .view) ?? .auto
        display = try c.decodeIfPresent(FolderDisplay.self, forKey: .display) ?? .stack
        sort = try c.decodeIfPresent(FolderSort.self, forKey: .sort) ?? .name
        label = normalizedLabel(try c.decodeIfPresent(String.self, forKey: .label))
    }
}

/// A plain (non-directory) file tile in the others section.
public struct FileItem: Codable, Hashable, Sendable {
    /// Absolute path. Never `~`-relative.
    public var path: String
    /// Nil when absent or empty (see `normalizedLabel`).
    public var label: String? {
        didSet { label = normalizedLabel(label) }
    }

    public init(path: String, label: String? = nil) {
        self.path = path
        self.label = normalizedLabel(label)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case path, label
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, alsoAllowing: [])
    }

    init(from decoder: any Decoder, alsoAllowing extra: Set<String>) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, alsoAllowing: extra)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        label = normalizedLabel(try c.decodeIfPresent(String.self, forKey: .label))
    }
}

/// Raw values are dockutil's `--type` arguments.
public enum SpacerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case normal = "spacer"
    case small = "small-spacer"
    case flex = "flex-spacer"

    /// The `tile-type` value in the Dock plist, e.g. `small-spacer-tile`.
    public var tileType: String { rawValue + "-tile" }
}

public struct UnknownTile: Codable, Hashable, Sendable {
    /// The plist `tile-type`, e.g. `recents-tile`.
    public var tileType: String
    /// Nil when absent or empty (see `normalizedLabel`).
    public var label: String? {
        didSet { label = normalizedLabel(label) }
    }

    public init(tileType: String, label: String? = nil) {
        self.tileType = tileType
        self.label = normalizedLabel(label)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case tileType, label
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, alsoAllowing: [])
    }

    init(from decoder: any Decoder, alsoAllowing extra: Set<String>) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, alsoAllowing: extra)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tileType = try c.decode(String.self, forKey: .tileType)
        label = normalizedLabel(try c.decodeIfPresent(String.self, forKey: .label))
    }
}

// MARK: - Codable

extension DockItem: Codable {
    /// JSON `type` discriminator values.
    public enum ItemType: String, Hashable, Sendable, CaseIterable {
        case app, url, folder, file, spacer, unknown
    }

    public var itemType: ItemType {
        switch self {
        case .app: .app
        case .url: .url
        case .folder: .folder
        case .file: .file
        case .spacer: .spacer
        case .unknown: .unknown
        }
    }

    private enum TypeKey: String, CodingKey {
        case type
    }

    private enum SpacerKeys: String, CodingKey, CaseIterable {
        case type, kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let type = ItemType(rawValue: raw) else {
            throw ProfileDecodingError.unknownItemType(raw, codingPath: decoder.codingPath.pathString)
        }
        let typeKey: Set<String> = [TypeKey.type.stringValue]
        switch type {
        case .app: self = .app(try AppRef(from: decoder, alsoAllowing: typeKey))
        case .url: self = .url(try URLItem(from: decoder, alsoAllowing: typeKey))
        case .folder: self = .folder(try FolderItem(from: decoder, alsoAllowing: typeKey))
        case .file: self = .file(try FileItem(from: decoder, alsoAllowing: typeKey))
        case .unknown: self = .unknown(try UnknownTile(from: decoder, alsoAllowing: typeKey))
        case .spacer:
            try decoder.rejectUnknownKeys(SpacerKeys.self)
            let c = try decoder.container(keyedBy: SpacerKeys.self)
            self = .spacer(try c.decodeIfPresent(SpacerKind.self, forKey: .kind) ?? .normal)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(itemType.rawValue, forKey: .type)
        switch self {
        case .app(let ref): try ref.encode(to: encoder)
        case .url(let item): try item.encode(to: encoder)
        case .folder(let item): try item.encode(to: encoder)
        case .file(let item): try item.encode(to: encoder)
        case .unknown(let tile): try tile.encode(to: encoder)
        case .spacer(let kind):
            var c = encoder.container(keyedBy: SpacerKeys.self)
            try c.encode(kind, forKey: .kind)
        }
    }
}
