import Foundation

/// Remembers which profile was applied last, so the menu bar can mark the right one active after
/// a relaunch even when several profiles describe the same Dock.
protocol ActiveProfileRecording: Sendable {
    func load() -> UUID?
    /// Pass nil to forget (after an undo, or when nothing was applied).
    func save(_ id: UUID?)
}

/// Keeps nothing; the default for tests and previews.
final class InMemoryActiveProfileRecord: ActiveProfileRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?

    init(_ id: UUID? = nil) { self.id = id }

    func load() -> UUID? { lock.withLock { id } }
    func save(_ id: UUID?) { lock.withLock { self.id = id } }
}

/// `{"profileID": "…"}` in a small JSON file under Application Support.
struct FileActiveProfileRecord: ActiveProfileRecording {
    private struct Payload: Codable { var profileID: UUID? }

    let url: URL

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oh-my-dock/active-profile.json", isDirectory: false)
    }

    init(url: URL = FileActiveProfileRecord.defaultURL()) { self.url = url }

    func load() -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.profileID
    }

    func save(_ id: UUID?) {
        // Best effort: losing this only costs the preference between look-alike profiles.
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Payload(profileID: id)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
