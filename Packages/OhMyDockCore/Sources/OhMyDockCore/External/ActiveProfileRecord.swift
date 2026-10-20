import Foundation

public protocol ActiveProfileRecording: Sendable {
    func load() -> UUID?
    func save(_ id: UUID?)
}

public final class InMemoryActiveProfileRecord: ActiveProfileRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?

    public init(_ id: UUID? = nil) { self.id = id }

    public func load() -> UUID? { lock.withLock { id } }
    public func save(_ id: UUID?) { lock.withLock { self.id = id } }
}

/// `{"profileID": "…"}` in a small JSON file under Application Support.
public struct FileActiveProfileRecord: ActiveProfileRecording {
    private struct Payload: Codable { var profileID: UUID? }

    public let url: URL

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try SupportPaths.activeProfileURL(fileManager: fileManager)
    }

    public init(url: URL) { self.url = url }

    public init(fileManager: FileManager = .default) throws {
        try self.init(url: Self.defaultURL(fileManager: fileManager))
    }

    public func load() -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.profileID
    }

    public func save(_ id: UUID?) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Payload(profileID: id)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
