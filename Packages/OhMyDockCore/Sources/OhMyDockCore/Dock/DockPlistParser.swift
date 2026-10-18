import Foundation

/// Parses a `com.apple.dock` domain dictionary into ``DockState``.
///
/// Pure and side-effect free except for the bundle-identifier resolver, which
/// runs only for app tiles that have no `bundle-identifier`. A tile that cannot
/// be represented is returned as ``DockItem/unknown(_:)`` — tiles are never
/// dropped and parsing never throws.
public enum DockPlistParser {
    /// Opens `url` with `Bundle` and returns its bundle identifier, or nil when
    /// `url` is not a bundle. This is the default resolver.
    public static func bundleIdentifier(at url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    /// Parses `persistent-apps` and `persistent-others`. Missing sections are empty.
    /// A section value that is not an array contributes no tiles.
    public static func parse(
        domain: [String: Any],
        resolvingBundleIdentifier bundleIdentifier: @Sendable (URL) -> String? = bundleIdentifier(at:)
    ) -> DockState {
        DockState(
            apps: items(
                in: domain[DockSection.apps.plistKey],
                section: .apps,
                resolvingBundleIdentifier: bundleIdentifier
            ),
            others: items(
                in: domain[DockSection.others.plistKey],
                section: .others,
                resolvingBundleIdentifier: bundleIdentifier
            )
        )
    }

    /// Parses one tile dictionary from `section`.
    ///
    /// - `file-tile` is an app when the path ends in `.app` or `bundle-identifier`
    ///   is present; otherwise it is a file.
    /// - `directory-tile` is a folder. `showas`, `displayas`, and `arrangement`
    ///   use dockutil 3.1.3's integer values (see `folderView(showas:)`).
    /// - `url-tile` is a URL. `spacer-tile`, `small-spacer-tile`, and
    ///   `flex-spacer-tile` are spacers. Anything else is unknown.
    public static func parseTile(
        _ tile: [String: Any],
        section: DockSection,
        resolvingBundleIdentifier bundleIdentifier: @Sendable (URL) -> String? = bundleIdentifier(at:)
    ) -> DockItem {
        // Both sections share one tile schema. Exhaustiveness forces a look here
        // if `DockSection` gains a case.
        switch section {
        case .apps, .others:
            return parseTileContents(tile, resolvingBundleIdentifier: bundleIdentifier)
        }
    }

    // MARK: - Tiles

    private static func items(
        in value: Any?,
        section: DockSection,
        resolvingBundleIdentifier bundleIdentifier: @Sendable (URL) -> String?
    ) -> [DockItem] {
        guard let elements = DockPlistValues.array(value) else { return [] }
        return elements.map { element in
            guard let tile = DockPlistValues.dictionary(element) else {
                return .unknown(UnknownTile(tileType: ""))
            }
            return parseTile(tile, section: section, resolvingBundleIdentifier: bundleIdentifier)
        }
    }

    private static func parseTileContents(
        _ tile: [String: Any],
        resolvingBundleIdentifier bundleIdentifier: @Sendable (URL) -> String?
    ) -> DockItem {
        guard let tileType = DockPlistValues.string(tile["tile-type"]) else {
            return unknown(from: tile)
        }
        if let kind = SpacerKind.allCases.first(where: { $0.tileType == tileType }) {
            return .spacer(kind)
        }
        switch tileType {
        case "file-tile":
            return parseFileTile(tile, resolvingBundleIdentifier: bundleIdentifier)
        case "directory-tile":
            return parseDirectoryTile(tile)
        case "url-tile":
            return parseURLTile(tile)
        default:
            return unknown(from: tile, tileType: tileType)
        }
    }

    private static func parseFileTile(
        _ tile: [String: Any],
        resolvingBundleIdentifier bundleIdentifier: @Sendable (URL) -> String?
    ) -> DockItem {
        guard let data = DockPlistValues.dictionary(tile["tile-data"]) else {
            return unknown(from: tile, tileType: "file-tile")
        }
        let explicitBundleID = nonEmpty(DockPlistValues.string(data["bundle-identifier"]))
        let path = DockPlistValues.dictionary(data["file-data"]).flatMap(absoluteFilePath(in:))
        let label = DockPlistValues.string(data["file-label"])
        let isApp = explicitBundleID != nil || path?.lowercased().hasSuffix(".app") == true

        if isApp {
            let resolvedID: String
            if let explicitBundleID {
                resolvedID = explicitBundleID
            } else if let path {
                resolvedID = bundleIdentifier(URL(fileURLWithPath: path)) ?? ""
            } else {
                resolvedID = ""
            }
            let name = label ?? path.map(appName(from:)) ?? ""
            return .app(AppRef(bundleId: resolvedID, name: name, path: path))
        }

        guard let path else {
            return unknown(from: tile, tileType: "file-tile")
        }
        return .file(FileItem(path: path, label: label))
    }

    private static func parseDirectoryTile(_ tile: [String: Any]) -> DockItem {
        // Missing or unrecognized ints are not defaulted: a guessed view would
        // write a different Dock setting back. The tile is kept as unknown.
        guard
            let data = DockPlistValues.dictionary(tile["tile-data"]),
            let fileData = DockPlistValues.dictionary(data["file-data"]),
            let path = absoluteFilePath(in: fileData),
            let showas = DockPlistValues.int(data["showas"]),
            let view = folderView(showas: showas),
            let displayas = DockPlistValues.int(data["displayas"]),
            let display = folderDisplay(displayas: displayas),
            let arrangement = DockPlistValues.int(data["arrangement"]),
            let sort = folderSort(arrangement: arrangement)
        else {
            return unknown(from: tile, tileType: "directory-tile")
        }
        return .folder(FolderItem(
            path: path,
            view: view,
            display: display,
            sort: sort,
            label: DockPlistValues.string(data["file-label"])
        ))
    }

    private static func parseURLTile(_ tile: [String: Any]) -> DockItem {
        guard
            let data = DockPlistValues.dictionary(tile["tile-data"]),
            let urlData = DockPlistValues.dictionary(data["url"]),
            let raw = DockPlistValues.string(urlData["_CFURLString"]),
            let url = URL(string: raw),
            url.scheme != nil
        else {
            return unknown(from: tile, tileType: "url-tile")
        }
        let label = DockPlistValues.string(data["label"]) ?? DockPlistValues.string(data["file-label"])
        return .url(URLItem(url: url, label: label))
    }

    private static func unknown(from tile: [String: Any], tileType: String? = nil) -> DockItem {
        let type = tileType ?? DockPlistValues.string(tile["tile-type"]) ?? ""
        let data = DockPlistValues.dictionary(tile["tile-data"])
        let label = data.flatMap {
            DockPlistValues.string($0["file-label"]) ?? DockPlistValues.string($0["label"])
        }
        return .unknown(UnknownTile(tileType: type, label: label))
    }

    // MARK: - Paths

    /// `_CFURLStringType` 0 is a bare POSIX path. 15 is an absolute URL string
    /// (`file:///…`), often percent-encoded and written with a trailing slash.
    /// Both become a decoded absolute path with no trailing slash.
    private static func absoluteFilePath(in fileData: [String: Any]) -> String? {
        guard let raw = DockPlistValues.string(fileData["_CFURLString"]), !raw.isEmpty else {
            return nil
        }
        let path: String
        switch DockPlistValues.int(fileData["_CFURLStringType"]) {
        case 0:
            path = raw
        case 15:
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            path = url.path(percentEncoded: false)
        default:
            return nil
        }
        return cleanAbsolutePath(path)
    }

    private static func cleanAbsolutePath(_ path: String) -> String? {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.hasPrefix("/") else { return nil }
        return standardizedPath(path)
    }

    private static func appName(from path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    // MARK: - Folder integers

    // dockutil 3.1.3 (commit 640c520ce142a5f21e56fda88a95b4e4d6576042).
    // Raw values are `Sources/DockUtil/DockUtil.swift`; `Dock.swift:294-296` writes
    // them as `arrangement`, `displayas`, and `showas`.
    //
    // FolderView (`showas`), DockUtil.swift:48-51:
    //   auto = 0, fan = 1, grid = 2, list = 3
    // FolderDisplay (`displayas`), DockUtil.swift:31-32:
    //   stack = 0, folder = 1
    // FolderSort (`arrangement`), DockUtil.swift:68-72:
    //   name = 1, dateadded = 2, datemodified = 3, datecreated = 4, kind = 5

    private static func folderView(showas: Int) -> FolderView? {
        switch showas {
        case 0: .auto
        case 1: .fan
        case 2: .grid
        case 3: .list
        default: nil
        }
    }

    private static func folderDisplay(displayas: Int) -> FolderDisplay? {
        switch displayas {
        case 0: .stack
        case 1: .folder
        default: nil
        }
    }

    private static func folderSort(arrangement: Int) -> FolderSort? {
        switch arrangement {
        case 1: .name
        case 2: .dateAdded
        case 3: .dateModified
        case 4: .dateCreated
        case 5: .kind
        default: nil
        }
    }
}

/// Property-list values arrive as Swift values or as `NSDictionary` / `NSArray` /
/// `NSNumber` from `PropertyListSerialization` and `CFPreferencesCopyAppValue`.
enum DockPlistValues {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        result.reserveCapacity(dictionary.count)
        for (key, nested) in dictionary {
            guard let key = key as? String else { continue }
            result[key] = nested
        }
        return result
    }

    static func array(_ value: Any?) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        guard let array = value as? NSArray else { return nil }
        return array.map { $0 }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as NSNumber:
            number.intValue
        default:
            nil
        }
    }
}
