import Foundation
import OhMyDockCore

/// Builds `AppRef` values from application bundle URLs (shared by drops, pickers and Spotlight).
enum ApplicationReference {
    static func appRef(at url: URL) -> AppRef? {
        let url = url.standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppRef(bundleId: bundle?.bundleIdentifier ?? "", name: name, path: url.path)
    }
}
