import Foundation

/// Why a `DockPlan` could not be produced.
public enum DockPlanIssue: Hashable, Sendable {
    /// The target holds an `.unknown` tile that the current Dock does not contain.
    /// Unknown tiles can be kept, moved and removed, but never inserted.
    case unknownTileNotInsertable(section: DockSection, index: Int)
    /// A full rewrite is required, but `.replaceAll` cannot carry the target's `.unknown` tile.
    case fullRewriteCannotCarryUnknown(section: DockSection, index: Int)

    public var message: String {
        switch self {
        case let .unknownTileNotInsertable(section, index):
            "Unknown tile at \(section.rawValue)[\(index)] in the target cannot be created"
        case let .fullRewriteCannotCarryUnknown(section, index):
            "Full rewrite cannot carry the unknown tile at \(section.rawValue)[\(index)] in the target"
        }
    }
}

/// The result of `DiffEngine.plan`: operations that turn the current Dock into the target.
public struct DockPlan: Hashable, Sendable {
    /// Sequential operations (see `DockOperation`). Always empty when `unsatisfiable`.
    public let operations: [DockOperation]
    /// True when `operations` is a single `.replaceAll`, because spacers had to be removed
    /// or moved, or the incremental plan was too long.
    public let requiresFullRewrite: Bool
    /// Non-empty means the target cannot be produced; `operations` is then empty.
    public let issues: [DockPlanIssue]
    /// Human-readable description of the change, for the diff preview.
    public let summary: String

    public init(
        operations: [DockOperation],
        requiresFullRewrite: Bool = false,
        issues: [DockPlanIssue] = [],
        summary: String
    ) {
        self.operations = operations
        self.requiresFullRewrite = requiresFullRewrite
        self.issues = issues
        self.summary = summary
    }

    /// True when there is nothing to apply. Check `unsatisfiable` first: an unsatisfiable
    /// plan is also empty, but it does NOT mean the Dock already matches.
    public var isEmpty: Bool { operations.isEmpty }

    public var unsatisfiable: Bool { !issues.isEmpty }
}

/// Plans the operations that turn one `DockState` into another.
///
/// Guarantee: when the plan is not `unsatisfiable`, `current.applying(plan.operations) == target`.
///
/// Per section:
/// 1. Items match when they are fully equal (`DockItem ==`), as a multiset; duplicates match in
///    order. Items with the same identity but different fields (folder view, label, ...) do not
///    match, so they become remove + insert, because the backend cannot edit a tile in place.
/// 2. A weighted longest common subsequence picks the items that stay in place. Spacer matches
///    outweigh everything else, so spacers are kept in place when at all possible: they cannot be
///    removed or moved individually.
/// 3. Other items that exist on both sides are moved, the rest are removed or inserted.
/// 4. Operations are emitted as removals (highest index first), then moves, then insertions
///    (lowest index first).
public enum DiffEngine {
    /// dockutil 3.1.3 cannot remove (or move) a spacer individually, so a plan that needs to
    /// is replaced by one `.replaceAll`. Long incremental plans (more operations than this) are
    /// replaced as well: past this size one rewrite is simpler and no riskier than many
    /// separate edits. Not applied when the target holds `.unknown` tiles, which
    /// `.replaceAll` cannot carry.
    public static let maxIncrementalOperations = 40

