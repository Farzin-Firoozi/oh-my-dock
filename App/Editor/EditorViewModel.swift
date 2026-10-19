import Foundation
import Observation
import OhMyDockCore

/// The slice of `ProfileStore` the editor needs. A protocol so tests can use an in-memory fake.
protocol EditorProfileStore: Sendable {
    func list() async -> ProfileStore.ListResult
    func save(_ profile: Profile) async throws
    /// Read-modify-write of the stored profile, so an edit never overwrites fields (such as the
    /// hotkey) that another writer changed since the editor loaded it.
    @discardableResult
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) async throws -> Profile
    func delete(id: UUID) async throws
}

extension ProfileStore: EditorProfileStore {}

/// Stable handle for one tile of the selected profile. Tiles have no id of their own, so the
/// handle is the tile's identity plus how many equal tiles (spacers of one kind) precede it.
/// It survives reordering and label edits; it changes only when the tile itself is replaced.
struct EditorItemID: Hashable, Sendable {
    var section: DockSection
    var identity: DockItemIdentity
    var ordinal: Int
}

enum EditorError: Error, Equatable, LocalizedError {
    case validation(ProfileValidationError)
    case nameInUse(String)
    case noProfileSelected
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .validation(let error): Self.describe(error)
        case .nameInUse(let name): "Another profile is already named \"\(name)\"."
        case .noProfileSelected: "Select a profile first."
        case .persistence(let message): "Couldn't save: \(message)"
        }
    }

    private static func title(_ section: DockSection) -> String {
        section == .apps ? "Apps" : "Others"
    }

    private static func describe(_ error: ProfileValidationError) -> String {
        switch error {
        case .emptyName:
            "A profile needs a name."
        case .nameTooLong(_, let maximum):
            "Profile names can be at most \(maximum) characters."
        case .unknownItem(let section, _, let tileType):
            "\(title(section)) holds a tile of unsupported type \(tileType)."
        case .appMissingIdentity(let section, _):
            "An app in \(title(section)) has neither a bundle identifier nor a path."
        case .pathNotAbsolute(let section, _, let path):
            "\(path) in \(title(section)) isn't an absolute path."
        case .unsupportedURLScheme(let section, _, let url):
            "\(url) in \(title(section)) isn't an http or https address."
        case .invalidPrefs:
            "The Dock preferences of this profile are invalid."
        case .duplicateLabel(let section, _, let label):
            "\(title(section)) already has a tile called \"\(label)\"."
        }
    }
}

/// All editor state and every edit. Edits are validated with `Profile.validate`, applied to the
/// in-memory profile, then written through the store in order. Nothing here touches the Dock.
@MainActor
@Observable
final class EditorViewModel {
    private(set) var profiles: [Profile] = []
    private(set) var isLoaded = false
    /// Profile files the store couldn't read.
    private(set) var skippedProfileCount = 0
    private(set) var error: EditorError?

    var selectedProfileID: UUID? {
        didSet {
            if selectedProfileID != oldValue { selectedItemID = nil }
        }
    }
    var selectedItemID: EditorItemID?

    @ObservationIgnored private let store: any EditorProfileStore
    @ObservationIgnored private var persistence: Task<Void, Never>?
    /// Bumped when a write fails. Writes queued under an older epoch were made against a state
    /// the failure invalidated, so they are dropped instead of replaying stale values.
    @ObservationIgnored private var writeEpoch = 0

    init(store: any EditorProfileStore) {
        self.store = store
    }

    // MARK: - Derived state

    var selectedProfile: Profile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    /// Handles for the tiles of `section` in the selected profile, in order.
    func itemIDs(in section: DockSection) -> [EditorItemID] {
        guard let profile = selectedProfile else { return [] }
        return Self.ids(for: profile.items(in: section), in: section)
    }

    func item(_ id: EditorItemID) -> DockItem? {
        guard let profile = selectedProfile, let index = Self.index(of: id, in: profile) else { return nil }
        return profile.items(in: id.section)[index]
    }

    var selectedItem: DockItem? { selectedItemID.flatMap(item) }

    func dismissError() { error = nil }

    /// Resolves once every queued write has reached the store.
    func flush() async {
        await persistence?.value
    }

    // MARK: - Loading

    func load() async {
        let result = await store.list()
        skippedProfileCount = result.failures.count
        profiles = result.profiles
        sortProfiles()
        isLoaded = true
        if selectedProfile == nil { selectedProfileID = profiles.first?.id }
    }

    // MARK: - Profiles

