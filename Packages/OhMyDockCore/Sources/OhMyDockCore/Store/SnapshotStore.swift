import CryptoKit
import Foundation

// MARK: - Dock domain I/O

public protocol DockDomainIO: Sendable {
    func exportDomain(to url: URL) async throws
    func importDomain(from url: URL) async throws
    func deleteKey(_ key: String) async throws
}

public extension DockDomainIO {
    func deleteKey(_ key: String) async throws {
        throw DockDomainIOError.deleteKeyUnsupported(key)
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var terminationStatus: Int32
    public var stdout: String
    public var standardError: String

    public init(
        terminationStatus: Int32,
        standardError: String,
        stdout: String = ""
    ) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.standardError = standardError
    }
}

public protocol ProcessRunner: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult
}

public enum DockDomainIOError: Error, Equatable, Sendable {
    case invalidFileURL(String)
    case deleteKeyUnsupported(String)
    case launchFailed(executablePath: String, message: String)
    case commandFailed(arguments: [String], exitStatus: Int32, standardError: String)
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        async let outputData = Self.readToEnd(of: standardOutput.fileHandleForReading)
        async let errorData = Self.readToEnd(of: standardError.fileHandleForReading)
        process.waitUntilExit()
        let (capturedOutput, capturedError) = await (outputData, errorData)
        let stdout = String(decoding: capturedOutput, as: UTF8.self)
        let stderr = String(decoding: capturedError, as: UTF8.self)

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            // dockutil reports some failures only on stdout. Preserve the existing
            // diagnostic field's usefulness for callers that predate `stdout`.
            standardError: stderr.isEmpty ? stdout : stderr,
            stdout: stdout
        )
    }

    private static func readToEnd(of fileHandle: FileHandle) async -> Data {
        await Task.detached {
            fileHandle.readDataToEndOfFile()
        }.value
    }
}

public struct LiveDockDomainIO: DockDomainIO {
    public static let executableURL = URL(fileURLWithPath: "/usr/bin/defaults")

    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner = FoundationProcessRunner()) {
        self.processRunner = processRunner
    }

    public func exportDomain(to url: URL) async throws {
        try await run(arguments: ["export", "com.apple.dock", try absolutePath(for: url)])
    }

    public func importDomain(from url: URL) async throws {
        try await run(arguments: ["import", "com.apple.dock", try absolutePath(for: url)])
    }

    public func deleteKey(_ key: String) async throws {
        try await run(arguments: ["delete", "com.apple.dock", key])
    }

    private func run(arguments: [String]) async throws {
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executableURL: Self.executableURL,
                arguments: arguments
            )
        } catch {
            throw DockDomainIOError.launchFailed(
                executablePath: Self.executableURL.path,
                message: String(describing: error)
            )
        }

        guard result.terminationStatus == 0 else {
            throw DockDomainIOError.commandFailed(
                arguments: arguments,
                exitStatus: result.terminationStatus,
                standardError: result.standardError
            )
        }
    }

    private func absolutePath(for url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DockDomainIOError.invalidFileURL(url.absoluteString)
        }
        return url.standardizedFileURL.path
    }
}

// MARK: - Snapshots

public struct Snapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var reason: String
    public var profileName: String?
    public var byteSize: Int
    public var sha256: String
    public var pinned: Bool

    public init(
        id: UUID,
        createdAt: Date,
        reason: String,
        profileName: String? = nil,
        byteSize: Int,
        sha256: String,
        pinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.profileName = profileName
        self.byteSize = byteSize
        self.sha256 = sha256
        self.pinned = pinned
    }
}

public enum SnapshotValidationError: Error, Equatable, Sendable {
    case malformedPlist
    case expectedDictionary
    case missingPersistentAppsArray
    case missingPersistentOthersArray
}

public enum SnapshotStoreError: Error, Equatable, Sendable {
    case snapshotNotFound(UUID)
    case plistMissing(UUID)
    case metadataMissing(UUID)
    case metadataIDMismatch(expected: UUID, actual: UUID)
    case invalidMetadata(UUID)
    case invalidExport(SnapshotValidationError)
    case exportTooLarge(actualBytes: Int, maximumBytes: Int)
    case byteSizeMismatch(id: UUID, expected: Int, actual: Int)
    case checksumMismatch(id: UUID, expected: String, actual: String)
    case restoreVerificationFailed(UUID)
    case invalidKeepCount(Int)
}

