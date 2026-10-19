import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct ProfileStoreTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-dock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func saveLoadRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Round Trip")
        try await store.save(profile)
        let loaded = try await store.load(id: profile.id)
        #expect(loaded == profile)
    }

    @Test func localProfileKeepsUnknownTilesAcrossSaveAndLoad() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Captured", apps: [.unknown(UnknownTile(tileType: "mystery-tile", label: "Mystery"))])
        try await store.save(profile)
        #expect(try await store.load(id: profile.id) == profile)
    }

    @Test func listSortedByNameCaseInsensitive() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let zebra = Profile(name: "zebra")
        let Alpha = Profile(name: "Alpha")
        let beta = Profile(name: "beta")
        try await store.save(zebra)
        try await store.save(Alpha)
        try await store.save(beta)

        let result = await store.list()
        #expect(result.failures.isEmpty)
        #expect(result.profiles.map(\.name) == ["Alpha", "beta", "zebra"])
    }

    @Test func deleteRemovesFile() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Gone")
        try await store.save(profile)
        #expect(await store.exists(id: profile.id))

        try await store.delete(id: profile.id)
        #expect(await store.exists(id: profile.id) == false)
        await #expect(throws: ProfileStoreError.profileNotFound(profile.id)) {
            try await store.load(id: profile.id)
        }
    }

    @Test func duplicateAssignsNewID() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let original = Profile(name: "Original")
        try await store.save(original)

        let copy = try await store.duplicate(id: original.id, newName: "Copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Copy")
        #expect(await store.exists(id: original.id))
        #expect(await store.exists(id: copy.id))
        let loaded = try await store.load(id: copy.id)
        #expect(loaded.apps == original.apps)
    }

    @Test func renameUpdatesName() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Before")
        try await store.save(profile)
        try await store.rename(id: profile.id, newName: "After")
        let loaded = try await store.load(id: profile.id)
        #expect(loaded.name == "After")
    }

    @Test func invalidProfileRejectedOnSave() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let invalid = Profile(name: "")
        await #expect(throws: ProfileValidationError.emptyName) {
            try await store.save(invalid)
        }
        #expect(await store.list().profiles.isEmpty)
    }

    @Test func corruptFileReportedInListFailures() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let good = Profile(name: "Good")
        try await store.save(good)

        let badID = UUID()
        let badURL = root.appendingPathComponent("\(badID.uuidString).json")
        try Data("{ not json".utf8).write(to: badURL)

        let result = await store.list()
        #expect(result.profiles.count == 1)
        #expect(result.profiles[0].id == good.id)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].url.standardizedFileURL == badURL.standardizedFileURL)
    }

    @Test func fileAndDirectoryPermissions() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        try await store.save(Profile(name: "Perm"))

        let dirMode = try fileMode(at: root)
        #expect(dirMode == 0o700)

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let fileMode = try fileMode(at: files[0])
        #expect(fileMode == 0o600)
    }

    @Test func atomicWriteLeavesNoTempFiles() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        try await store.save(Profile(name: "One"))
        try await store.save(Profile(name: "Two"))

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.allSatisfy { $0.hasSuffix(".json") && !$0.hasPrefix(".tmp-") })
        #expect(entries.count == 2)
    }

    @Test func migratorInvokedForOlderSchemaVersion() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        final class MigratorSpy: ProfileMigrator, @unchecked Sendable {
            private let lock = NSLock()
            private var _callCount = 0
            var callCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return _callCount
            }

            func migrate(jsonData: Data, from schemaVersion: Int) throws -> Data {
                lock.lock()
                _callCount += 1
                lock.unlock()
                guard schemaVersion == 0 else { return jsonData }
                guard var object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected object"))
                }
                object["schemaVersion"] = 1
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
        }

        let migrator = MigratorSpy()
        let store = ProfileStore(rootDirectory: root, migrator: migrator)

        let id = UUID()
        let url = root.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let v0JSON = """
        {"apps":[],"hotkey":null,"id":"\(id.uuidString)","name":"Legacy","others":[],"prefs":null,"schemaVersion":0,"switching":{"launchHidden":false,"offerForceQuit":true,"quitScope":"previousProfileApps"}}
        """
        try Data(v0JSON.utf8).write(to: url)

        let loaded = try await store.load(id: id)
        #expect(loaded.name == "Legacy")
        #expect(migrator.callCount == 1)
    }

    @Test func profileNamedCaseInsensitive() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Work Profile")
        try await store.save(profile)

        #expect(await store.profile(named: "work profile")?.id == profile.id)
        #expect(await store.profile(named: "missing") == nil)
    }

    private func fileMode(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attrs[.posixPermissions] as? Int)
        return permissions & 0o777
    }

    @Test func updateAppliesTheTransformToTheLatestStoredProfile() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let original = Profile(name: "Work")
        try await store.save(original)

        // Another writer changes the hotkey after this caller loaded `original`.
        let hotkey = Hotkey(keyCode: 18, modifiers: [.command])
        try await store.setHotkey(id: original.id, to: hotkey)
        let updated = try await store.update(id: original.id) { $0.name = "Renamed" }

        #expect(updated.name == "Renamed")
        #expect(updated.hotkey == hotkey)
        #expect(try await store.load(id: original.id) == updated)
    }

    @Test func updateValidatesAndLeavesTheStoredProfileUntouchedOnFailure() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Work")
        try await store.save(profile)

        await #expect(throws: ProfileValidationError.self) {
            try await store.update(id: profile.id) { $0.name = "" }
        }
        #expect(try await store.load(id: profile.id).name == "Work")
    }

    @Test func updateKeepsTheProfileIdAndFailsForMissingProfiles() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(name: "Work")
        try await store.save(profile)
        let updated = try await store.update(id: profile.id) { $0.id = UUID() }
        #expect(updated.id == profile.id)

        let missing = UUID()
        await #expect(throws: ProfileStoreError.profileNotFound(missing)) {
            try await store.update(id: missing) { _ in }
        }
    }

    @Test func setHotkeyRejectsAShortcutAnotherProfileUses() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let store = ProfileStore(rootDirectory: root)
        let hotkey = Hotkey(keyCode: 18, modifiers: [.command, .option])
        let work = Profile(name: "Work", hotkey: hotkey)
        let play = Profile(name: "Play")
        try await store.save(work)
        try await store.save(play)

        await #expect(throws: ProfileStoreError.hotkeyInUse(profileName: "Work")) {
            try await store.setHotkey(id: play.id, to: hotkey)
        }
        #expect(try await store.load(id: play.id).hotkey == nil)

        // Re-recording a profile's own shortcut, and clearing, are fine.
        try await store.setHotkey(id: work.id, to: hotkey)
        try await store.setHotkey(id: work.id, to: nil)
        try await store.setHotkey(id: play.id, to: hotkey)
        #expect(try await store.load(id: play.id).hotkey == hotkey)
    }
}
