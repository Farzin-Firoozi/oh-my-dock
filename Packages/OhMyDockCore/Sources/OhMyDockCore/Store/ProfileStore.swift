import Foundation

// MARK: - Migration

public enum ProfileMigrationError: Error, Hashable, Sendable {
    case unsupportedSourceVersion(Int)
}

/// Upgrades on-disk profile JSON from an older `schemaVersion` toward the current model version.
public protocol ProfileMigrator: Sendable {
    func migrate(jsonData: Data, from schemaVersion: Int) throws -> Data
}

/// v1 profiles need no transformation; older versions require a custom migrator.
public struct DefaultProfileMigrator: ProfileMigrator {
    public init() {}

    public func migrate(jsonData: Data, from schemaVersion: Int) throws -> Data {
        if schemaVersion >= Profile.currentSchemaVersion {
            return jsonData
        }
        throw ProfileMigrationError.unsupportedSourceVersion(schemaVersion)
    }
}

// MARK: - Store

public enum ProfileStoreError: Error, Hashable, Sendable, LocalizedError {
    case profileNotFound(UUID)
    /// Another profile already uses this hotkey; `profileName` is that profile.
    case hotkeyInUse(profileName: String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound: "That profile no longer exists."
        case let .hotkeyInUse(name): "That shortcut is already used by “\(name)”."
        }
    }
}

public actor ProfileStore {
    public struct ListResult: Sendable {
        public var profiles: [Profile]
        public var failures: [(url: URL, error: any Error)]

        public init(profiles: [Profile], failures: [(url: URL, error: any Error)]) {
            self.profiles = profiles
            self.failures = failures
        }
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let migrator: any ProfileMigrator

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        migrator: any ProfileMigrator = DefaultProfileMigrator()
    ) {
        self.rootURL = rootDirectory
        self.fileManager = fileManager
        self.migrator = migrator
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        (try? SupportPaths.profilesDirectory(fileManager: fileManager))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("oh-my-dock/profiles", isDirectory: true)
    }

    public func list() -> ListResult {
        ensureRootDirectoryExists()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ListResult(profiles: [], failures: [])
        }

        var profiles: [Profile] = []
        var failures: [(URL, any Error)] = []

        for url in entries where isProfileFile(url) {
            do {
                let profile = try loadProfile(from: url)
                profiles.append(profile)
            } catch {
                failures.append((url, error))
            }
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ListResult(profiles: profiles, failures: failures)
    }

    public func load(id: UUID) throws -> Profile {
        let url = profileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        return try loadProfile(from: url)
    }

    public func save(_ profile: Profile) throws {
        // Local profiles keep the live Dock's tiles the model cannot describe.
        try profile.validate(allowingUnknownTiles: true)
        _ = ensureRootDirectoryExists()
        let data = try profile.jsonData()
        let url = profileURL(for: profile.id)
        try writeAtomically(data: data, to: url)
    }

    /// Loads the stored profile, applies `transform`, validates and saves it, all within one
    /// store call, so concurrent writers each change their own fields instead of overwriting
    /// each other with stale whole profiles. The profile keeps its id whatever `transform` does.
    @discardableResult
    public func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        var profile = try load(id: id)
        try transform(&profile)
        profile.id = id
        try save(profile)
        return profile
    }

    /// Sets or clears the hotkey of `id`. Fails with `hotkeyInUse` when another profile has it.
    @discardableResult
    public func setHotkey(id: UUID, to hotkey: Hotkey?) throws -> Profile {
        if let hotkey,
           let other = list().profiles.first(where: { $0.id != id && $0.hotkey == hotkey })
        {
            throw ProfileStoreError.hotkeyInUse(profileName: other.name)
        }
        return try update(id: id) { $0.hotkey = hotkey }
    }

    public func contentModificationDate(for id: UUID) throws -> Date? {
        let url = profileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func delete(id: UUID) throws {
        let url = profileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        try fileManager.removeItem(at: url)
    }

    public func rename(id: UUID, newName: String) throws {
        var profile = try load(id: id)
        profile.name = newName
        try save(profile)
    }

    @discardableResult
    public func duplicate(id: UUID, newName: String) throws -> Profile {
        var profile = try load(id: id)
        profile.id = UUID()
        profile.name = newName
        try save(profile)
        return profile
    }

    public func exists(id: UUID) -> Bool {
        fileManager.fileExists(atPath: profileURL(for: id).path)
    }

    /// First profile whose name matches `name`, compared case-insensitively.
    public func profile(named name: String) -> Profile? {
        list().profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Paths & I/O

    private func profileURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func isProfileFile(_ url: URL) -> Bool {
        guard url.pathExtension == "json" else { return false }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    @discardableResult
    private func ensureRootDirectoryExists() -> Bool {
        if fileManager.fileExists(atPath: rootURL.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            return true
        }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }

    private func loadProfile(from url: URL) throws -> Profile {
        let data = try Data(contentsOf: url)
        let migrated = try migrateToCurrentSchema(data)
        return try Profile(jsonData: migrated)
    }

    private func migrateToCurrentSchema(_ data: Data) throws -> Data {
        var json = data
        var version = try schemaVersion(in: json)
        while version < Profile.currentSchemaVersion {
            json = try migrator.migrate(jsonData: json, from: version)
            version = try schemaVersion(in: json)
        }
        return json
    }

    private func schemaVersion(in data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected JSON object"))
        }
        guard let version = dict["schemaVersion"] as? Int else {
            struct MissingSchemaVersion: Error {}
            throw MissingSchemaVersion()
        }
        return version
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        defer {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        try data.write(to: tempURL, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