public actor SnapshotStore {
    public struct ListResult: Sendable {
        public var snapshots: [Snapshot]
        public var failures: [(url: URL, error: any Error)]

        public init(snapshots: [Snapshot], failures: [(url: URL, error: any Error)]) {
            self.snapshots = snapshots
            self.failures = failures
        }
    }

    public static let maximumSnapshotBytes = 10 * 1_024 * 1_024

    private let rootURL: URL
    private let domainIO: any DockDomainIO
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let retentionLimit: Int

    public init(
        rootDirectory: URL = SnapshotStore.defaultDirectory(),
        domainIO: any DockDomainIO = LiveDockDomainIO(),
        fileManager: FileManager = .default,
        retentionLimit: Int = 50,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(retentionLimit >= 0, "retentionLimit must not be negative")
        self.rootURL = rootDirectory
        self.domainIO = domainIO
        self.fileManager = fileManager
        self.retentionLimit = retentionLimit
        self.now = now
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oh-my-dock/snapshots", isDirectory: true)
    }

    @discardableResult
    public func save(
        reason: String,
        profileName: String? = nil,
        pinned: Bool = false
    ) async throws -> Snapshot {
        try ensureRootDirectoryExists()

        let id = UUID()
        let temporaryURL = rootURL.appendingPathComponent(
            ".tmp-export-\(id.uuidString).plist",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try await domainIO.exportDomain(to: temporaryURL)
        let data = try Data(contentsOf: temporaryURL)
        guard data.count <= Self.maximumSnapshotBytes else {
            throw SnapshotStoreError.exportTooLarge(
                actualBytes: data.count,
                maximumBytes: Self.maximumSnapshotBytes
            )
        }
        try validatePlist(data)

        let snapshot = Snapshot(
            id: id,
            createdAt: now(),
            reason: reason,
            profileName: profileName,
            byteSize: data.count,
            sha256: sha256(of: data),
            pinned: pinned
        )
        let plistURL = self.plistURL(for: id)

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        try fileManager.moveItem(at: temporaryURL, to: plistURL)

        do {
            try writeMetadata(snapshot)
        } catch {
            try? fileManager.removeItem(at: plistURL)
            throw error
        }
        try prune(keep: retentionLimit, preserving: snapshot.id)
        return snapshot
    }

    public func list() -> ListResult {
        do {
            try ensureRootDirectoryExists()
        } catch {
            return ListResult(snapshots: [], failures: [(rootURL, error)])
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ListResult(snapshots: [], failures: [(rootURL, error)])
        }

        let ids = Set(entries.compactMap(snapshotID(from:)))
        var snapshots: [Snapshot] = []
        var failures: [(URL, any Error)] = []

        for id in ids {
            let metadataURL = self.metadataURL(for: id)
            let plistURL = self.plistURL(for: id)
            do {
                guard fileManager.fileExists(atPath: metadataURL.path) else {
                    throw SnapshotStoreError.metadataMissing(id)
                }
                let snapshot = try loadMetadata(id: id)
                guard fileManager.fileExists(atPath: plistURL.path) else {
                    throw SnapshotStoreError.plistMissing(id)
                }
                let data = try Data(contentsOf: plistURL)
                try verify(data: data, against: snapshot)
                snapshots.append(snapshot)
            } catch {
                let failureURL = fileManager.fileExists(atPath: metadataURL.path)
                    ? metadataURL
                    : plistURL
                failures.append((failureURL, error))
            }
        }

        snapshots.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
        failures.sort { $0.0.path < $1.0.path }
        return ListResult(snapshots: snapshots, failures: failures)
    }

    public func load(id: UUID) throws -> Data {
        let url = plistURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SnapshotStoreError.snapshotNotFound(id)
        }
        return try Data(contentsOf: url)
    }

    public func restore(id: UUID, createSafetySnapshot: Bool = true) async throws {
        let snapshot = try loadMetadata(id: id)
        let data = try load(id: id)
        try verify(data: data, against: snapshot)
        let targetDictionary = try validatedPlistDictionary(data)

        if createSafetySnapshot {
            let date = Self.restoreDateString(now())
            try await save(reason: "Before restoring \(date)")
        }

        try ensureRootDirectoryExists()
        let restoreURL = rootURL.appendingPathComponent(
            ".tmp-restore-\(UUID().uuidString).plist",
            isDirectory: false
        )
        let currentURL = rootURL.appendingPathComponent(
            ".tmp-current-\(UUID().uuidString).plist",
            isDirectory: false
        )
        let verificationURL = rootURL.appendingPathComponent(
            ".tmp-verification-\(UUID().uuidString).plist",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: restoreURL)
            try? fileManager.removeItem(at: currentURL)
            try? fileManager.removeItem(at: verificationURL)
        }

        try await domainIO.exportDomain(to: currentURL)
        let currentData = try Data(contentsOf: currentURL)
        let currentDictionary = try plistDictionary(currentData)
        let keysToDelete = Set(currentDictionary.keys)
            .subtracting(targetDictionary.keys)
            .sorted()
        for key in keysToDelete {
            try await domainIO.deleteKey(key)
        }

        try data.write(to: restoreURL, options: [])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: restoreURL.path
        )
        try await domainIO.importDomain(from: restoreURL)

        try await domainIO.exportDomain(to: verificationURL)
        let restoredData = try Data(contentsOf: verificationURL)
        let restoredDictionary = try plistDictionary(restoredData)
        guard NSDictionary(dictionary: restoredDictionary).isEqual(to: targetDictionary) else {
            throw SnapshotStoreError.restoreVerificationFailed(id)
        }
    }

    public func delete(id: UUID) throws {
        let metadataURL = self.metadataURL(for: id)
        let plistURL = self.plistURL(for: id)
        let hasMetadata = fileManager.fileExists(atPath: metadataURL.path)
        let hasPlist = fileManager.fileExists(atPath: plistURL.path)
        guard hasMetadata || hasPlist else {
            throw SnapshotStoreError.snapshotNotFound(id)
        }
        if hasMetadata {
            try fileManager.removeItem(at: metadataURL)
        }
        if hasPlist {
            try fileManager.removeItem(at: plistURL)
        }
    }

    public func prune(keep: Int = 50) throws {
        try prune(keep: keep, preserving: nil)
    }

    private func prune(keep: Int, preserving protectedID: UUID?) throws {
        guard keep >= 0 else {
            throw SnapshotStoreError.invalidKeepCount(keep)
        }

        let snapshots = list().snapshots
        guard let newest = snapshots.first else { return }

        let protectedSnapshot = snapshots.first {
            $0.id == (protectedID ?? newest.id)
        }
        let protectedUnpinnedID = protectedSnapshot?.pinned == false
            ? protectedSnapshot?.id
            : nil
        let remainingSlots = max(keep - (protectedUnpinnedID == nil ? 0 : 1), 0)
        var retainedUnpinned = Set(
            snapshots.lazy
                .filter { !$0.pinned && $0.id != protectedUnpinnedID }
                .prefix(remainingSlots)
                .map(\.id)
        )
        if let protectedUnpinnedID {
            retainedUnpinned.insert(protectedUnpinnedID)
        }
        let protectedSnapshotID = protectedID ?? newest.id

        for snapshot in snapshots
        where !snapshot.pinned
            && snapshot.id != protectedSnapshotID
            && !retainedUnpinned.contains(snapshot.id)
        {
            try delete(id: snapshot.id)
        }
    }

    public func pin(id: UUID) throws {
        try setPinned(true, id: id)
    }

    public func unpin(id: UUID) throws {
        try setPinned(false, id: id)
    }

    // MARK: - Paths & I/O

    private func plistURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).plist", isDirectory: false)
    }

    private func metadataURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func snapshotID(from url: URL) -> UUID? {
        guard url.pathExtension == "plist" || url.pathExtension == "json" else {
            return nil
        }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func ensureRootDirectoryExists() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func loadMetadata(id: UUID) throws -> Snapshot {
        let url = metadataURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            let plistExists = fileManager.fileExists(atPath: plistURL(for: id).path)
            throw plistExists
                ? SnapshotStoreError.metadataMissing(id)
                : SnapshotStoreError.snapshotNotFound(id)
        }

        let snapshot: Snapshot
        do {
            let data = try Data(contentsOf: url)
            snapshot = try Self.decoder.decode(Snapshot.self, from: data)
        } catch is DecodingError {
            throw SnapshotStoreError.invalidMetadata(id)
        }
        guard snapshot.id == id else {
            throw SnapshotStoreError.metadataIDMismatch(expected: id, actual: snapshot.id)
        }
        guard snapshot.byteSize >= 0,
              snapshot.sha256.count == 64,
              snapshot.sha256.allSatisfy({ $0.isHexDigit })
        else {
            throw SnapshotStoreError.invalidMetadata(id)
        }
        return snapshot
    }

    private func writeMetadata(_ snapshot: Snapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        try writeAtomically(data: data, to: metadataURL(for: snapshot.id))
    }

    private func setPinned(_ pinned: Bool, id: UUID) throws {
        var snapshot = try loadMetadata(id: id)
        guard fileManager.fileExists(atPath: plistURL(for: id).path) else {
            throw SnapshotStoreError.plistMissing(id)
        }
        snapshot.pinned = pinned
        try writeMetadata(snapshot)
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        try ensureRootDirectoryExists()
        let temporaryURL = rootURL.appendingPathComponent(
            ".tmp-\(UUID().uuidString).json",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: [])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private func validatePlist(_ data: Data) throws {
        _ = try validatedPlistDictionary(data)
    }

    private func validatedPlistDictionary(_ data: Data) throws -> [String: Any] {
        let dictionary = try plistDictionary(data)
        guard dictionary["persistent-apps"] is [Any] else {
            throw SnapshotStoreError.invalidExport(.missingPersistentAppsArray)
        }
        guard dictionary["persistent-others"] is [Any] else {
            throw SnapshotStoreError.invalidExport(.missingPersistentOthersArray)
        }
        return dictionary
    }

    private func plistDictionary(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw SnapshotStoreError.invalidExport(.malformedPlist)
        }
        guard let dictionary = object as? [String: Any] else {
            throw SnapshotStoreError.invalidExport(.expectedDictionary)
        }
        return dictionary
    }

    private func verify(data: Data, against snapshot: Snapshot) throws {
        let actualHash = sha256(of: data)
        guard actualHash == snapshot.sha256 else {
            throw SnapshotStoreError.checksumMismatch(
                id: snapshot.id,
                expected: snapshot.sha256,
                actual: actualHash
            )
        }
        guard data.count == snapshot.byteSize else {
            throw SnapshotStoreError.byteSizeMismatch(
                id: snapshot.id,
                expected: snapshot.byteSize,
                actual: data.count
            )
        }
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func restoreDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
