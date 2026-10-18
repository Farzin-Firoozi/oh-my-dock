import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockOperationTests {
    private let app1 = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
    private let app2 = DockItem.app(AppRef(bundleId: "com.apple.Mail", name: "Mail"))
    private let app3 = DockItem.app(AppRef(bundleId: "com.apple.Music", name: "Music"))
    private let folder1 = DockItem.folder(FolderItem(path: "/Users/me/Downloads"))
    private let folder2 = DockItem.folder(FolderItem(path: "/Users/me/Documents"))
    private let spacer1 = DockItem.spacer(.normal)

    // MARK: - Insert

    @Test func insertAtStart() throws {
        let initial = DockState(apps: [app1, app2])
        let result = try initial.applying([.insert(app3, section: .apps, index: 0)])
        #expect(result.apps == [app3, app1, app2])
        #expect(result.others.isEmpty)
    }

    @Test func insertInMiddle() throws {
        let initial = DockState(apps: [app1, app2])
        let result = try initial.applying([.insert(app3, section: .apps, index: 1)])
        #expect(result.apps == [app1, app3, app2])
    }

    @Test func insertAtEnd() throws {
        let initial = DockState(apps: [app1, app2])
        let result = try initial.applying([.insert(app3, section: .apps, index: 2)])
        #expect(result.apps == [app1, app2, app3])
    }

    @Test func insertIntoOthersSection() throws {
        let initial = DockState(others: [folder1])
        let result = try initial.applying([.insert(folder2, section: .others, index: 1)])
        #expect(result.others == [folder1, folder2])
    }

    @Test func insertUnknownItemRejected() {
        let initial = DockState()
        let unknown = DockItem.unknown(UnknownTile(tileType: "custom-tile"))
        #expect(throws: DockBackendError.invalidOperation("Unknown dock items cannot be inserted")) {
            try initial.applying([.insert(unknown, section: .apps, index: 0)])
        }
    }

    @Test func insertOutOfRangeNegative() {
        let initial = DockState(apps: [app1])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: -1)) {
            try initial.applying([.insert(app2, section: .apps, index: -1)])
        }
    }

    @Test func insertOutOfRangeTooHigh() {
        let initial = DockState(apps: [app1])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 2)) {
            try initial.applying([.insert(app2, section: .apps, index: 2)])
        }
    }

    // MARK: - Remove

    @Test func removeStartMiddleEnd() throws {
        let initial = DockState(apps: [app1, app2, app3])

        let removedStart = try initial.applying([.remove(section: .apps, index: 0)])
        #expect(removedStart.apps == [app2, app3])

        let removedMiddle = try initial.applying([.remove(section: .apps, index: 1)])
        #expect(removedMiddle.apps == [app1, app3])

        let removedEnd = try initial.applying([.remove(section: .apps, index: 2)])
        #expect(removedEnd.apps == [app1, app2])
    }

    @Test func removeOutOfRangeNegative() {
        let initial = DockState(apps: [app1])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: -1)) {
            try initial.applying([.remove(section: .apps, index: -1)])
        }
    }

    @Test func removeOutOfRangeEqualCount() {
        let initial = DockState(apps: [app1])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 1)) {
            try initial.applying([.remove(section: .apps, index: 1)])
        }
    }

    @Test func removeOutOfRangeEmpty() {
        let initial = DockState()
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 0)) {
            try initial.applying([.remove(section: .apps, index: 0)])
        }
    }

    @Test func removeCanRemoveUnknownItem() throws {
        let unknown = DockItem.unknown(UnknownTile(tileType: "mystery"))
        let initial = DockState(apps: [app1, unknown, app2])
        let result = try initial.applying([.remove(section: .apps, index: 1)])
        #expect(result.apps == [app1, app2])
    }

    // MARK: - Move

    @Test func moveForward() throws {
        let initial = DockState(apps: [app1, app2, app3])
        let result = try initial.applying([.move(section: .apps, from: 0, to: 2)])
        #expect(result.apps == [app2, app3, app1])
    }

    @Test func moveBackward() throws {
        let initial = DockState(apps: [app1, app2, app3])
        let result = try initial.applying([.move(section: .apps, from: 2, to: 0)])
        #expect(result.apps == [app3, app1, app2])
    }

    @Test func moveSameIndex() throws {
        let initial = DockState(apps: [app1, app2, app3])
        let result = try initial.applying([.move(section: .apps, from: 1, to: 1)])
        #expect(result.apps == [app1, app2, app3])
    }

    @Test func moveCanMoveUnknownItem() throws {
        let unknown = DockItem.unknown(UnknownTile(tileType: "mystery"))
        let initial = DockState(apps: [unknown, app1, app2])
        let result = try initial.applying([.move(section: .apps, from: 0, to: 2)])
        #expect(result.apps == [app1, app2, unknown])
    }

    @Test func moveOutOfRangeFromNegative() {
        let initial = DockState(apps: [app1, app2])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: -1)) {
            try initial.applying([.move(section: .apps, from: -1, to: 1)])
        }
    }

    @Test func moveOutOfRangeFromTooHigh() {
        let initial = DockState(apps: [app1, app2])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 2)) {
            try initial.applying([.move(section: .apps, from: 2, to: 1)])
        }
    }

    @Test func moveOutOfRangeToNegative() {
        let initial = DockState(apps: [app1, app2])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: -1)) {
            try initial.applying([.move(section: .apps, from: 0, to: -1)])
        }
    }

    @Test func moveOutOfRangeToTooHigh() {
        let initial = DockState(apps: [app1, app2])
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 2)) {
            try initial.applying([.move(section: .apps, from: 0, to: 2)])
        }
    }

    @Test func moveOutOfRangeEmptySection() {
        let initial = DockState()
        #expect(throws: DockBackendError.indexOutOfRange(section: .others, index: 0)) {
            try initial.applying([.move(section: .others, from: 0, to: 0)])
        }
    }

    // MARK: - Replace All

    @Test func replaceAllReplacesWholeDock() throws {
        let initial = DockState(apps: [app1], others: [folder1])
        let replacement = DockState(apps: [app2, app3], others: [folder2, spacer1])
        let result = try initial.applying([.replaceAll(replacement)])
        #expect(result == replacement)
    }

    // MARK: - Sequential batch semantics

    @Test func sequentialIndexSemanticsAcrossBatch() throws {
        let initial = DockState(apps: [app1, app2, app3])
        // 1. insert spacer at index 1 -> [app1, spacer, app2, app3]
        // 2. remove item at index 3 -> [app1, spacer, app2] (app3 removed)
        // 3. move item at 0 to index 2 -> [spacer, app2, app1] (app1 moved to end)
        let operations: [DockOperation] = [
            .insert(spacer1, section: .apps, index: 1),
            .remove(section: .apps, index: 3),
            .move(section: .apps, from: 0, to: 2)
        ]
        let result = try initial.applying(operations)
        #expect(result.apps == [spacer1, app2, app1])
    }

    @Test func batchFailsAtomicallyOnOutOfRange() {
        let initial = DockState(apps: [app1, app2])
        let operations: [DockOperation] = [
            .insert(app3, section: .apps, index: 0), // valid -> would be [app3, app1, app2]
            .remove(section: .apps, index: 10)       // invalid
        ]
        #expect(throws: DockBackendError.indexOutOfRange(section: .apps, index: 10)) {
            try initial.applying(operations)
        }
        // Original remains unchanged
        #expect(initial.apps == [app1, app2])
    }
}
