import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DiffEngineTests {
    private func app(_ name: String, launch: Bool = false) -> DockItem {
        .app(AppRef(bundleId: "com.test.\(name)", name: name, launchOnSwitch: launch))
    }

    private func folder(_ name: String, view: FolderView = .auto, label: String? = nil) -> DockItem {
        .folder(FolderItem(path: "/Users/me/\(name)", view: view, label: label))
    }

    private let spacer = DockItem.spacer(.normal)
    private let smallSpacer = DockItem.spacer(.small)
    private let flexSpacer = DockItem.spacer(.flex)
    private let unknown = DockItem.unknown(UnknownTile(tileType: "recents-tile", label: "Recents"))

    private func assertCorrect(
        _ current: DockState,
        _ target: DockState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> DockPlan {
        let plan = DiffEngine.plan(from: current, to: target)
        #expect(!plan.unsatisfiable, sourceLocation: sourceLocation)
        #expect(try current.applying(plan.operations) == target, sourceLocation: sourceLocation)
        return plan
    }

    // MARK: - Basics

    @Test func equalStatesProduceNoOperations() throws {
        let state = DockState(apps: [app("A"), spacer, app("B")], others: [folder("Downloads")])
        let plan = try assertCorrect(state, state)
        #expect(plan.isEmpty)
        #expect(!plan.requiresFullRewrite)
        #expect(plan.summary == "No changes")
    }

    @Test func emptyStatesProduceNoOperations() throws {
        #expect(try assertCorrect(DockState(), DockState()).isEmpty)
    }

    @Test func pureInserts() throws {
        let a = app("A"), b = app("B"), x = app("X"), y = app("Y")
        let plan = try assertCorrect(DockState(apps: [a, b]), DockState(apps: [a, x, b, y]))
        #expect(plan.operations == [
            .insert(x, section: .apps, index: 1),
            .insert(y, section: .apps, index: 3),
        ])
    }

    @Test func insertIntoEmptySection() throws {
        let f = folder("Downloads")
        let plan = try assertCorrect(DockState(), DockState(others: [f]))
        #expect(plan.operations == [.insert(f, section: .others, index: 0)])
    }

    @Test func pureRemovals() throws {
        let a = app("A"), b = app("B"), c = app("C"), d = app("D")
        let plan = try assertCorrect(DockState(apps: [a, b, c, d]), DockState(apps: [b, d]))
        #expect(plan.operations == [
            .remove(section: .apps, index: 2),
            .remove(section: .apps, index: 0),
        ])
        #expect(!plan.requiresFullRewrite)
    }

    @Test func removeEverything() throws {
        let plan = try assertCorrect(DockState(apps: [app("A"), app("B")]), DockState())
        #expect(plan.operations.count == 2)
    }

    // MARK: - Moves

    @Test func moveFirstToLastIsOneMove() throws {
        let a = app("A"), b = app("B"), c = app("C"), d = app("D")
        let plan = try assertCorrect(DockState(apps: [a, b, c, d]), DockState(apps: [b, c, d, a]))
        #expect(plan.operations == [.move(section: .apps, from: 0, to: 3)])
    }

    @Test func moveLastToFirstIsOneMove() throws {
        let a = app("A"), b = app("B"), c = app("C")
        let plan = try assertCorrect(DockState(apps: [a, b, c]), DockState(apps: [c, a, b]))
        #expect(plan.operations == [.move(section: .apps, from: 2, to: 0)])
    }

    @Test func swapIsOneMove() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, b]), DockState(apps: [b, a]))
        #expect(plan.operations.count == 1)
    }

    @Test func reversalNeedsNMinusOneMoves() throws {
        let items = (0..<6).map { app("App\($0)") }
        let plan = try assertCorrect(DockState(apps: items), DockState(apps: items.reversed()))
        #expect(plan.operations.count == 5)
        #expect(plan.operations.allSatisfy { if case .move = $0 { true } else { false } })
    }

    @Test func keptItemsAreNotMoved() throws {
        // Only B moves; A, C, D, E stay (LCS), so exactly one move.
        let a = app("A"), b = app("B"), c = app("C"), d = app("D"), e = app("E")
        let plan = try assertCorrect(DockState(apps: [a, b, c, d, e]), DockState(apps: [a, c, d, e, b]))
        #expect(plan.operations.count == 1)
    }

    // MARK: - Mixed

    @Test func mixedChangesInBothSections() throws {
        let a = app("A"), b = app("B"), c = app("C"), x = app("X")
        let dl = folder("Downloads"), docs = folder("Documents")
        let url = DockItem.url(URLItem(url: URL(string: "https://example.com")!))
        let current = DockState(apps: [a, b, c], others: [dl, url])
        let target = DockState(apps: [c, x, a], others: [docs, dl])
        let plan = try assertCorrect(current, target)
        #expect(!plan.requiresFullRewrite)
        #expect(plan.operations.count < 8)
    }

    @Test func sectionsAreIndependent() throws {
        let a = app("A")
        // Same item in a different section is remove + insert, not a move.
        let plan = try assertCorrect(DockState(apps: [a]), DockState(others: [a]))
        #expect(plan.operations == [
            .remove(section: .apps, index: 0),
            .insert(a, section: .others, index: 0),
        ])
    }

    // MARK: - Duplicates

    @Test func duplicateAppsMatchInOrder() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, b, a]), DockState(apps: [a, b, a]))
        #expect(plan.isEmpty)
    }

    @Test func removingOneOfTwoDuplicates() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, a, b]), DockState(apps: [a, b]))
        #expect(plan.operations.count == 1)
    }

    @Test func addingADuplicate() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, b]), DockState(apps: [a, b, a]))
        #expect(plan.operations == [.insert(a, section: .apps, index: 2)])
    }

    @Test func duplicateReorder() throws {
        let a = app("A"), b = app("B")
        _ = try assertCorrect(DockState(apps: [a, b, a, b]), DockState(apps: [b, a, b, a]))
    }

    @Test func identicalSpacersAreMatchedInOrder() throws {
        let a = app("A"), b = app("B")
        let current = DockState(apps: [a, spacer, b, spacer])
        let plan = try assertCorrect(current, current)
        #expect(plan.isEmpty)
    }

    // MARK: - Field changes

    @Test func changedFolderViewIsRemoveAndInsertAtSamePosition() throws {
        let a = app("A"), b = app("B")
        let oldFolder = folder("Downloads", view: .grid)
        let newFolder = folder("Downloads", view: .list)
        #expect(oldFolder.identity == newFolder.identity)
        let plan = try assertCorrect(
            DockState(apps: [a], others: [b, oldFolder, b]),
            DockState(apps: [a], others: [b, newFolder, b])
        )
        #expect(plan.operations == [
            .remove(section: .others, index: 1),
            .insert(newFolder, section: .others, index: 1),
        ])
        #expect(plan.summary.contains("Changed: Downloads"))
    }

    @Test func changedLabelIsRemoveAndInsert() throws {
        let plan = try assertCorrect(
            DockState(others: [folder("Downloads", label: "Old")]),
            DockState(others: [folder("Downloads", label: "New")])
        )
        #expect(plan.operations.count == 2)
    }

    @Test func changedAppFieldIsRemoveAndInsert() throws {
        let plan = try assertCorrect(
            DockState(apps: [app("A", launch: false)]),
            DockState(apps: [app("A", launch: true)])
        )
        #expect(plan.operations.count == 2)
    }

    // MARK: - Spacers

    @Test func spacerRemovalFallsBackToReplaceAll() throws {
        let a = app("A"), b = app("B")
        let target = DockState(apps: [a, b])
        let plan = try assertCorrect(DockState(apps: [a, spacer, b]), target)
        #expect(plan.requiresFullRewrite)
        #expect(plan.operations == [.replaceAll(target)])
        #expect(plan.summary.contains("Full Dock rewrite required"))
    }

    @Test func spacerRemovalInOthersFallsBackToReplaceAll() throws {
        let f = folder("Downloads")
        let target = DockState(others: [f])
        let plan = try assertCorrect(DockState(others: [f, flexSpacer]), target)
        #expect(plan.operations == [.replaceAll(target)])
    }

    @Test func spacerKindChangeFallsBackToReplaceAll() throws {
        let a = app("A")
        let plan = try assertCorrect(DockState(apps: [a, spacer]), DockState(apps: [a, smallSpacer]))
        #expect(plan.requiresFullRewrite)
    }

    @Test func spacerInsertionOnlyIsIncremental() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, b]), DockState(apps: [a, smallSpacer, b]))
        #expect(!plan.requiresFullRewrite)
        #expect(plan.operations == [.insert(smallSpacer, section: .apps, index: 1)])
    }

    @Test func spacersStayPutWhileNeighboursMove() throws {
        let a = app("A")
        let plan = try assertCorrect(DockState(apps: [spacer, a]), DockState(apps: [a, spacer]))
        #expect(!plan.requiresFullRewrite)
        #expect(plan.operations == [.move(section: .apps, from: 1, to: 0)])
    }

    @Test func spacerWouldNeedMovingFallsBackToReplaceAll() throws {
        let plan = try assertCorrect(
            DockState(apps: [spacer, smallSpacer]),
            DockState(apps: [smallSpacer, spacer])
        )
        #expect(plan.requiresFullRewrite)
    }

    @Test func spacerRewriteIsNotAppliedWhenSpacersUntouched() throws {
        let a = app("A"), b = app("B"), c = app("C")
        let plan = try assertCorrect(
            DockState(apps: [a, spacer, b, spacer, c]),
            DockState(apps: [c, a, spacer, b, spacer])
        )
        #expect(!plan.requiresFullRewrite)
        #expect(plan.operations.count == 1)
    }

    // MARK: - Unknown tiles

    @Test func unknownInCurrentIsRemoved() throws {
        let a = app("A")
        let plan = try assertCorrect(DockState(apps: [unknown, a], others: [unknown]), DockState(apps: [a]))
        #expect(plan.operations == [
            .remove(section: .apps, index: 0),
            .remove(section: .others, index: 0),
        ])
    }

    @Test func unknownInBothIsKeptInPlace() throws {
        let a = app("A"), b = app("B")
        let plan = try assertCorrect(DockState(apps: [a, unknown]), DockState(apps: [a, b, unknown]))
        #expect(plan.operations == [.insert(b, section: .apps, index: 1)])
    }

    @Test func unknownInBothCanMove() throws {
        let a = app("A")
        let plan = try assertCorrect(DockState(apps: [unknown, a]), DockState(apps: [a, unknown]))
        #expect(plan.operations.count == 1)
    }

    @Test func equalStatesWithUnknownAreEmpty() throws {
        let state = DockState(apps: [unknown], others: [unknown])
        #expect(try assertCorrect(state, state).isEmpty)
    }

    @Test func unknownInTargetOnlyIsUnsatisfiable() {
        let a = app("A")
        let plan = DiffEngine.plan(from: DockState(apps: [a]), to: DockState(apps: [a, unknown]))
        #expect(plan.unsatisfiable)
        #expect(plan.operations.isEmpty)
        #expect(plan.issues == [.unknownTileNotInsertable(section: .apps, index: 1)])
        #expect(plan.summary.contains("Cannot apply"))
    }

    @Test func rewriteWithUnknownInTargetIsUnsatisfiable() {
        let plan = DiffEngine.plan(
            from: DockState(apps: [spacer, unknown]),
            to: DockState(apps: [unknown])
        )
        #expect(plan.unsatisfiable)
        #expect(plan.operations.isEmpty)
        #expect(!plan.requiresFullRewrite)
        #expect(plan.issues == [.fullRewriteCannotCarryUnknown(section: .apps, index: 0)])
    }

    @Test func removedSpacerWithUnknownInCurrentOnlyStillRewrites() throws {
        let a = app("A")
        let target = DockState(apps: [a])
        let plan = try assertCorrect(DockState(apps: [unknown, spacer, a]), target)
        #expect(plan.operations == [.replaceAll(target)])
    }

    // MARK: - Threshold

    @Test func atThresholdStaysIncremental() throws {
        let limit = DiffEngine.maxIncrementalOperations
        let old = (0..<(limit / 2)).map { app("Old\($0)") }
        let new = (0..<(limit / 2)).map { app("New\($0)") }
        let plan = try assertCorrect(DockState(apps: old), DockState(apps: new))
        #expect(plan.operations.count == limit)
        #expect(!plan.requiresFullRewrite)
    }

    @Test func overThresholdFallsBackToReplaceAll() throws {
        let limit = DiffEngine.maxIncrementalOperations
        let old = (0...(limit / 2)).map { app("Old\($0)") }
        let new = (0..<(limit / 2)).map { app("New\($0)") }
        let target = DockState(apps: new)
        let plan = try assertCorrect(DockState(apps: old), target)
        #expect(plan.requiresFullRewrite)
        #expect(plan.operations == [.replaceAll(target)])
        #expect(plan.summary.contains("exceed the limit of \(limit)"))
    }

    @Test func overThresholdKeepsIncrementalWhenTargetHoldsUnknown() throws {
        let old = (0..<30).map { app("Old\($0)") } + [unknown]
        let new = (0..<30).map { app("New\($0)") } + [unknown]
        let plan = try assertCorrect(DockState(apps: old), DockState(apps: new))
        #expect(plan.operations.count > DiffEngine.maxIncrementalOperations)
        #expect(!plan.requiresFullRewrite)
    }

    // MARK: - Summary

    @Test func summaryListsAddedRemovedAndMovedPerSection() throws {
        let safari = DockItem.app(AppRef(bundleId: "com.apple.Safari", name: "Safari"))
        let mail = DockItem.app(AppRef(bundleId: "com.apple.mail", name: "Mail"))
        let notes = DockItem.app(AppRef(bundleId: "com.apple.Notes", name: "Notes"))
        let link = DockItem.url(URLItem(url: URL(string: "https://example.com/docs")!))
        let labeled = DockItem.url(URLItem(url: URL(string: "https://swift.org")!, label: "Swift"))
        let file = DockItem.file(FileItem(path: "/Users/me/notes.txt"))
        let plan = try assertCorrect(
            DockState(apps: [safari, mail, notes], others: [file, link]),
            DockState(apps: [notes, safari, smallSpacer], others: [link, labeled])
        )
        #expect(plan.summary.hasPrefix("Apps\n"))
        #expect(plan.summary.contains("Added: Small spacer"))
        #expect(plan.summary.contains("\nOthers\n"))
        #expect(plan.summary.contains("Removed: Mail"))
        #expect(plan.summary.contains("Added: Swift"))
        #expect(plan.summary.contains("Removed: notes.txt"))
    }

    @Test func summaryNamesEveryItemKind() {
        #expect(DockItem.app(AppRef(bundleId: "x", name: "Figma")).displayName == "Figma")
        #expect(DockItem.url(URLItem(url: URL(string: "https://example.com/a")!)).displayName == "example.com")
        #expect(DockItem.url(URLItem(url: URL(string: "https://example.com/a")!, label: "Docs")).displayName == "Docs")
        #expect(folder("Downloads").displayName == "Downloads")
        #expect(DockItem.file(FileItem(path: "/Users/me/notes.txt")).displayName == "notes.txt")
        #expect(spacer.displayName == "Spacer")
        #expect(smallSpacer.displayName == "Small spacer")
        #expect(flexSpacer.displayName == "Flexible spacer")
        #expect(unknown.displayName == "Recents")
    }

    // MARK: - Determinism

    @Test func planIsDeterministic() {
        let items = (0..<6).map { app("A\($0)") }
        let current = DockState(apps: items, others: [spacer])
        let target = DockState(apps: items.reversed(), others: [spacer, folder("X")])
        #expect(DiffEngine.plan(from: current, to: target) == DiffEngine.plan(from: current, to: target))
    }
}

