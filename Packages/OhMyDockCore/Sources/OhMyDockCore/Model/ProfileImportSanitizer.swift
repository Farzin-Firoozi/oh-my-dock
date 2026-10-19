import Foundation

/// One thing `Profile.sanitizedForImport()` removed or changed. Indexes refer to the tile's
/// position in the profile as it was handed in.
public enum ImportSanitizationChange: Hashable, Sendable {
    public enum DropReason: Hashable, Sendable {
        /// A tile type the model does not cover.
        case unknownTile
        /// A URL that is not `https`, has no host, or carries credentials.
        case disallowedURL
        /// A path that is not absolute and normalized, or is not under the home directory.
        case disallowedPath
        /// An app tile with neither a bundle id nor a usable path.
        case missingAppIdentity
        /// A string over the size cap that cannot be shortened without changing what it means.
        case stringTooLong
        /// Dockutil refuses a second tile with the same label.
        case duplicateLabel
    }

    case droppedItem(DockSection, index: Int, reason: DropReason)
    /// Valid tiles past the per-section cap were dropped.
    case droppedItemsOverLimit(DockSection, dropped: Int)
    case clearedAppPath(DockSection, index: Int)
    case clearedBrewCask(DockSection, index: Int)
    case clearedLaunchOnSwitch(DockSection, index: Int)
    case truncatedString(field: String)
    case forcedQuitScopeNone(was: SwitchingOptions.QuitScope)
    case clearedOfferForceQuit
    case idReassigned
}

public enum ImportSanitizationError: Error, Hashable, Sendable {
    /// What is left after sanitizing is still not a valid profile (empty name, bad prefs, ...).
    case invalidProfile(ProfileValidationError)
}

public struct SanitizedProfile: Equatable, Sendable {
    public var profile: Profile
    /// Everything removed or changed, in the order it was found. Empty when the input was
    /// already safe, apart from the fresh `id`.
    public var changes: [ImportSanitizationChange]
}

extension Profile {
    public static let maxImportItemsPerSection = 200
    /// Paths and URLs.
    public static let maxImportLocationLength = 1_024
    /// Labels, app names, bundle ids and cask names.
    public static let maxImportTextLength = 256

    /// A copy that is safe to store and apply when the profile came from outside this machine
    /// (a gallery download, a shared file). The original is not modified.
    ///
    /// - URLs must be `https` with a host and no credentials.
    /// - Folder and file paths, and app path hints, must be absolute, normalized and strictly
    ///   under `homeDirectory`. A bad folder/file tile is dropped; a bad app path hint is
    ///   cleared, since apps resolve by bundle id.
    /// - `.unknown` tiles are dropped; sections are capped at `maxImportItemsPerSection`;
    ///   paths and URLs over `maxImportLocationLength` drop their tile; names, labels and ids
    ///   over `maxImportTextLength` are shortened (labels, names) or cleared (cask, which must
    ///   also look like a cask token) or drop the tile (bundle id).
    /// - Switching cannot quit anything (`quitScope = .none`, `offerForceQuit = false`) and no
    ///   app launches on switch.
    /// - The profile gets a fresh `id` so an import can never overwrite a local profile.
    ///
    /// Paths are checked as text; symlinks are not resolved.
    ///
    /// - Throws: `ImportSanitizationError.invalidProfile` when the result still fails
    ///   `validate()`.
    public func sanitizedForImport(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(ImportSanitizationError) -> SanitizedProfile {
        var sanitizer = ProfileImportSanitizer(home: homeDirectory.standardizedFileURL.path)
        return try sanitizer.run(self)
    }
}

private struct ProfileImportSanitizer {
    let home: String
    var changes: [ImportSanitizationChange] = []

