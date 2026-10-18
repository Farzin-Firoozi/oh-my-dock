import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockItemIdentityTests {
    @Test func appsKeyedByBundleIdIgnoringPathAndName() {
        let a = DockItem.app(AppRef(bundleId: "a.b", name: "One", path: "/Applications/One.app"))
        let b = DockItem.app(AppRef(bundleId: "a.b", name: "Two", path: "/Other/Two.app", launchOnSwitch: true))
        #expect(a.identity == b.identity)
        #expect(a.identity == .app(bundleId: "a.b"))
        #expect(a.identity != DockItem.app(AppRef(bundleId: "a.c", name: "One")).identity)
    }

    @Test func appWithoutBundleIdFallsBackToStandardizedPath() {
        let a = DockItem.app(AppRef(bundleId: "", name: "X", path: "/Applications/X.app/"))
        let b = DockItem.app(AppRef(bundleId: "", name: "Y", path: "/Applications//./X.app"))
        #expect(a.identity == .appPath("/Applications/X.app"))
        #expect(a.identity == b.identity)
    }

    @Test func urlsKeyedByAbsoluteString() {
        let a = DockItem.url(URLItem(url: URL(string: "https://example.com/a")!, label: "A"))
        let b = DockItem.url(URLItem(url: URL(string: "https://example.com/a")!, label: "B"))
        #expect(a.identity == b.identity)
        #expect(a.identity == .url("https://example.com/a"))
        #expect(a.identity != DockItem.url(URLItem(url: URL(string: "https://example.com/b")!)).identity)
    }

    @Test func foldersAndFilesKeyedByStandardizedPath() {
        let a = DockItem.folder(FolderItem(path: "/Users/me/Downloads/", view: .grid))
        let b = DockItem.folder(FolderItem(path: "/Users//me/./Downloads", view: .list, label: "x"))
        #expect(a.identity == b.identity)
        #expect(a.identity == .folder(path: "/Users/me/Downloads"))
        #expect(DockItem.file(FileItem(path: "/a/b/../c.txt")).identity == .file(path: "/a/c.txt"))
    }

    @Test func folderAndFileWithSamePathDiffer() {
        #expect(DockItem.folder(FolderItem(path: "/x")).identity != DockItem.file(FileItem(path: "/x")).identity)
    }

    @Test func spacersKeyedByKindAndNotUnique() {
        #expect(DockItem.spacer(.small).identity == DockItem.spacer(.small).identity)
        #expect(DockItem.spacer(.small).identity != DockItem.spacer(.flex).identity)
        #expect(DockItem.spacer(.normal).identity == .spacer(.normal))
    }

    @Test func unknownKeyedByTileTypeAndLabel() {
        let a = DockItem.unknown(UnknownTile(tileType: "recents-tile", label: "Recent"))
        #expect(a.identity == .unknown(tileType: "recents-tile", label: "Recent"))
        #expect(a.identity != DockItem.unknown(UnknownTile(tileType: "recents-tile")).identity)
        #expect(a.identity != DockItem.unknown(UnknownTile(tileType: "other-tile", label: "Recent")).identity)
    }

    @Test func standardizedPathRules() {
        #expect(standardizedPath("/") == "/")
        #expect(standardizedPath("/a/b/") == "/a/b")
        #expect(standardizedPath("/a/../../b") == "/b")
        #expect(standardizedPath("relative/../x") == "relative/../x")
    }
}