    @discardableResult
    func addProfile(named name: String = "New Profile") -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(name: uniqueName(trimmed))
        guard validated(profile) else { return nil }
        insert(profile)
        return profile.id
    }

    @discardableResult
    func duplicateProfile(id: UUID) -> UUID? {
        guard let source = profiles.first(where: { $0.id == id }) else { return nil }
        // Leave room for the suffix so a long name doesn't fail validation.
        let base = String(source.name.prefix(Profile.maxNameLength - 12)) + " copy"
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(base)
        // A hotkey belongs to one profile.
        copy.hotkey = nil
        guard validated(copy) else { return nil }
        insert(copy)
        return copy.id
    }

    @discardableResult
    func renameProfile(id: UUID, to name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == profiles[index].name { return true }
        if profiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            error = .nameInUse(trimmed)
            return false
        }
        var profile = profiles[index]
        profile.name = trimmed
        guard validated(profile) else { return false }
        profiles[index] = profile
        sortProfiles()
        persistEdit(of: profile)
        return true
    }

    func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        if selectedProfileID == id {
            selectedProfileID = profiles.indices.contains(index) ? profiles[index].id : profiles.last?.id
        }
        enqueue { store in try await store.delete(id: id) }
    }

    // MARK: - Items

    /// Adds a tile for a file-system item (an app bundle, folder or file), such as one dropped
    /// from Finder. Apps go to the apps section, everything else to others. Anything that isn't a
    /// `file:` URL is refused: a web address must become a link tile (`addDroppedURL`), never a
    /// "file" with a bogus path.
    /// - Parameter drop: where it was dropped. The position is honoured only when the item
    ///   belongs in that section (an app dropped on the others side is appended to the apps);
    ///   nil appends.
    @discardableResult
    func addFileURL(_ url: URL, dropped drop: (section: DockSection, slot: Int)? = nil) -> EditorItemID? {
        guard url.isFileURL else {
            error = .validation(.unsupportedURLScheme(.others, index: 0, url: url.absoluteString))
            return nil
        }
        let (section, item) = Self.tile(forFileURL: url)
        return insert(item, in: section, at: drop?.section == section ? drop?.slot : nil)
    }

    /// Adds whatever a drop delivered: a `file:` URL becomes a file, folder or app tile, an `https`
    /// URL becomes a link tile through the same https-only input path as the add-link sheet, and
    /// any other scheme is refused with an error.
    @discardableResult
    func addDroppedURL(_ url: URL, dropped drop: (section: DockSection, slot: Int)? = nil) -> EditorItemID? {
        if url.isFileURL { return addFileURL(url, dropped: drop) }
        guard url.scheme?.lowercased() == "https" else {
            error = .validation(.unsupportedURLScheme(.others, index: 0, url: url.absoluteString))
            return nil
        }
        return addURLString(url.absoluteString, at: drop?.section == .others ? drop?.slot : nil)
    }

    /// Adds an application from a bundle URL (picker or Spotlight list).
    @discardableResult
    func addApplication(at url: URL, at slot: Int? = nil) -> EditorItemID? {
        guard let ref = ApplicationReference.appRef(at: url) else { return nil }
        return insert(.app(ref), in: .apps, at: slot)
    }

    /// Adds a link tile after validating the address (`https` only).
    @discardableResult
    func addURLString(_ raw: String, label: String? = nil, at slot: Int? = nil) -> EditorItemID? {
        switch EditorURLInput.normalizedURL(from: raw) {
        case .success(let url):
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let item = URLItem(url: url, label: trimmed.isEmpty ? nil : trimmed)
            return insert(.url(item), in: .others, at: slot)
        case .failure(.empty):
            error = .validation(.unsupportedURLScheme(.others, index: 0, url: ""))
            return nil
        case .failure(.invalid):
            error = .validation(.unsupportedURLScheme(.others, index: 0, url: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            return nil
        }
    }

    @discardableResult
    func addFolder(_ folder: FolderItem, at slot: Int? = nil) -> EditorItemID? {
        insert(.folder(folder), in: .others, at: slot)
    }

    @discardableResult
    func addFile(_ file: FileItem, at slot: Int? = nil) -> EditorItemID? {
        insert(.file(file), in: .others, at: slot)
    }

    @discardableResult
    func addSpacer(_ kind: SpacerKind = .normal, in section: DockSection, at slot: Int? = nil) -> EditorItemID? {
        insert(.spacer(kind), in: section, at: slot)
    }

    @discardableResult
    func insert(_ item: DockItem, in section: DockSection, at slot: Int? = nil) -> EditorItemID? {
        var newIndex = 0
        let ok = mutateSelected { profile in
            let count = profile.items(in: section).count
            newIndex = min(max(slot ?? count, 0), count)
            profile[keyPath: Self.path(section)].insert(item, at: newIndex)
        }
        guard ok else { return nil }
        let id = itemIDs(in: section)[newIndex]
        selectedItemID = id
        return id
    }

    func removeItem(_ id: EditorItemID) {
        guard let profile = selectedProfile, let index = Self.index(of: id, in: profile) else { return }
        guard mutateSelected({ $0[keyPath: Self.path(id.section)].remove(at: index) }) else { return }
        if selectedItemID == id { selectedItemID = nil }
    }

    /// Moves a tile so it sits before the tile currently at `slot` of `section` (`slot` counts
    /// tiles before the move; the section's end is its count). Works across sections.
    func moveItem(_ id: EditorItemID, to section: DockSection, before slot: Int) {
        guard let profile = selectedProfile, let from = Self.index(of: id, in: profile) else { return }
        let count = profile.items(in: section).count
        var target = min(max(slot, 0), count)
        if section == id.section, from < target { target -= 1 }
        if section == id.section, from == target { return }
        let moved = mutateSelected { profile in
            let item = profile[keyPath: Self.path(id.section)].remove(at: from)
            profile[keyPath: Self.path(section)].insert(item, at: target)
        }
        if moved { selectedItemID = itemIDs(in: section)[target] }
    }

    /// Edits one tile in place. Keeps the selection on that tile even if the edit changes its handle.
    @discardableResult
    func updateItem(_ id: EditorItemID, _ edit: (inout DockItem) -> Void) -> Bool {
        guard let profile = selectedProfile, let index = Self.index(of: id, in: profile) else { return false }
        let ok = mutateSelected { edit(&$0[keyPath: Self.path(id.section)][index]) }
        if ok, selectedItemID == id { selectedItemID = itemIDs(in: id.section)[index] }
        return ok
    }

    /// Sets the label of a URL, folder or file tile. An empty label means "derive one".
    @discardableResult
    func setLabel(_ label: String, for id: EditorItemID) -> Bool {
        updateItem(id) { item in
            switch item {
            case .url(var value): value.label = label; item = .url(value)
            case .folder(var value): value.label = label; item = .folder(value)
            case .file(var value): value.label = label; item = .file(value)
            case .app, .spacer, .unknown: break
            }
        }
    }

    // MARK: - Mutation plumbing

    /// Applies `edit` to a copy of the selected profile and commits it only if it validates.
    private func mutateSelected(_ edit: (inout Profile) -> Void) -> Bool {
        guard let id = selectedProfileID, let index = profiles.firstIndex(where: { $0.id == id }) else {
            error = .noProfileSelected
            return false
        }
        var profile = profiles[index]
        edit(&profile)
        guard validated(profile) else { return false }
        profiles[index] = profile
        persistEdit(of: profile)
        return true
    }

    /// Validates the way the store will, so a bad edit is refused before it reaches the UI state.
    private func validated(_ profile: Profile) -> Bool {
        do {
            try profile.validate(allowingUnknownTiles: true)
            error = nil
            return true
        } catch {
            self.error = .validation(error)
            return false
        }
    }

    private func insert(_ profile: Profile) {
        profiles.append(profile)
        sortProfiles()
        selectedProfileID = profile.id
        persist(profile)
    }

    private func sortProfiles() {
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Writes a profile the store has never seen.
    private func persist(_ profile: Profile) {
        enqueue { store in try await store.save(profile) }
    }

    /// Writes the editor's own fields (name and tiles) into the latest stored profile. Everything
    /// else (hotkey, prefs, switching options) stays as whoever last wrote it left it.
    private func persistEdit(of profile: Profile) {
        let id = profile.id
        let name = profile.name
        let apps = profile.apps
        let others = profile.others
        enqueue { store in
            try await store.update(id: id) {
                $0.name = name
                $0.apps = apps
                $0.others = others
            }
        }
    }

    /// Runs store writes strictly in order. A failed write is reported and the in-memory state is
    /// reloaded from the store, so the window never keeps showing something that isn't on disk.
    /// Writes queued before the failure are dropped: they carry values the reload just discarded.
    private func enqueue(_ write: @escaping @Sendable (any EditorProfileStore) async throws -> Void) {
        let previous = persistence
        let epoch = writeEpoch
        persistence = Task { [store] in
            await previous?.value
            guard epoch == self.writeEpoch else { return }
            do {
                try await write(store)
            } catch {
                self.writeEpoch += 1
                self.error = .persistence((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                await self.load()
            }
        }
    }

    // MARK: - Helpers

    private static func path(_ section: DockSection) -> WritableKeyPath<Profile, [DockItem]> {
        section == .apps ? \.apps : \.others
    }

    private static func ids(for items: [DockItem], in section: DockSection) -> [EditorItemID] {
        var seen: [DockItemIdentity: Int] = [:]
        return items.map { item in
            let identity = item.identity
            let ordinal = seen[identity, default: 0]
            seen[identity] = ordinal + 1
            return EditorItemID(section: section, identity: identity, ordinal: ordinal)
        }
    }

    private static func index(of id: EditorItemID, in profile: Profile) -> Int? {
        ids(for: profile.items(in: id.section), in: id.section).firstIndex(of: id)
    }

    /// Classifies a dropped file-system item. Apps resolve their bundle id from the bundle itself.
    static func tile(forFileURL url: URL) -> (DockSection, DockItem) {
        let url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if let ref = ApplicationReference.appRef(at: url) {
            return (.apps, .app(ref))
        }
        if values?.isDirectory == true, values?.isPackage != true {
            return (.others, .folder(FolderItem(path: url.path)))
        }
        return (.others, .file(FileItem(path: url.path)))
    }
}
