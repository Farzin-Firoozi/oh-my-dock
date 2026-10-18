import Foundation

public enum OhMyDockCore {
    public static let version = "0.0.1"
}

public struct BundledTools {
    /// Relative location of the bundled dockutil inside an app bundle.
    static let dockutilRelativePath = "Contents/Helpers/dockutil"

    /// URL of the bundled dockutil in `bundle`, or nil if missing or not executable.
    public static func dockutilURL(in bundle: Bundle = .main) -> URL? {
        dockutilURL(inBundleAt: bundle.bundleURL)
    }

    /// Testable variant that takes the `.app` bundle directory directly.
    public static func dockutilURL(inBundleAt bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent(dockutilRelativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }
}