    public static func plan(from current: DockState, to target: DockState) -> DockPlan {
        var operations: [DockOperation] = []
        var diffs: [DockSection: SectionDiff] = [:]
        var insertIssues: [DockPlanIssue] = []
        var touchesSpacer = false

        for section in DockSection.allCases {
            let diff = diffSection(section, current: current[section], target: target[section])
            operations += diff.operations
            touchesSpacer = touchesSpacer || diff.removesOrMovesSpacer
            insertIssues += diff.unknownInsertIndices.map {
                .unknownTileNotInsertable(section: section, index: $0)
            }
            diffs[section] = diff
        }

        let targetUnknowns: [DockPlanIssue] = DockSection.allCases.flatMap { section in
            target[section].enumerated().compactMap { index, item in
                if case .unknown = item {
                    DockPlanIssue.fullRewriteCannotCarryUnknown(section: section, index: index)
                } else {
                    nil
                }
            }
        }

        var issues = insertIssues
        var fullRewrite = false
        var rewriteReason: String?

        if issues.isEmpty {
            let tooLong = operations.count > maxIncrementalOperations
            if touchesSpacer || (tooLong && targetUnknowns.isEmpty) {
                if targetUnknowns.isEmpty {
                    fullRewrite = true
                    rewriteReason = touchesSpacer
                        ? "spacers cannot be removed or moved individually"
                        : "\(operations.count) operations exceed the limit of \(maxIncrementalOperations)"
                    operations = [.replaceAll(target)]
                } else {
                    issues = targetUnknowns
                }
            }
        }
        if !issues.isEmpty {
            operations = []
        }

        let summary = makeSummary(
            diffs: diffs,
            fullRewriteReason: rewriteReason,
            issues: issues
        )
        return DockPlan(
            operations: operations,
            requiresFullRewrite: fullRewrite,
            issues: issues,
            summary: summary
        )
    }

    // MARK: - Per-section diff

    private struct SectionDiff {
        var operations: [DockOperation] = []
        /// Items of the current section that are removed, in current order.
        var removed: [DockItem] = []
        /// Items inserted, in target order.
        var added: [DockItem] = []
        /// Items that are moved, in move order.
        var moved: [DockItem] = []
        /// Target indices of `.unknown` tiles that would need inserting.
        var unknownInsertIndices: [Int] = []
        var removesOrMovesSpacer = false
    }

    private static func diffSection(
        _ section: DockSection,
        current: [DockItem],
        target: [DockItem]
    ) -> SectionDiff {
        let n = current.count
        let m = target.count
        var diff = SectionDiff()

        // For each target index, the current index of the tile that ends up there
        // (kept or moved); nil means the tile is inserted.
        var source = [Int?](repeating: nil, count: m)
        var kept = Set<Int>()
        for (c, t) in keptPairs(current: current, target: target) {
            source[t] = c
            kept.insert(c)
        }

        // Unkept current items that still exist in the target are moved; the rest are removed.
        var pending: [DockItem: [Int]] = [:]
        for t in 0..<m where source[t] == nil {
            pending[target[t], default: []].append(t)
        }
        var movable = Set<Int>()
        var removedIndices: [Int] = []
        for c in 0..<n where !kept.contains(c) {
            let item = current[c]
            if var queue = pending[item], !queue.isEmpty {
                source[queue.removeFirst()] = c
                pending[item] = queue
                movable.insert(c)
            } else {
                removedIndices.append(c)
            }
        }

        // 1. Removals, highest index first so lower indices stay valid.
        for c in removedIndices.reversed() {
            diff.operations.append(.remove(section: section, index: c))
            diff.removed.append(current[c])
        }
        diff.removed.reverse()
        if diff.removed.contains(where: \.isSpacer) {
            diff.removesOrMovesSpacer = true
        }

        // 2. Moves. `working` holds current indices of surviving tiles. Each moved tile goes
        // right after its predecessor in target order, which is either kept or already placed.
        var working = (0..<n).filter { c in !removedIndices.contains(c) }
        let ordered = source.compactMap { $0 }
        for (position, c) in ordered.enumerated() where movable.contains(c) {
            // Every tile of `ordered` survives (removals are not in `working` and never in
            // `ordered`), so the lookups succeed; if that ever broke, skipping the move beats a crash.
            guard let from = working.firstIndex(of: c) else { continue }
            let anchor: Int
            if position == 0 {
                anchor = -1
            } else if let predecessor = working.firstIndex(of: ordered[position - 1]) {
                anchor = predecessor
            } else {
                continue
            }
            let to = from < anchor ? anchor : anchor + 1
            guard from != to else { continue }
            working.remove(at: from)
            working.insert(c, at: to)
            diff.operations.append(.move(section: section, from: from, to: to))
            diff.moved.append(current[c])
            if current[c].isSpacer {
                diff.removesOrMovesSpacer = true
            }
        }

        // 3. Insertions, lowest target index first: every earlier position is already final.
        for t in 0..<m where source[t] == nil {
            let item = target[t]
            if case .unknown = item {
                diff.unknownInsertIndices.append(t)
            }
            diff.operations.append(.insert(item, section: section, index: t))
            diff.added.append(item)
        }
        return diff
    }

