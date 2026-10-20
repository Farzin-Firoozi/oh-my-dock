import Darwin
import Foundation
import SystemConfiguration

/// Whether a filesystem path refers to the live Dock plist (symlinks, case variants, hard links).
public enum DockPlistLiveDetection {
    /// Same candidate homes as ``DockutilBackend/defaultLiveDockPlistURLs()``.
    public static func liveDockPlistURLs() -> [URL] {
        var homes = [
            NSHomeDirectory(),
            FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        ]
        if let home = NSHomeDirectoryForUser(NSUserName()) {
            homes.append(home)
        }
        if let console = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?,
           let home = NSHomeDirectoryForUser(console)
        {
            homes.append(home)
        }
        var seen: Set<String> = []
        return homes.filter { seen.insert($0).inserted }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        }
    }

    public static func aliasesLiveDockPlist(_ path: String, candidates: [URL]? = nil) -> Bool {
        for candidate in candidates ?? liveDockPlistURLs() {
            let candidatePaths = [
                candidate.path(percentEncoded: false),
                candidate.resolvingSymlinksInPath().standardized.path(percentEncoded: false),
            ]
            if candidatePaths.contains(where: { $0.lowercased() == path.lowercased() }) {
                return true
            }
            if candidatePaths.contains(where: { isSameFile(path, $0) }) {
                return true
            }
        }
        return false
    }

    private static func isSameFile(_ first: String, _ second: String) -> Bool {
        var a = stat()
        var b = stat()
        guard stat(first, &a) == 0, stat(second, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
