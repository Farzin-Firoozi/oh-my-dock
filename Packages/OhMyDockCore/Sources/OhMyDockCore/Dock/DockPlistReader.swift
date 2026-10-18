import Foundation

/// Failure while reading a Dock plist. Reading never writes preferences and never
/// restarts the Dock.
public enum DockReadError: Error, Equatable, Sendable {
    /// A live `com.apple.dock` section was present but was not an array.
    case unreadablePreferences(key: String)
    /// `path` could not be read as a property-list dictionary.
    case unreadableFile(String)
}

extension DockReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadablePreferences(let key):
            "Could not read the Dock preference key \(key)."
        case .unreadableFile(let path):
            "Could not read Dock plist at \(path)."
        }
    }
}

/// Read-only view of a Dock plist.
///
/// `.live` synchronizes the `com.apple.dock` domain and copies `persistent-apps`
/// and `persistent-others` with `CFPreferencesCopyAppValue`. `.file` reads a
/// plist file with `PropertyListSerialization` after canonicalizing the URL.
/// Neither path writes the domain or restarts the Dock.
public struct DockPlistReader: Sendable {
    public enum Source: Hashable, Sendable {
        /// The current user's live Dock preference domain.
        case live
        /// A plist file. The URL is canonicalized with
        /// `resolvingSymlinksInPath().standardized` before it is opened.
        case file(URL)
    }

    public let source: Source
    private let resolveBundleIdentifier: @Sendable (URL) -> String?

    public init(
        _ source: Source,
        resolvingBundleIdentifier: @escaping @Sendable (URL) -> String? = DockPlistParser.bundleIdentifier(at:)
    ) {
        self.source = source
        self.resolveBundleIdentifier = resolvingBundleIdentifier
    }

    public func read() throws -> DockState {
        switch source {
        case .live:
            try readLive()
        case .file(let url):
            try readFile(url)
        }
    }

    // MARK: - Live domain

    private static var applicationID: CFString { "com.apple.dock" as CFString }

    private func readLive() throws -> DockState {
        // Flush pending writes so the copy sees the latest domain. False means
        // there was nothing to flush; the values below are still the domain.
        _ = CFPreferencesAppSynchronize(Self.applicationID)
        var domain: [String: Any] = [:]
        for section in [DockSection.apps, .others] {
            if let value = try preferenceValue(for: section) {
                domain[section.plistKey] = value
            }
        }
        return DockPlistParser.parse(domain: domain, resolvingBundleIdentifier: resolveBundleIdentifier)
    }

    private func preferenceValue(for section: DockSection) throws -> Any? {
        let value = CFPreferencesCopyAppValue(section.plistKey as CFString, Self.applicationID)
        if let value, DockPlistValues.array(value) == nil {
            throw DockReadError.unreadablePreferences(key: section.plistKey)
        }
        return value
    }

    // MARK: - Plist file

    private func readFile(_ url: URL) throws -> DockState {
        // Canonicalize before opening. dockutil compares plist paths as strings,
        // so a symlink, `..`, or `//` must not be treated as a different file.
        let url = url.resolvingSymlinksInPath().standardized
        let path = url.path(percentEncoded: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DockReadError.unreadableFile(path)
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw DockReadError.unreadableFile(path)
        }
        guard let domain = DockPlistValues.dictionary(plist) else {
            throw DockReadError.unreadableFile(path)
        }
        return DockPlistParser.parse(domain: domain, resolvingBundleIdentifier: resolveBundleIdentifier)
    }
}
