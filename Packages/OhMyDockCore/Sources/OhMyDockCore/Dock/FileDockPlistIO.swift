import Foundation

// MARK: - Snapshot / domain file I/O

/// Reads and writes a single Dock plist **file** (no `defaults` / `com.apple.dock` domain).
public struct FileDockDomainIO: DockDomainIO {
    public let plistURL: URL

    public init(plistURL: URL) {
        self.plistURL = plistURL.standardizedFileURL
    }

    public func exportDomain(to url: URL) async throws {
        let data = try readPlistData()
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func importDomain(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        try writePlistData(data)
    }

    public func deleteKey(_ key: String) async throws {
        var dictionary = try readPlistDictionary()
        dictionary.removeValue(forKey: key)
        try writePlistDictionary(dictionary)
    }

    private func readPlistData() throws -> Data {
        if !FileManager.default.fileExists(atPath: plistURL.path) {
            return try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        }
        return try Data(contentsOf: plistURL)
    }

    private func readPlistDictionary() throws -> [String: Any] {
        let data = try readPlistData()
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw DockDomainIOError.invalidFileURL(plistURL.path)
        }
        return dictionary
    }

    private func writePlistData(_ data: Data) throws {
        let directory = plistURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: plistURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    private func writePlistDictionary(_ dictionary: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try writePlistData(data)
    }
}

// MARK: - Managed prefs keys in a plist file

/// Reads and writes Dock preference keys in a plist **file** (no `CFPreferences`).
public final class FileDockPrefsDomainIO: DockPrefsDomainIO, @unchecked Sendable {
    private let plistURL: URL
    private var storage: [String: Any]
    private var dirty = false

    public init(plistURL: URL) {
        self.plistURL = plistURL.standardizedFileURL
        if FileManager.default.fileExists(atPath: plistURL.path),
           let data = try? Data(contentsOf: plistURL),
           let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            storage = dictionary
        } else {
            storage = [:]
        }
    }

    public func synchronize() {
        guard dirty else { return }
        dirty = false
        let directory = plistURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: storage, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: plistURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    public func value(forKey key: String) -> Any? {
        storage[key]
    }

    public func setValue(_ value: Any?, forKey key: String) {
        dirty = true
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func allKeys() -> Set<String> {
        Set(storage.keys)
    }
}