// MARK: - Randomized property test

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct DiffEnginePropertyTests {
    private static let apps: [DockItem] = (0..<6).map {
        .app(AppRef(bundleId: "com.test.app\($0)", name: "App\($0)"))
    } + [
        .app(AppRef(bundleId: "com.test.app0", name: "App0", launchOnSwitch: true)),
        .app(AppRef(bundleId: "", name: "NoBundle", path: "/Applications/NoBundle.app")),
    ]
    private static let others: [DockItem] = [
        .url(URLItem(url: URL(string: "https://example.com")!)),
        .url(URLItem(url: URL(string: "https://swift.org")!, label: "Swift")),
        .folder(FolderItem(path: "/Users/me/Downloads", view: .grid)),
        .folder(FolderItem(path: "/Users/me/Downloads", view: .list)),
        .folder(FolderItem(path: "/Users/me/Documents")),
        .file(FileItem(path: "/Users/me/notes.txt")),
    ]
    private static let spacers: [DockItem] = SpacerKind.allCases.map { .spacer($0) }
    private static let unknowns: [DockItem] = [
        .unknown(UnknownTile(tileType: "recents-tile", label: "Recents")),
        .unknown(UnknownTile(tileType: "directory-tile")),
    ]

    private static func randomItem(
        _ rng: inout SplitMix64,
        section: DockSection,
        allowUnknown: Bool
    ) -> DockItem {
        let roll = Int.random(in: 0..<100, using: &rng)
        if roll < 20 { return spacers.randomElement(using: &rng)! }
        if allowUnknown && roll < 28 { return unknowns.randomElement(using: &rng)! }
        let pool = section == .apps ? apps : others
        return pool.randomElement(using: &rng)!
    }

    private static func randomList(
        _ rng: inout SplitMix64,
        section: DockSection,
        allowUnknown: Bool
    ) -> [DockItem] {
        let count = Int.random(in: 0...9, using: &rng)
        return (0..<count).map { _ in randomItem(&rng, section: section, allowUnknown: allowUnknown) }
    }

    /// Mutates `list` by shuffling, dropping, inserting and tweaking, so that targets
    /// overlap heavily with current and exercise moves.
    private static func mutate(
        _ list: [DockItem],
        _ rng: inout SplitMix64,
        section: DockSection
    ) -> [DockItem] {
        var result = list.filter { item in
            if case .unknown = item { return Bool.random(using: &rng) }
            return Int.random(in: 0..<10, using: &rng) > 1
        }
        if Bool.random(using: &rng) { result.shuffle(using: &rng) }
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let item = randomItem(&rng, section: section, allowUnknown: false)
            result.insert(item, at: Int.random(in: 0...result.count, using: &rng))
        }
        return result
    }

    /// Replays `ops` and reports whether any `remove`/`move` touched a spacer.
    private static func touchesSpacer(_ state: DockState, _ ops: [DockOperation]) throws -> Bool {
        var state = state
        for op in ops {
            switch op {
            case let .remove(section, index), let .move(section, index, _):
                if state[section][index].isSpacer { return true }
            default: break
            }
            state = try state.applying([op])
        }
        return false
    }

    @Test func planAppliesToTargetForRandomStates() throws {
        var rng = SplitMix64(state: 0xD0C4_5EED)
        var rewrites = 0
        var incrementalWithOps = 0
        var unsatisfiable = 0
        let cases = 3000
        for caseIndex in 0..<cases {
            let current = DockState(
                apps: Self.randomList(&rng, section: .apps, allowUnknown: true),
                others: Self.randomList(&rng, section: .others, allowUnknown: true)
            )
            let target: DockState
            if Int.random(in: 0..<3, using: &rng) == 0 {
                target = DockState(
                    apps: Self.randomList(&rng, section: .apps, allowUnknown: false),
                    others: Self.randomList(&rng, section: .others, allowUnknown: false)
                )
            } else {
                target = DockState(
                    apps: Self.mutate(current.apps, &rng, section: .apps),
                    others: Self.mutate(current.others, &rng, section: .others)
                )
            }

            let plan = DiffEngine.plan(from: current, to: target)
            if plan.unsatisfiable {
                // Only possible when the target keeps an unknown tile and a full rewrite is needed.
                unsatisfiable += 1
                let targetHasUnknown = DockSection.allCases.contains { section in
                    target[section].contains { if case .unknown = $0 { true } else { false } }
                }
                #expect(targetHasUnknown, "case \(caseIndex)")
                #expect(plan.operations.isEmpty, "case \(caseIndex)")
                #expect(!plan.requiresFullRewrite, "case \(caseIndex)")
                continue
            }
            let result = try current.applying(plan.operations)
            #expect(result == target, "case \(caseIndex): \(current) -> \(target) via \(plan.operations)")

            if current == target { #expect(plan.isEmpty, "case \(caseIndex)") }

            if plan.requiresFullRewrite {
                rewrites += 1
                #expect(plan.operations == [.replaceAll(target)], "case \(caseIndex)")
            } else {
                if !plan.isEmpty { incrementalWithOps += 1 }
                #expect(!plan.operations.contains { if case .replaceAll = $0 { true } else { false } })
                #expect(try !Self.touchesSpacer(current, plan.operations), "case \(caseIndex)")
                #expect(plan.operations.count <= DiffEngine.maxIncrementalOperations)
                // Never worse than removing everything and inserting everything.
                let upperBound = current.apps.count + current.others.count + target.apps.count + target.others.count
                #expect(plan.operations.count <= upperBound, "case \(caseIndex)")
            }
        }
        // The generator must exercise both paths.
        #expect(rewrites > 100)
        #expect(incrementalWithOps > 100)
        #expect(unsatisfiable < cases / 10)
    }

    @Test func planIsMinimalForSpacerFreeStates() throws {
        // Without spacers or field edits the plan size is |C| + |T| - 2M + (M - L) where
        // M = multiset intersection size and L = LCS length; check against a brute-force LCS.
        var rng = SplitMix64(state: 42)
        for caseIndex in 0..<500 {
            let current = (0..<Int.random(in: 0...8, using: &rng)).map { _ in Self.apps.randomElement(using: &rng)! }
            let target = (0..<Int.random(in: 0...8, using: &rng)).map { _ in Self.apps.randomElement(using: &rng)! }
            let plan = DiffEngine.plan(from: DockState(apps: current), to: DockState(apps: target))
            #expect(try DockState(apps: current).applying(plan.operations).apps == target)

            var remaining = target
            var matched = 0
            for item in current {
                if let index = remaining.firstIndex(of: item) {
                    remaining.remove(at: index)
                    matched += 1
                }
            }
            let lcs = Self.lcsLength(current, target)
            let expected = (current.count - matched) + (target.count - matched) + (matched - lcs)
            #expect(plan.operations.count == expected, "case \(caseIndex)")
        }
    }

    private static func lcsLength(_ a: [DockItem], _ b: [DockItem]) -> Int {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return table[a.count][b.count]
    }
}
