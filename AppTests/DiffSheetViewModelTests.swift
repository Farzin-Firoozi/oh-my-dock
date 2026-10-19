import Foundation
import OhMyDockCore
import Testing

@MainActor
@Suite struct DiffSheetViewModelTests {
    private static let safari = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))
    private static let music = DockItem.app(AppRef(bundleId: "com.apple.Music", name: "Music", path: "/Applications/Music.app"))
    private static let notes = DockItem.app(AppRef(bundleId: "com.apple.Notes", name: "Notes", path: "/Applications/Notes.app"))
    private static let terminal = DockItem.app(AppRef(bundleId: "com.apple.Terminal", name: "Terminal", path: "/Applications/Utilities/Terminal.app"))
    private static let spacer = DockItem.spacer(.normal)
    private static let flexSpacer = DockItem.spacer(.flex)
    private static let webLink = DockItem.url(URLItem(url: URL(string: "https://apple.com")!, label: "Apple"))
    private static let folder = DockItem.folder(FolderItem(path: "/Users/test/Downloads", label: "Downloads"))

    private func makePreview(
        profileName: String = "Test",
        current: DockState = DockState(),
        target: DockState = DockState(),
        operations: [DockOperation] = [],
        requiresFullRewrite: Bool = false,
        issues: [DockPlanIssue] = [],
        summary: String = "Test Summary",
        skipped: [SkippedItem] = [],
        emptiedSections: [DockSection] = [],
        clearsRecentApps: Bool = false
    ) -> ApplyPreview {
        ApplyPreview(
            profileName: profileName,
            current: current,
            target: target,
            plan: DockPlan(
                operations: operations,
                requiresFullRewrite: requiresFullRewrite,
                issues: issues,
                summary: summary
            ),
            skipped: skipped,
            emptiedSections: emptiedSections,
            clearsRecentApps: clearsRecentApps
        )
    }

    // MARK: - Preferences and apps

    @Test func prefsAndAppsGetTheirOwnSections() {
        let slack = RunningAppInfo(processIdentifier: 7, bundleId: "com.example.slack", name: "Slack")
        let preview = ApplyPreview(
            profileName: "Work",
            current: DockState(),
            target: DockState(),
            plan: DockPlan(operations: [], summary: ""),
            skipped: [],
            prefsDiff: PrefsDiff(entries: [
                .init(key: .tileSize, current: .double(48), target: .double(64)),
                .init(key: .autohide, current: nil, target: .bool(true)),
            ]),
            switchPlan: SwitchPlan(
                scope: .previousProfileApps,
                willQuit: [slack],
                willLaunch: [LaunchRequest(bundleId: "com.example.figma", name: "Figma")]
            )
        )
        let model = DiffSheetViewModel(preview: preview)

        #expect(model.prefs.map(\.name) == ["Icon size", "Automatically hide"])
        #expect(model.prefs.map(\.target) == ["64", "On"])
        #expect(model.prefs.first?.current == "48")
        #expect(model.prefs.last?.current == "Default")
        #expect(model.apps.map(\.name) == ["Slack", "Figma"])
        #expect(model.apps.map(\.action) == [.quit, .open])
        #expect(model.hasChanges)
        #expect(model.canApply)
    }

    @Test func noPrefsAndNoSwitcherMeansNoExtraSections() {
        let model = DiffSheetViewModel(preview: makePreview())
        #expect(model.prefs.isEmpty)
        #expect(model.apps.isEmpty)
    }

    // MARK: - Additions

    @Test func additionsAreMappedFromInsertOperations() {
        let preview = makePreview(
            current: DockState(apps: [Self.safari]),
            operations: [
                .insert(Self.music, section: .apps, index: 1),
                .insert(Self.webLink, section: .others, index: 0),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.additions.count == 2)
        #expect(model.additions[0].name == "Music")
        #expect(model.additions[0].section == .apps)
        #expect(model.additions[0].index == 1)
        #expect(model.additions[0].detail == "/Applications/Music.app")
        #expect(model.additions[0].systemImage == "app.fill")

        #expect(model.additions[1].name == "Apple")
        #expect(model.additions[1].section == .others)
        #expect(model.additions[1].index == 0)
        #expect(model.additions[1].detail == "https://apple.com")
        #expect(model.additions[1].systemImage == "globe")

        #expect(model.removals.isEmpty)
        #expect(model.moves.isEmpty)
        #expect(model.hasChanges)
        #expect(model.totalChangesCount == 2)
    }

    // MARK: - Removals

    @Test func removalsAreMappedFromRemoveOperationsWithItemLookup() {
        let preview = makePreview(
            current: DockState(apps: [Self.safari, Self.music]),
            operations: [
                .remove(section: .apps, index: 1),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.removals.count == 1)
        #expect(model.removals[0].name == "Music")
        #expect(model.removals[0].section == .apps)
        #expect(model.removals[0].index == 1)
        #expect(model.removals[0].item == Self.music)
        #expect(model.removals[0].detail == "/Applications/Music.app")
        #expect(model.additions.isEmpty)
        #expect(model.moves.isEmpty)
    }

    // MARK: - Moves

    @Test func movesAreMappedFromMoveOperationsWithItemLookup() {
        let preview = makePreview(
            current: DockState(apps: [Self.safari, Self.music, Self.notes]),
            operations: [
                .move(section: .apps, from: 0, to: 2),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.moves.count == 1)
        #expect(model.moves[0].name == "Safari")
        #expect(model.moves[0].section == .apps)
        #expect(model.moves[0].fromIndex == 0)
        #expect(model.moves[0].toIndex == 2)
        #expect(model.moves[0].detail == "Position 1 → 3")
        #expect(model.moves[0].item == Self.safari)
        #expect(model.additions.isEmpty)
        #expect(model.removals.isEmpty)
    }

    // MARK: - Sequential Simulation

    @Test func sequentialSimulationCorrectlyTracksWorkingIndices() {
        // Initial state: [Safari, Music, Notes]
        // Op 1: remove Notes at index 2 -> working becomes [Safari, Music]
        // Op 2: remove Safari at index 0 -> working becomes [Music]
        // Op 3: insert Terminal at index 0 -> working becomes [Terminal, Music]
        // Op 4: move Music from index 1 to 0 -> working becomes [Music, Terminal]
        let preview = makePreview(
            current: DockState(apps: [Self.safari, Self.music, Self.notes]),
            operations: [
                .remove(section: .apps, index: 2),
                .remove(section: .apps, index: 0),
                .insert(Self.terminal, section: .apps, index: 0),
                .move(section: .apps, from: 1, to: 0),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.removals.count == 2)
        #expect(model.removals[0].name == "Notes")
        #expect(model.removals[1].name == "Safari")

        #expect(model.additions.count == 1)
        #expect(model.additions[0].name == "Terminal")
        #expect(model.additions[0].index == 0)

        #expect(model.moves.count == 1)
        #expect(model.moves[0].name == "Music")
        #expect(model.moves[0].fromIndex == 1)
        #expect(model.moves[0].toIndex == 0)
    }

    // MARK: - Skipped Items

    @Test func skippedItemsAreMappedWithReasonAndDetails() {
        let missingApp = AppRef(bundleId: "com.example.missing", name: "MissingApp", path: nil)
        let skippedItem = SkippedItem(section: .apps, index: 3, app: missingApp, reason: .appNotFound)
        let preview = makePreview(
            current: DockState(apps: [Self.safari]),
            skipped: [skippedItem]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.skipped.count == 1)
        #expect(model.skipped[0].name == "MissingApp")
        #expect(model.skipped[0].section == .apps)
        #expect(model.skipped[0].index == 3)
        #expect(model.skipped[0].reason == "App not found on system")
        #expect(model.skipped[0].detail == "com.example.missing")
        #expect(model.skipped[0].systemImage == "questionmark.app.fill")
        #expect(model.canApply) // Skipped apps alone do not prevent apply
    }

    // MARK: - Warnings and Issues

    @Test func planIssuesProduceErrorWarningsAndDisableApply() {
        let preview = makePreview(
            issues: [
                .unknownTileNotInsertable(section: .apps, index: 1),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(!model.canApply)
        #expect(model.warnings.count == 1)
        #expect(model.warnings[0].severity == .error)
        #expect(model.warnings[0].title == "Cannot Apply Profile")
        #expect(model.warnings[0].detail == DockPlanIssue.unknownTileNotInsertable(section: .apps, index: 1).message)
        #expect(model.warnings[0].systemImage == "xmark.octagon.fill")
        #expect(model.additions.isEmpty)
        #expect(model.removals.isEmpty)
        #expect(model.moves.isEmpty)
    }

    @Test func emptiedSectionsProduceErrorWarningsAndDisableApply() {
        let preview = makePreview(
            emptiedSections: [.apps]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(!model.canApply)
        let emptiedWarning = model.warnings.first { $0.id == "emptied-apps" }
        #expect(emptiedWarning != nil)
        #expect(emptiedWarning?.severity == .error)
        #expect(emptiedWarning?.title == "Apps Section Empty")
    }

    @Test func fullRewriteProducesWarning() {
        let preview = makePreview(
            requiresFullRewrite: true
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.canApply)
        let rewriteWarning = model.warnings.first { $0.id == "warning-full-rewrite" }
        #expect(rewriteWarning != nil)
        #expect(rewriteWarning?.severity == .warning)
        #expect(rewriteWarning?.title == "Full Dock Rewrite Required")
    }

    @Test func clearsRecentAppsProducesWarning() {
        let preview = makePreview(
            clearsRecentApps: true
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.canApply)
        let recentsWarning = model.warnings.first { $0.id == "warning-clears-recents" }
        #expect(recentsWarning != nil)
        #expect(recentsWarning?.severity == .warning)
        #expect(recentsWarning?.title == "Recent Apps Will Be Cleared")
    }

    // MARK: - ReplaceAll Plan

    @Test func replaceAllPlanDerivesAdditionsRemovalsAndMoves() {
        let current = DockState(apps: [Self.safari, Self.music])
        let target = DockState(apps: [Self.music, Self.notes])
        let preview = makePreview(
            current: current,
            target: target,
            operations: [.replaceAll(target)],
            requiresFullRewrite: true
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.canApply)
        // Safari is removed
        #expect(model.removals.contains(where: { $0.name == "Safari" }))
        // Notes is added
        #expect(model.additions.contains(where: { $0.name == "Notes" }))
        // Music moved from index 1 to index 0
        #expect(model.moves.contains(where: { $0.name == "Music" && $0.fromIndex == 1 && $0.toIndex == 0 }))
        // Full rewrite warning present
        #expect(model.warnings.contains(where: { $0.id == "warning-full-rewrite" }))
    }

    // MARK: - Empty Plan (No changes)

    @Test func emptyPlanHasNoChanges() {
        let preview = makePreview(
            current: DockState(apps: [Self.safari]),
            target: DockState(apps: [Self.safari]),
            operations: []
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(!model.hasChanges)
        #expect(model.additions.isEmpty)
        #expect(model.removals.isEmpty)
        #expect(model.moves.isEmpty)
        #expect(model.skipped.isEmpty)
        #expect(model.warnings.isEmpty)
        #expect(model.canApply)
        #expect(model.totalChangesCount == 0)
    }

    // MARK: - Various DockItem Types

    @Test func variousDockItemsHaveCorrectDisplayNamesAndSymbols() {
        let preview = makePreview(
            operations: [
                .insert(Self.folder, section: .others, index: 0),
                .insert(Self.spacer, section: .apps, index: 1),
                .insert(Self.flexSpacer, section: .apps, index: 2),
            ]
        )

        let model = DiffSheetViewModel(preview: preview)

        #expect(model.additions.count == 3)
        #expect(model.additions[0].name == "Downloads")
        #expect(model.additions[0].systemImage == "folder.fill")

        #expect(model.additions[1].name == "Spacer")
        #expect(model.additions[1].systemImage == "space")

        #expect(model.additions[2].name == "Flexible spacer")
        #expect(model.additions[2].systemImage == "space")
    }
}