    init(home: String) {
        self.home = home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    mutating func run(_ input: Profile) throws(ImportSanitizationError) -> SanitizedProfile {
        var profile = input
        profile.id = UUID()
        changes.append(.idReassigned)

        profile.name = truncated(profile.name, to: Profile.maxNameLength, field: "name")
        profile.apps = sanitize(input.apps, in: .apps)
        profile.others = sanitize(input.others, in: .others)

        if profile.switching.quitScope != .none {
            changes.append(.forcedQuitScopeNone(was: profile.switching.quitScope))
            profile.switching.quitScope = .none
        }
        if profile.switching.offerForceQuit {
            changes.append(.clearedOfferForceQuit)
            profile.switching.offerForceQuit = false
        }

        do {
            try profile.validate()
        } catch {
            throw .invalidProfile(error)
        }
        return SanitizedProfile(profile: profile, changes: changes)
    }

    private mutating func sanitize(_ items: [DockItem], in section: DockSection) -> [DockItem] {
        var kept: [DockItem] = []
        var labels: Set<String> = []
        var overLimit = 0

        for (index, item) in items.enumerated() {
            guard let clean = sanitize(item, in: section, at: index) else { continue }
            if !clean.isSpacer {
                let label = DockutilPlanner.computedLabel(of: clean)
                if !label.isEmpty, !labels.insert(label).inserted {
                    changes.append(.droppedItem(section, index: index, reason: .duplicateLabel))
                    continue
                }
            }
            if kept.count >= Profile.maxImportItemsPerSection {
                overLimit += 1
                continue
            }
            kept.append(clean)
        }
        if overLimit > 0 {
            changes.append(.droppedItemsOverLimit(section, dropped: overLimit))
        }
        return kept
    }

    private mutating func sanitize(_ item: DockItem, in section: DockSection, at index: Int) -> DockItem? {
        switch item {
        case .unknown:
            return drop(section, index, .unknownTile)
        case .spacer:
            return item
        case .url(var url):
            guard Self.isAllowed(url.url) else { return drop(section, index, .disallowedURL) }
            guard url.url.absoluteString.count <= Profile.maxImportLocationLength else {
                return drop(section, index, .stringTooLong)
            }
            url.label = label(url.label)
            return .url(url)
        case .folder(var folder):
            guard isUnderHome(folder.path) else { return drop(section, index, .disallowedPath) }
            guard folder.path.count <= Profile.maxImportLocationLength else {
                return drop(section, index, .stringTooLong)
            }
            folder.label = label(folder.label)
            return .folder(folder)
        case .file(var file):
            guard isUnderHome(file.path) else { return drop(section, index, .disallowedPath) }
            guard file.path.count <= Profile.maxImportLocationLength else {
                return drop(section, index, .stringTooLong)
            }
            file.label = label(file.label)
            return .file(file)
        case .app(var app):
            guard app.bundleId.count <= Profile.maxImportTextLength else {
                return drop(section, index, .stringTooLong)
            }
            if let path = app.path,
               !isUnderHome(path) || path.count > Profile.maxImportLocationLength {
                app.path = nil
                changes.append(.clearedAppPath(section, index: index))
            }
            if app.bundleId.isEmpty, (app.path ?? "").isEmpty {
                return drop(section, index, .missingAppIdentity)
            }
            if let cask = app.brewCask, !Self.isCaskToken(cask) {
                app.brewCask = nil
                changes.append(.clearedBrewCask(section, index: index))
            }
            if app.launchOnSwitch {
                app.launchOnSwitch = false
                changes.append(.clearedLaunchOnSwitch(section, index: index))
            }
            app.name = truncated(app.name, to: Profile.maxImportTextLength, field: "app name")
            return .app(app)
        }
    }

    private mutating func drop(
        _ section: DockSection,
        _ index: Int,
        _ reason: ImportSanitizationChange.DropReason
    ) -> DockItem? {
        changes.append(.droppedItem(section, index: index, reason: reason))
        return nil
    }

    private mutating func label(_ label: String?) -> String? {
        label.map { truncated($0, to: Profile.maxImportTextLength, field: "label") }
    }

    private mutating func truncated(_ string: String, to limit: Int, field: String) -> String {
        guard string.count > limit else { return string }
        changes.append(.truncatedString(field: field))
        return String(string.prefix(limit))
    }

    private static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && !(url.host() ?? "").isEmpty
            && url.user() == nil
            && url.password() == nil
    }

    /// Absolute, no `.`/`..` components, and a strict descendant of the home directory
    /// (compared by path component, so `/Users/mehack` is not under `/Users/me`).
    private func isUnderHome(_ path: String) -> Bool {
        guard Profile.isAbsolutePath(path) else { return false }
        let homeParts = home.split(separator: "/")
        let parts = path.split(separator: "/")
        return parts.count > homeParts.count && parts.starts(with: homeParts)
    }

    /// Homebrew cask tokens: lowercase letters, digits, `-`, `@`, `+`, `.`, `_`, optionally
    /// tap-qualified with `/`. Nothing that could be read as an option or a path escape.
    private static func isCaskToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= maxCaskLength, !token.hasPrefix("-"), !token.contains("..") else {
            return false
        }
        return token.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || "-@+._/".unicodeScalars.contains(scalar)
        }
    }

    private static let maxCaskLength = 128
}
