import Foundation

public protocol SpentUndoRecording: Sendable {
    func load() -> Set<UUID>
    func save(_ ids: Set<UUID>)
}

public final class InMemorySpentUndoRecord: SpentUndoRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID>

    public init(_ ids: Set<UUID> = []) { self.ids = ids }

    public func load() -> Set<UUID> { lock.withLock { ids } }
    public func save(_ ids: Set<UUID>) { lock.withLock { self.ids = ids } }
}

/// `{"spent": ["…"]}` next to `active-profile.json`.
public struct FileSpentUndoRecord: SpentUndoRecording {
    private struct Payload: Codable { var spent: [UUID] }

    public let url: URL

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try SupportPaths.spentUndoURL(fileManager: fileManager)
    }

    public init(url: URL) { self.url = url }

    public init(fileManager: FileManager = .default) throws {
        try self.init(url: Self.defaultURL(fileManager: fileManager))
    }

    public func load() -> Set<UUID> {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return Set(payload.spent)
    }

    public func save(_ ids: Set<UUID>) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sorted = ids.sorted { $0.uuidString < $1.uuidString }
        guard let data = try? JSONEncoder().encode(Payload(spent: sorted)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
