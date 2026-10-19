import Foundation

/// Why the first-launch capture gave up.
public enum FirstLaunchError: Error, Equatable, Sendable {
    /// The Dock changed while it was being captured (twice in a row), so the profile and the safety
    /// snapshot would not describe the same Dock. Nothing was saved and no marker was written.
    case dockChangedDuringCapture
}

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
    /// - Otherwise reads the current Dock, filters out `.unknown` items and validates a profile
    ///   named "Default" (or "Default (2)" on collision). Tiles whose label another tile of the
    ///   section already has get a numbered label ("Docs (2)"); an app that cannot be relabelled
    ///   is dropped and reported like an unknown tile. Only then does it pin a "First launch"
    ///   snapshot, re-read the Dock and compare: when the Dock changed in between, the snapshot
    ///   (if new) is deleted and the capture is retried once, then `FirstLaunchError` is thrown.
    ///   Profile and snapshot are therefore the same capture.
    /// - An earlier pinned "First launch" snapshot is reused only while it still equals the Dock;
    ///   otherwise a fresh one is taken and the stale one is unpinned (kept, but prunable).
    ///   A failed read, validation or capture leaves no new snapshot behind.
    /// - Saves the profile and writes the marker file atomically.
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

            // 4. Capture the Dock and the snapshot as one: read, validate, snapshot, read again.
            var attempt = 0
            while true {
                let dockState = try await reader()
                let (profile, droppedItems) = try Self.profile(named: profileName, from: dockState)

                let (snapshot, isNew, stale) = try await pinnedFirstLaunchSnapshot(
                    profileName: profileName,
                    matching: dockState
                )
                guard try await reader() == dockState else {
                    if isNew { try? await snapshotStore.delete(id: snapshot.id) }
                    attempt += 1
                    if attempt >= 2 { throw FirstLaunchError.dockChangedDuringCapture }
                    continue
                }

                // 5. Save profile to store
                try await profileStore.save(profile)
                for old in stale { try? await snapshotStore.unpin(id: old.id) }

                // 6. Write marker atomically LAST
                try writeMarkerAtomically(fileManager: fileManager)

                return .created(profile: profile, snapshot: snapshot, droppedItems: droppedItems)
            }
        }
    }

    /// The captured profile and the tiles it could not hold (unknown tiles, apps with a label
    /// another tile already has).
    private static func profile(
        named name: String,
        from dockState: DockState
    ) throws -> (Profile, [DockItem]) {
        var dropped: [DockItem] = []
        func capturable(_ items: [DockItem]) -> [DockItem] {
            let known = items.filter {
                if case .unknown = $0 { dropped.append($0); return false }
                return true
            }
            return disambiguatingLabels(known, dropping: &dropped)
        }
        let profile = Profile(
            name: name,
            apps: capturable(dockState.apps),
            others: capturable(dockState.others)
        )
        try profile.validate()
        return (profile, dropped)
    }

    /// Gives folders, files and URLs whose computed label an earlier tile already has an explicit
    /// "Label (2)", "(3)", ... that is free in the section. A pathless app is renamed likewise (its
    /// name is its label). An app whose label comes from its path cannot be relabelled and goes
    /// into `dropped`.
    private static func disambiguatingLabels(_ items: [DockItem], dropping dropped: inout [DockItem]) -> [DockItem] {
        var used = Set(items.filter { !$0.isSpacer }.map(DockutilPlanner.computedLabel(of:)))
        var seen: Set<String> = []
        var result: [DockItem] = []
        func freeLabel(_ base: String) -> String {
            var n = 2
            while used.contains("\(base) (\(n))") { n += 1 }
            let label = "\(base) (\(n))"
            used.insert(label)
            return label
        }
        for item in items {
            if item.isSpacer { result.append(item); continue }
            let label = DockutilPlanner.computedLabel(of: item)
            if label.isEmpty || seen.insert(label).inserted { result.append(item); continue }
            switch item {
            case .folder(var folder):
                folder.label = freeLabel(label)
                result.append(.folder(folder))
            case .file(var file):
                file.label = freeLabel(label)
                result.append(.file(file))
            case .url(var url):
                url.label = freeLabel(label)
                result.append(.url(url))
            case .app(var app) where (app.path ?? "").isEmpty:
                app.name = freeLabel(label)
                result.append(.app(app))
            default:
                dropped.append(item)
            }
        }
        return result
    }

    static let snapshotReason = "First launch"

    /// A pinned first-launch snapshot of the Dock as it is now: the newest existing one that still
    /// equals `dockState`, else a new one. `stale` lists the pinned ones that do not match, for
    /// the caller to unpin once the capture succeeded.
    private func pinnedFirstLaunchSnapshot(
        profileName: String,
        matching dockState: DockState
    ) async throws -> (snapshot: Snapshot, isNew: Bool, stale: [Snapshot]) {
        let pinned = await snapshotStore.list().snapshots
            .filter { $0.pinned && $0.reason == Self.snapshotReason }
        var stale: [Snapshot] = []
        for candidate in pinned {
            if await storedDock(of: candidate) == dockState {
                return (candidate, false, stale)
            }
            stale.append(candidate)
        }
        let snapshot = try await snapshotStore.save(
            reason: Self.snapshotReason,
            profileName: profileName,
            pinned: true
        )
        return (snapshot, true, stale)
    }

    /// The Dock a snapshot holds, or nil when it cannot be read.
    private func storedDock(of snapshot: Snapshot) async -> DockState? {
        guard let data = try? await snapshotStore.load(id: snapshot.id),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let domain = DockPlistValues.dictionary(plist)
        else { return nil }
        return DockPlistParser.parse(domain: domain)
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
