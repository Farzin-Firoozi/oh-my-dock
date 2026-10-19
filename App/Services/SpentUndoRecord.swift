import Foundation

/// Remembers which snapshots an undo has already used up, across relaunches, so the safety
/// snapshot an undo leaves behind is not offered as the next Undo target after a restart.
protocol SpentUndoRecording: Sendable {
    /// A missing or unreadable record is an empty set.
    func load() -> Set<UUID>
    func save(_ ids: Set<UUID>)
}

final class InMemorySpentUndoRecord: SpentUndoRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID>

    init(_ ids: Set<UUID> = []) { self.ids = ids }

    func load() -> Set<UUID> { lock.withLock { ids } }
    func save(_ ids: Set<UUID>) { lock.withLock { self.ids = ids } }
}

/// `{"spent": ["…"]}` in a small JSON file under Application Support, next to `active-profile.json`.
struct FileSpentUndoRecord: SpentUndoRecording {
    private struct Payload: Codable { var spent: [UUID] }

    let url: URL

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oh-my-dock/undo-spent.json", isDirectory: false)
    }

    init(url: URL = FileSpentUndoRecord.defaultURL()) { self.url = url }

    func load() -> Set<UUID> {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return Set(payload.spent)
    }

    func save(_ ids: Set<UUID>) {
        // Best effort: losing this only means Undo may be offered once more after a relaunch.
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Payload(spent: ids.map { $0 }.sorted { $0.uuidString < $1.uuidString })) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
