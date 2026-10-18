import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockStateComparisonTests {
    private func matches(_ expected: DockItem, _ actual: DockItem) -> Bool {
        expected.matchesAfterWrite(actual)
    }

    // MARK: - Whole state

    @Test func identicalStatesMatch() {
        let state = DockState(apps: [Sample.calculator, .spacer(.flex)], others: [Sample.example, Sample.docs])
        #expect(state.matchesAfterWrite(state))
    }

    @Test func orderMatters() {
        let expected = DockState(apps: [Sample.calculator, Sample.notes])
        let actual = DockState(apps: [Sample.notes, Sample.calculator])
        #expect(!expected.matchesAfterWrite(actual))
    }

    @Test func countMattersInEachSection() {
        let one = DockState(apps: [Sample.calculator])
        let two = DockState(apps: [Sample.calculator, .spacer(.small)])
        #expect(!one.matchesAfterWrite(two))
        #expect(!two.matchesAfterWrite(one))
        #expect(!DockState(others: [Sample.docs]).matchesAfterWrite(DockState()))
    }

    @Test func itemInTheWrongSectionDoesNotMatch() {
        let expected = DockState(apps: [Sample.calculator])
        let actual = DockState(others: [Sample.calculator])
        #expect(!expected.matchesAfterWrite(actual))
    }

    @Test func emptyStatesMatch() {
        #expect(DockState().matchesAfterWrite(DockState()))
    }

    // MARK: - Apps

    @Test func appIgnoresNameBundleIdWhenPathsMatch() {
        let expected = DockItem.app(AppRef(
            bundleId: "com.apple.calculator", name: "My Calc", path: "/System/Applications/Calculator.app",
            brewCask: "calc", appStoreId: 42, launchOnSwitch: true
        ))
        let written = DockItem.app(AppRef(
            bundleId: "", name: "Calculator", path: "/System/Applications/Calculator.app"
        ))
        #expect(matches(expected, written))
    }

    @Test func appBundleIdMayBeResolvedAfterWrite() {
        let expected = DockItem.app(AppRef(bundleId: "", name: "Calculator", path: "/System/Applications/Calculator.app"))
        let written = DockItem.app(AppRef(bundleId: "com.apple.calculator", name: "Calculator", path: "/System/Applications/Calculator.app"))
        #expect(matches(expected, written))
    }

    @Test func appPathsAreComparedAfterStandardizing() {
        let expected = DockItem.app(AppRef(bundleId: "a", name: "A", path: "/Applications//Foo.app/"))
        let written = DockItem.app(AppRef(bundleId: "a", name: "A", path: "/Applications/Foo.app"))
        #expect(matches(expected, written))
    }

    @Test func differentAppDoesNotMatch() {
        #expect(!matches(Sample.calculator, Sample.notes))
    }

    @Test func differentPathWithDifferentBundleIdDoesNotMatch() {
        let expected = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: "/Applications/One.app"))
        let written = DockItem.app(AppRef(bundleId: "com.x.two", name: "One", path: "/Applications/Two.app"))
        #expect(!matches(expected, written))
    }

    @Test func appWrittenToSystemApplicationsMatches() {
        // dockutil swaps a missing /Applications/X.app for /System/Applications/X.app.
        let expected = DockItem.app(AppRef(bundleId: "", name: "Mail", path: "/Applications/Mail.app"))
        let written = DockItem.app(AppRef(bundleId: "", name: "Mail", path: "/System/Applications/Mail.app"))
        #expect(matches(expected, written))
    }

    @Test func cryptexSymlinkResolutionMatches() {
        let expected = DockItem.app(AppRef(bundleId: "", name: "Safari", path: "/Applications/Safari.app"))
        let written = DockItem.app(AppRef(
            bundleId: "", name: "Safari",
            path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        ))
        #expect(matches(expected, written))
    }

    @Test func rewriteRuleDoesNotAcceptADifferentAppName() {
        let expected = DockItem.app(AppRef(bundleId: "", name: "Mail", path: "/Applications/Mail.app"))
        let written = DockItem.app(AppRef(bundleId: "", name: "Notes", path: "/System/Applications/Notes.app"))
        #expect(!matches(expected, written))
    }

    @Test func sameBundleIdAtAnotherPathMatches() {
        let expected = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: "/Applications/One.app"))
        let written = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: "/Users/me/Applications/One.app"))
        #expect(matches(expected, written))
    }

    @Test func appWithoutPathFallsBackToIdentity() {
        let expected = DockItem.app(AppRef(bundleId: "com.x.one", name: "One", path: nil))
        #expect(matches(expected, .app(AppRef(bundleId: "com.x.one", name: "Uno", path: "/Applications/One.app"))))
        #expect(!matches(expected, .app(AppRef(bundleId: "com.x.two", name: "One", path: "/Applications/One.app"))))
        let nameOnly = DockItem.app(AppRef(bundleId: "", name: "One", path: nil))
        #expect(matches(nameOnly, .app(AppRef(bundleId: "", name: "One", path: nil))))
        #expect(!matches(nameOnly, .app(AppRef(bundleId: "", name: "Two", path: nil))))
    }

    // MARK: - URLs

    @Test func urlMustBeEqual() {
        let expected = DockItem.url(URLItem(url: URL(string: "https://example.com/a")!))
        #expect(matches(expected, .url(URLItem(url: URL(string: "https://example.com/a")!, label: "https://example.com/a"))))
        #expect(!matches(expected, .url(URLItem(url: URL(string: "https://example.com/b")!))))
    }

    @Test func urlLabelIsCheckedOnlyWhenSet() {
        let labelled = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: "Example"))
        let unlabelled = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: nil))
        let derived = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: "https://example.com"))
        let renamed = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: "Renamed"))

        #expect(matches(labelled, labelled))
        #expect(!matches(labelled, renamed))
        #expect(!matches(labelled, unlabelled))
        #expect(matches(unlabelled, derived))
        #expect(matches(unlabelled, renamed))
    }

    // MARK: - Folders

    @Test func folderOptionsMustMatch() {
        let base = FolderItem(path: "/Users/me/Docs", view: .grid, display: .folder, sort: .dateAdded, label: "Docs")
        let expected = DockItem.folder(base)

        var other = base
        other.view = .list
        #expect(!matches(expected, .folder(other)))
        other = base
        other.display = .stack
        #expect(!matches(expected, .folder(other)))
        other = base
        other.sort = .kind
        #expect(!matches(expected, .folder(other)))
        other = base
        other.path = "/Users/me/Documents"
        #expect(!matches(expected, .folder(other)))
        #expect(matches(expected, .folder(base)))
    }

    @Test func folderLabelIsDerivedWhenNotSet() {
        let expected = DockItem.folder(FolderItem(path: "/Users/me/Docs"))
        let written = DockItem.folder(FolderItem(path: "/Users/me/Docs", label: "Docs"))
        #expect(matches(expected, written))

        let labelled = DockItem.folder(FolderItem(path: "/Users/me/Docs", label: "Mine"))
        #expect(!matches(labelled, written))
    }

    // MARK: - Files, spacers, unknown

    @Test func filePathAndLabel() {
        let expected = DockItem.file(FileItem(path: "/Users/me/a.txt", label: "A"))
        #expect(matches(expected, .file(FileItem(path: "/Users/me/a.txt", label: "A"))))
        #expect(!matches(expected, .file(FileItem(path: "/Users/me/b.txt", label: "A"))))
        #expect(!matches(expected, .file(FileItem(path: "/Users/me/a.txt", label: "B"))))
        #expect(matches(.file(FileItem(path: "/Users/me/a.txt")), .file(FileItem(path: "/Users/me/a.txt", label: "a.txt"))))
    }

    @Test(arguments: SpacerKind.allCases)
    func spacerKindMustMatch(kind: SpacerKind) {
        for other in SpacerKind.allCases {
            #expect(matches(.spacer(kind), .spacer(other)) == (kind == other))
        }
    }

    @Test func unknownTilesCompareTypeAndLabel() {
        let expected = DockItem.unknown(UnknownTile(tileType: "recents-tile", label: "Recent"))
        #expect(matches(expected, expected))
        #expect(!matches(expected, .unknown(UnknownTile(tileType: "other-tile", label: "Recent"))))
        #expect(!matches(expected, .unknown(UnknownTile(tileType: "recents-tile", label: "Other"))))
    }

    @Test func differentKindsNeverMatch() {
        let items: [DockItem] = [
            Sample.calculator, Sample.example, Sample.docs, Sample.plainFile, .spacer(.normal),
            .unknown(UnknownTile(tileType: "x")),
        ]
        for (i, expected) in items.enumerated() {
            for (j, actual) in items.enumerated() where i != j {
                #expect(!matches(expected, actual), "\(expected) vs \(actual)")
            }
        }
    }
}
