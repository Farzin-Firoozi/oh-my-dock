import Foundation

/// Bootstraps the application on first launch by capturing the current live Dock
/// state as a safety-net profile named "Default" and creating a pinned snapshot.
public struct FirstLaunchBootstrapper: Sendable {
    public typealias DockReader = @Sendable () async throws -> DockState

    public enum Result: Equatable, Sendable {
        case alreadyCompleted
        case created(profile: Profile, snapshot: Snapshot, droppedItems: [DockItem])
    }

    public let reader: DockReader
    public let profileStore: ProfileStore
    public let snapshotStore: SnapshotStore
    public let markerURL: URL
    public let skipIfProfilesExist: Bool
    private let coordinator: Coordinator

    public init(
        reader: @escaping DockReader = { try DockPlistReader(.live).read() },
        profileStore: ProfileStore,
        snapshotStore: SnapshotStore,
        markerURL: URL = Self.defaultMarkerURL(),
        skipIfProfilesExist: Bool = true
    ) {
        self.reader = reader
        self.profileStore = profileStore
        self.snapshotStore = snapshotStore
        self.markerURL = markerURL
        self.skipIfProfilesExist = skipIfProfilesExist
        self.coordinator = Coordinator()
    }

    public init(
        reader: @escaping DockReader = { try DockPlistReader(.live).read() },
        profileStore: ProfileStore,
        snapshotStore: SnapshotStore,
        markerFileURL: URL,
        skipIfProfilesExist: Bool = true
    ) {
        self.init(
            reader: reader,
            profileStore: profileStore,
            snapshotStore: snapshotStore,
            markerURL: markerFileURL,
            skipIfProfilesExist: skipIfProfilesExist
        )
    }

    public static func defaultMarkerURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oh-my-dock/.first-launch-complete", isDirectory: false)
    }

    /// Resolves an available profile name based on `base` ("Default" by default),
    /// appending ` (2)`, ` (3)`, etc. if a case-insensitive collision exists.
    public func resolveProfileName(base: String = "Default") async -> String {
        let existingProfiles = await profileStore.list().profiles
        let existingNames = Set(existingProfiles.map { $0.name.lowercased() })

        if !existingNames.contains(base.lowercased()) {
            return base
        }

        var index = 2
        while existingNames.contains("\(base) (\(index))".lowercased()) {
            index += 1
        }
        return "\(base) (\(index))"
    }

    /// Runs the first-launch capture workflow if needed.
    ///
    /// - Skips if the marker file already exists or if `skipIfProfilesExist` is true
    ///   and the profile store contains at least one profile (in which case the marker is written).
    /// - Otherwise, captures a pinned snapshot, reads the current Dock, filters out `.unknown` items,
    ///   creates and saves a profile named "Default" (or "Default (2)" on collision), and writes
    ///   the marker file atomically.
    /// - Thread-safe and serialized by an internal coordinator.
    public func runIfNeeded(skipIfProfilesExist: Bool? = nil) async throws -> Result {
        let shouldSkipIfProfiles = skipIfProfilesExist ?? self.skipIfProfilesExist
        return try await coordinator.run {
            let fileManager = FileManager.default

            // 1. Skip if marker already exists
            if fileManager.fileExists(atPath: markerURL.path) {
                return .alreadyCompleted
            }

            // 2. Skip if store already has at least one profile
            if shouldSkipIfProfiles {
                let existing = await profileStore.list().profiles
                if !existing.isEmpty {
                    try writeMarkerAtomically(fileManager: fileManager)
                    return .alreadyCompleted
                }
            }

            // 3. Resolve profile name
            let profileName = await self.resolveProfileName(base: "Default")

            // 4. Take a PINNED snapshot first (reason: "First launch")
            let snapshot = try await snapshotStore.save(
                reason: "First launch",
                profileName: profileName,
                pinned: true
            )

            // 5. Read the Dock
            let dockState = try await reader()

            // 6. Filter out `.unknown` items and build profile
            var validApps: [DockItem] = []
            var validOthers: [DockItem] = []
            var droppedItems: [DockItem] = []

            for item in dockState.apps {
                if case .unknown = item {
                    droppedItems.append(item)
                } else {
                    validApps.append(item)
                }
            }

            for item in dockState.others {
                if case .unknown = item {
                    droppedItems.append(item)
                } else {
                    validOthers.append(item)
                }
            }

            let profile = Profile(
                name: profileName,
                apps: validApps,
                others: validOthers
            )

            try profile.validate()

            // 7. Save profile to store
            try await profileStore.save(profile)

            // 8. Write marker atomically LAST
            try writeMarkerAtomically(fileManager: fileManager)

            return .created(profile: profile, snapshot: snapshot, droppedItems: droppedItems)
        }
    }

    private func writeMarkerAtomically(fileManager: FileManager) throws {
        let directory = markerURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let tempURL = directory.appendingPathComponent(".tmp-marker-\(UUID().uuidString)", isDirectory: false)
        defer {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        let data = Data(ISO8601DateFormatter().string(from: Date()).utf8)
        try data.write(to: tempURL, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: markerURL.path) {
            _ = try fileManager.replaceItemAt(markerURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: markerURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
    }
}

private actor Coordinator {
    private var isRunning = false
    private var waitQueue: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if isRunning {
            await withCheckedContinuation { continuation in
                waitQueue.append(continuation)
            }
        } else {
            isRunning = true
        }
    }

    private func release() {
        if !waitQueue.isEmpty {
            let next = waitQueue.removeFirst()
            next.resume()
        } else {
            isRunning = false
        }
    }
}
