import Foundation
import OhMyDockCore
import Testing

actor FakeStore: EditorProfileStore {
    var saved: [UUID: Profile]
    var deleted: [UUID] = []
    var saveCount = 0
    var failNextSave = false

    init(_ profiles: [Profile] = []) {
        saved = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    struct Boom: Error {}

    func list() -> ProfileStore.ListResult {
        ProfileStore.ListResult(profiles: Array(saved.values), failures: [])
    }

    func save(_ profile: Profile) throws {
        if failNextSave {
            failNextSave = false
            throw Boom()
        }
        saveCount += 1
        saved[profile.id] = profile
    }

    func delete(id: UUID) throws {
        deleted.append(id)
        saved[id] = nil
    }

    func failOnNextSave() { failNextSave = true }
}

private func app(_ name: String) -> DockItem {
    .app(AppRef(bundleId: "com.test.\(name)", name: name, path: "/Applications/\(name).app"))
}

@MainActor
private func makeModel(_ profiles: [Profile] = []) async -> (EditorViewModel, FakeStore) {
    let store = FakeStore(profiles)
    let model = EditorViewModel(store: store)
    await model.load()
    return (model, store)
}

@MainActor
@Suite struct EditorViewModelTests {
    @Test func loadSortsAndSelectsFirst() async {
        let (model, _) = await makeModel([Profile(name: "work"), Profile(name: "Alpha")])
        #expect(model.profiles.map(\.name) == ["Alpha", "work"])
        #expect(model.selectedProfile?.name == "Alpha")
    }

    @Test func addProfilePersistsAndSelects() async {
        let (model, store) = await makeModel()
        let id = model.addProfile()
        await model.flush()
        #expect(model.selectedProfileID == id)
        #expect(await store.saved[id!]?.name == "New Profile")
        let second = model.addProfile()
        #expect(model.profiles.first { $0.id == second }?.name == "New Profile 2")
    }

    @Test func renameValidatesAndPersists() async {
        let a = Profile(name: "A")
        let b = Profile(name: "B")
        let (model, store) = await makeModel([a, b])
        #expect(model.renameProfile(id: a.id, to: "  Zed "))
        await model.flush()
        #expect(await store.saved[a.id]?.name == "Zed")
        #expect(model.profiles.map(\.name) == ["B", "Zed"])

        #expect(!model.renameProfile(id: a.id, to: "b"))
        #expect(model.error == .nameInUse("b"))
        #expect(!model.renameProfile(id: a.id, to: "   "))
        #expect(model.error == .validation(.emptyName))
        #expect(!model.renameProfile(id: a.id, to: String(repeating: "x", count: 101)))
        #expect(model.profiles.first { $0.id == a.id }?.name == "Zed")
    }

    @Test func duplicateCopiesItemsWithNewIdentity() async {
        let source = Profile(name: "Work", apps: [app("Safari")], others: [.spacer(.small)])
        let (model, store) = await makeModel([source])
        let copyID = model.duplicateProfile(id: source.id)
        await model.flush()
        #expect(copyID != nil && copyID != source.id)
        let copy = await store.saved[copyID!]
        #expect(copy?.name == "Work copy")
        #expect(copy?.apps == source.apps)
        #expect(copy?.others == source.others)
        #expect(model.selectedProfileID == copyID)
    }

    @Test func deleteRemovesAndSelectsNeighbor() async {
        let a = Profile(name: "A")
        let b = Profile(name: "B")
        let (model, store) = await makeModel([a, b])
        model.deleteProfile(id: a.id)
        await model.flush()
        #expect(await store.deleted == [a.id])
        #expect(model.selectedProfileID == b.id)
        model.deleteProfile(id: b.id)
        #expect(model.selectedProfileID == nil)
    }

    @Test func insertRemoveAndSelection() async {
        let (model, store) = await makeModel([Profile(name: "P")])
        let safari = model.insert(app("Safari"), in: .apps)
        model.insert(app("Mail"), in: .apps, at: 0)
        await model.flush()
        #expect(await store.saved[model.selectedProfileID!]?.apps.count == 2)
        #expect(model.itemIDs(in: .apps).count == 2)
        model.removeItem(safari!)
        await model.flush()
        #expect(model.selectedProfile?.apps == [app("Mail")])
    }

    @Test func moveWithinSectionUsesPreRemovalSlots() async {
        let (model, _) = await makeModel([Profile(name: "P", apps: [app("A"), app("B"), app("C")])])
        let ids = model.itemIDs(in: .apps)
        model.moveItem(ids[0], to: .apps, before: 3)   // to end
        #expect(model.selectedProfile?.apps == [app("B"), app("C"), app("A")])
        model.moveItem(ids[2], to: .apps, before: 0)   // C to front
        #expect(model.selectedProfile?.apps == [app("C"), app("B"), app("A")])
        model.moveItem(ids[1], to: .apps, before: 1)   // B already there
        #expect(model.selectedProfile?.apps == [app("C"), app("B"), app("A")])
    }

    @Test func moveAcrossSections() async {
        let folder = DockItem.folder(FolderItem(path: "/tmp"))
        let (model, _) = await makeModel([Profile(name: "P", apps: [app("A")], others: [folder])])
        model.moveItem(model.itemIDs(in: .apps)[0], to: .others, before: 0)
        #expect(model.selectedProfile?.apps == [])
        #expect(model.selectedProfile?.others == [app("A"), folder])
        #expect(model.selectedItemID?.section == .others)
    }

    @Test func spacersGetDistinctHandles() async {
        let (model, _) = await makeModel([Profile(name: "P", apps: [.spacer(.normal), .spacer(.normal), app("A")])])
        let ids = model.itemIDs(in: .apps)
        #expect(Set(ids).count == 3)
        model.removeItem(ids[1])
        #expect(model.selectedProfile?.apps == [.spacer(.normal), app("A")])
    }

    @Test func duplicateAppIsRejectedWithoutChangingState() async {
        let (model, store) = await makeModel([Profile(name: "P", apps: [app("A")])])
        #expect(model.insert(app("A"), in: .apps) == nil)
        #expect(model.error == .validation(.duplicateLabel(.apps, index: 1, label: "A")))
        await model.flush()
        #expect(model.selectedProfile?.apps.count == 1)
        #expect(await store.saveCount == 0)
    }

    @Test func invalidURLLabelEditsAreRefused() async {
        let (model, _) = await makeModel([Profile(name: "P")])
        let id = model.insert(.url(URLItem(url: URL(string: "ftp://example.com")!)), in: .others)
        #expect(id == nil)
        #expect(model.error != nil)
        #expect(model.selectedProfile?.others.isEmpty == true)
    }

    @Test func labelAndFolderOptionEdits() async {
        let (model, store) = await makeModel([Profile(name: "P", others: [.folder(FolderItem(path: "/tmp/Stuff"))])])
        let id = model.itemIDs(in: .others)[0]
        model.selectedItemID = id
        #expect(model.setLabel("Things", for: id))
        model.updateItem(id) { item in
            if case .folder(var f) = item { f.view = .grid; f.sort = .kind; item = .folder(f) }
        }
        await model.flush()
        guard case .folder(let f)? = await store.saved[model.selectedProfileID!]?.others.first else {
            Issue.record("folder missing"); return
        }
        #expect(f.label == "Things" && f.view == .grid && f.sort == .kind)
        #expect(model.selectedItem != nil)
    }

    @Test func spacerKindEditKeepsSelection() async {
        let (model, _) = await makeModel([Profile(name: "P", apps: [.spacer(.normal)])])
        let id = model.itemIDs(in: .apps)[0]
        model.selectedItemID = id
        model.updateItem(id) { $0 = .spacer(.flex) }
        #expect(model.selectedItem == .spacer(.flex))
    }

    @Test func editsWithoutProfileReportError() async {
        let (model, _) = await makeModel()
        #expect(model.addSpacer(in: .apps) == nil)
        #expect(model.error == .noProfileSelected)
    }

    @Test func failedSaveReportsAndReloadsFromStore() async {
        let (model, store) = await makeModel([Profile(name: "P")])
        await store.failOnNextSave()
        model.addSpacer(in: .apps)
        await model.flush()
        guard case .persistence? = model.error else {
            Issue.record("expected persistence error"); return
        }
        #expect(model.selectedProfile?.apps.isEmpty == true)
    }

    @Test func droppedFilesBecomeTiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.test.fake", "CFBundleName": "Fake", "CFBundlePackageType": "APPL"]
        try (info as NSDictionary).write(to: bundle.appendingPathComponent("Info.plist"))
        let folder = dir.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)

        let (model, _) = await makeModel([Profile(name: "P")])
        model.addFileURL(dir.appendingPathComponent("Fake.app"))
        model.addFileURL(folder)
        model.addFileURL(file)
        guard case .app(let ref)? = model.selectedProfile?.apps.first else {
            Issue.record("app missing"); return
        }
        #expect(ref.bundleId == "com.test.fake" && ref.name == "Fake")
        let others = model.selectedProfile?.others ?? []
        #expect(others.count == 2)
        guard case .folder? = others.first, case .file? = others.last else {
            Issue.record("expected folder then file"); return
        }
    }
}