    /// Index pairs `(current, target)` of tiles that stay in place: a longest common
    /// subsequence of equal items in which spacer matches weigh more than any number of other
    /// matches.
    private static func keptPairs(current: [DockItem], target: [DockItem]) -> [(Int, Int)] {
        let n = current.count
        let m = target.count
        guard n > 0, m > 0 else { return [] }

        let spacerWeight = min(n, m) + 1
        func weight(_ item: DockItem) -> Int { item.isSpacer ? spacerWeight : 1 }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var best = max(table[i - 1][j], table[i][j - 1])
                if current[i - 1] == target[j - 1] {
                    best = max(best, table[i - 1][j - 1] + weight(current[i - 1]))
                }
                table[i][j] = best
            }
        }

        var pairs: [(Int, Int)] = []
        var i = n
        var j = m
        while i > 0, j > 0 {
            if current[i - 1] == target[j - 1],
               table[i][j] == table[i - 1][j - 1] + weight(current[i - 1])
            {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    // MARK: - Summary

    private static func makeSummary(
        diffs: [DockSection: SectionDiff],
        fullRewriteReason: String?,
        issues: [DockPlanIssue]
    ) -> String {
        var lines: [String] = []
        for section in DockSection.allCases {
            guard let diff = diffs[section] else { continue }
            var added = diff.added
            var removed = diff.removed
            var changed: [DockItem] = []
            // A removed and an inserted tile with the same identity are one edited tile.
            for item in diff.removed {
                if let addedIndex = added.firstIndex(where: { $0.identity == item.identity }),
                   let removedIndex = removed.firstIndex(of: item)
                {
                    changed.append(added.remove(at: addedIndex))
                    removed.remove(at: removedIndex)
                }
            }
            let entries: [(String, [DockItem])] = [
                ("Added", added), ("Removed", removed), ("Changed", changed), ("Moved", diff.moved),
            ]
            let sectionLines = entries.compactMap { label, items in
                items.isEmpty ? nil : "  \(label): \(items.map(\.displayName).joined(separator: ", "))"
            }
            if !sectionLines.isEmpty {
                lines.append(section == .apps ? "Apps" : "Others")
                lines += sectionLines
            }
        }
        if let fullRewriteReason {
            lines.append("Full Dock rewrite required: \(fullRewriteReason)")
        }
        for issue in issues {
            lines.append("Cannot apply: \(issue.message)")
        }
        return lines.isEmpty ? "No changes" : lines.joined(separator: "\n")
    }
}

extension DockItem {
    var isSpacer: Bool {
        if case .spacer = self { true } else { false }
    }

    /// Short name for the diff preview.
    var displayName: String {
        switch self {
        case .app(let ref):
            if !ref.name.isEmpty { ref.name }
            else if !ref.bundleId.isEmpty { ref.bundleId }
            else { ref.path.map(lastComponent) ?? "App" }
        case .url(let item):
            if let label = item.label, !label.isEmpty { label }
            else { item.url.host ?? item.url.absoluteString }
        case .folder(let item): lastComponent(item.path)
        case .file(let item): lastComponent(item.path)
        case .spacer(.normal): "Spacer"
        case .spacer(.small): "Small spacer"
        case .spacer(.flex): "Flexible spacer"
        case .unknown(let tile): tile.label ?? tile.tileType
        }
    }
}

private func lastComponent(_ path: String) -> String {
    let component = (path as NSString).lastPathComponent
    return component.isEmpty ? path : component
}
