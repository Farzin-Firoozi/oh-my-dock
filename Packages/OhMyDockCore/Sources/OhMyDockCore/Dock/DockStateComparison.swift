import Foundation

public extension DockState {
    /// True when `actual`, re-read from the Dock after a write, is what this (expected) state
    /// asked for.
    ///
    /// The comparison checks order, item kinds, paths and URLs, folder view / display / sort,
    /// spacer kinds, and labels the expected side sets. It ignores what the Dock plist cannot
    /// carry or what dockutil derives itself: `launchOnSwitch`, `brewCask`, `appStoreId`, the
    /// app `name` (dockutil labels the tile), and an empty versus resolved `bundleId`.
    func matchesAfterWrite(_ actual: DockState) -> Bool {
        DockSection.allCases.allSatisfy { section in
            let expected = self[section]
            let actual = actual[section]
            return expected.count == actual.count
                && zip(expected, actual).allSatisfy { $0.matchesAfterWrite($1) }
        }
    }
}

public extension DockItem {
    /// Item-level rule behind ``DockState/matchesAfterWrite(_:)``; `self` is the expected item.
    func matchesAfterWrite(_ actual: DockItem) -> Bool {
        switch (self, actual) {
        case let (.app(expected), .app(actual)):
            return Self.appsMatch(expected, actual)

        case let (.url(expected), .url(actual)):
            return expected.url.absoluteString == actual.url.absoluteString
                && Self.labelMatches(expected: expected.label, actual: actual.label)

        case let (.folder(expected), .folder(actual)):
            return standardizedPath(expected.path) == standardizedPath(actual.path)
                && expected.view == actual.view
                && expected.display == actual.display
                && expected.sort == actual.sort
                && Self.labelMatches(expected: expected.label, actual: actual.label)

        case let (.file(expected), .file(actual)):
            return standardizedPath(expected.path) == standardizedPath(actual.path)
                && Self.labelMatches(expected: expected.label, actual: actual.label)

        case let (.spacer(expected), .spacer(actual)):
            return expected == actual

        case let (.unknown(expected), .unknown(actual)):
            return expected.tileType == actual.tileType
                && Self.labelMatches(expected: expected.label, actual: actual.label)

        default:
            return false
        }
    }

    /// An expected label is a request, so the Dock must carry it. A missing or empty expected
    /// label means "let dockutil derive one", so any actual label is fine.
    private static func labelMatches(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        return expected == actual
    }

    private static func appsMatch(_ expected: AppRef, _ actual: AppRef) -> Bool {
        if let expectedPath = expected.path, let actualPath = actual.path {
            if standardizedPath(expectedPath) == standardizedPath(actualPath) { return true }
            if dockutilRewrote(expectedPath, to: actualPath) { return true }
            // Different location, same app: only the bundle identifier can still say so.
            return !expected.bundleId.isEmpty && expected.bundleId == actual.bundleId
        }
        // A path is missing on one side (a tile without `file-data`): fall back to identity.
        if expected.bundleId != actual.bundleId { return false }
        return !expected.bundleId.isEmpty || expected.name == actual.name
    }

    /// dockutil 3.1.3 (`DockUtil.swift:405-430`) swaps a missing `/Applications/X.app` for
    /// `/System/Applications/X.app`, and resolves Cryptex symlinks (Safari) to
    /// `/System/Volumes/Preboot/Cryptexes/App/System/...`.
    private static func dockutilRewrote(_ requested: String, to written: String) -> Bool {
        let requested = standardizedPath(requested)
        let written = standardizedPath(written)
        guard requested.hasPrefix("/Applications/"),
              (requested as NSString).lastPathComponent == (written as NSString).lastPathComponent
        else { return false }
        return written.hasPrefix("/System/Applications/")
            || written.hasPrefix("/System/Volumes/Preboot/Cryptexes/App/System/")
    }
}
