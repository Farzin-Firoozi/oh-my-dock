import Foundation

public enum DockPlistEnvironmentError: Error, Equatable, Sendable {
    case liveDockPlistRefused
}

public enum DockPlistEnvironment {
    public static let overrideKey = "OHMYDOCK_DOCK_PLIST"

    public static var liveDockPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist", isDirectory: false)
            .standardizedFileURL
    }

    /// Returns the override path when set and not the live Dock plist; throws before any Dock API use.
    public static func resolvedOverridePlist() throws -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[overrideKey], !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        let resolvedPath = url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        if DockPlistLiveDetection.aliasesLiveDockPlist(resolvedPath) {
            throw DockPlistEnvironmentError.liveDockPlistRefused
        }
        return url
    }
}
