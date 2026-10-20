import Foundation

public enum SupportPathsError: Error, Equatable, Sendable {
    case relativeSupportDirectory(String)
}

/// Application Support layout for oh-my-dock. Override with `OHMYDOCK_SUPPORT_DIR` (absolute path only).
public enum SupportPaths {
    public static let supportDirEnvironmentKey = "OHMYDOCK_SUPPORT_DIR"

    public static func root(fileManager: FileManager = .default) throws -> URL {
        if let override = OhMyDockProcessEnvironment.string(for: supportDirEnvironmentKey) {
            guard override.hasPrefix("/") else {
                throw SupportPathsError.relativeSupportDirectory(override)
            }
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oh-my-dock", isDirectory: true)
    }

    public static func profilesDirectory(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("profiles", isDirectory: true)
    }

    public static func snapshotsDirectory(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("snapshots", isDirectory: true)
    }

    public static func operationLockURL(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("operation.lock", isDirectory: false)
    }

    public static func previewLockURL(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("preview.lock", isDirectory: false)
    }

    public static func activeProfileURL(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("active-profile.json", isDirectory: false)
    }

    public static func spentUndoURL(fileManager: FileManager = .default) throws -> URL {
        try root(fileManager: fileManager).appendingPathComponent("undo-spent.json", isDirectory: false)
    }

    @discardableResult
    public static func ensureRootExists(fileManager: FileManager = .default) throws -> URL {
        let url = try root(fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}
