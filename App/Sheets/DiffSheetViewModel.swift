import AppKit
import Foundation
import Observation
import OhMyDockCore

/// Pure view model mapping `ApplyPreview` into itemised display rows for `DiffSheetView`.
@MainActor
@Observable
public final class DiffSheetViewModel {
    public enum WarningSeverity: Equatable, Sendable {
        case warning
        case error
    }

    public struct WarningRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let severity: WarningSeverity
        public let title: String
        public let detail: String?
        public let systemImage: String

        public init(
            id: String,
            severity: WarningSeverity,
            title: String,
            detail: String?,
            systemImage: String
        ) {
            self.id = id
            self.severity = severity
            self.title = title
            self.detail = detail
            self.systemImage = systemImage
        }
    }

    public struct AdditionRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let item: DockItem
        public let name: String
        public let section: DockSection
        public let index: Int
        public let detail: String?
        public let systemImage: String

        public init(
            id: String,
            item: DockItem,
            name: String,
            section: DockSection,
            index: Int,
            detail: String?,
            systemImage: String
        ) {
            self.id = id
            self.item = item
            self.name = name
            self.section = section
            self.index = index
            self.detail = detail
            self.systemImage = systemImage
        }
    }

    public struct RemovalRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let item: DockItem?
        public let name: String
        public let section: DockSection
        public let index: Int
        public let detail: String?
        public let systemImage: String

        public init(
            id: String,
            item: DockItem?,
            name: String,
            section: DockSection,
            index: Int,
            detail: String?,
            systemImage: String
        ) {
            self.id = id
            self.item = item
            self.name = name
            self.section = section
            self.index = index
            self.detail = detail
            self.systemImage = systemImage
        }
    }

    public struct MoveRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let item: DockItem?
        public let name: String
        public let section: DockSection
        public let fromIndex: Int
        public let toIndex: Int
        public let detail: String?
        public let systemImage: String

        public init(
            id: String,
            item: DockItem?,
            name: String,
            section: DockSection,
            fromIndex: Int,
            toIndex: Int,
            detail: String?,
            systemImage: String
        ) {
            self.id = id
            self.item = item
            self.name = name
            self.section = section
            self.fromIndex = fromIndex
            self.toIndex = toIndex
            self.detail = detail
            self.systemImage = systemImage
        }
    }

    public struct SkippedItemRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let item: SkippedItem
        public let name: String
        public let section: DockSection
        public let index: Int
        public let reason: String
        public let detail: String?
        public let systemImage: String

        public init(
            id: String,
            item: SkippedItem,
            name: String,
            section: DockSection,
            index: Int,
            reason: String,
            detail: String?,
            systemImage: String
        ) {
            self.id = id
            self.item = item
            self.name = name
            self.section = section
            self.index = index
            self.reason = reason
            self.detail = detail
            self.systemImage = systemImage
        }
    }

    /// One Dock preference key the profile would change.
    public struct PrefRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let current: String
        public let target: String
    }

    /// One app the switch would quit or open.
    public struct AppRow: Identifiable, Equatable, Sendable {
        public enum Action: Equatable, Sendable { case quit, open }
        public let id: String
        public let name: String
        public let action: Action
    }

    // MARK: - Properties

    public let profileName: String
    public let summary: String
    public let warnings: [WarningRow]
    public let additions: [AdditionRow]
    public let removals: [RemovalRow]
    public let moves: [MoveRow]
    public let skipped: [SkippedItemRow]
    public let canApply: Bool
    /// "Dock preferences" section: keys whose value would change. Empty when the profile sets none.
    public let prefs: [PrefRow]
    /// "Apps" section: running apps to quit and apps to open.
    public let apps: [AppRow]

    public var hasChanges: Bool {
        !additions.isEmpty || !removals.isEmpty || !moves.isEmpty || !skipped.isEmpty
            || !prefs.isEmpty || !apps.isEmpty
    }

    public var totalChangesCount: Int {
        additions.count + removals.count + moves.count
    }

    // MARK: - Initializer

    public init(preview: ApplyPreview) {
        self.profileName = preview.profileName
        self.summary = preview.plan.summary

        var warningsAccumulator: [WarningRow] = []

        // Issues are blocking errors
        for (i, issue) in preview.plan.issues.enumerated() {
            warningsAccumulator.append(
                WarningRow(
                    id: "issue-\(i)",
                    severity: .error,
                    title: "Cannot Apply Profile",
                    detail: issue.message,
                    systemImage: "xmark.octagon.fill"
                )
            )
        }

        // Emptied sections are fatal errors
        for section in preview.emptiedSections {
            warningsAccumulator.append(
                WarningRow(
                    id: "emptied-\(section.rawValue)",
                    severity: .error,
                    title: "\(section.title) Section Empty",
                    detail: "Applying this profile would remove all items from \(section.title). Oh My Dock protects against empty sections.",
                    systemImage: "exclamationmark.octagon.fill"
                )
            )
        }

        // Full rewrite warning
        if preview.plan.requiresFullRewrite {
            warningsAccumulator.append(
                WarningRow(
                    id: "warning-full-rewrite",
                    severity: .warning,
                    title: "Full Dock Rewrite Required",
                    detail: "The Dock layout requires a full rewrite instead of incremental updates.",
                    systemImage: "exclamationmark.triangle.fill"
                )
            )
        }

        // Recent apps cleared warning
        if preview.clearsRecentApps {
            warningsAccumulator.append(
                WarningRow(
                    id: "warning-clears-recents",
                    severity: .warning,
                    title: "Recent Apps Will Be Cleared",
                    detail: "A full rewrite resets the macOS Recent Applications section.",
                    systemImage: "clock.badge.exclamationmark"
                )
            )
        }

        self.warnings = warningsAccumulator
        self.canApply = preview.plan.issues.isEmpty && preview.emptiedSections.isEmpty

        // Skipped missing items
        self.skipped = preview.skipped.enumerated().map { i, skipped in
            let name = skipped.app.name.isEmpty ? skipped.app.bundleId : skipped.app.name
            let reasonText: String
            switch skipped.reason {
            case .appNotFound:
                reasonText = "App not found on system"
            }
            return SkippedItemRow(
                id: "skipped-\(i)",
                item: skipped,
                name: name,
                section: skipped.section,
                index: skipped.index,
                reason: reasonText,
                detail: skipped.app.path ?? (skipped.app.bundleId.isEmpty ? nil : skipped.app.bundleId),
                systemImage: "questionmark.app.fill"
            )
        }

        // Operations mapping
        var adds: [AdditionRow] = []
        var rems: [RemovalRow] = []
        var mvs: [MoveRow] = []

        // If it's a replaceAll operation, compute diff from current to target
        let isReplaceAll = preview.plan.operations.contains {
            if case .replaceAll = $0 { return true }
            return false
        }

        if isReplaceAll {
            // Diff current and target directly
            Self.diffStates(
                current: preview.current,
                target: preview.target,
                additions: &adds,
                removals: &rems,
                moves: &mvs
            )
        } else {
            // Sequential simulation of operations on current working state
            var workingApps = preview.current.apps
            var workingOthers = preview.current.others

            for (opIdx, op) in preview.plan.operations.enumerated() {
                switch op {
                case let .insert(item, section, index):
                    adds.append(
                        AdditionRow(
                            id: "add-\(opIdx)",
                            item: item,
                            name: item.displayName,
                            section: section,
                            index: index,
                            detail: item.detailDescription,
                            systemImage: item.symbolName
                        )
                    )
                    switch section {
                    case .apps:
                        let safeIdx = min(max(0, index), workingApps.count)
                        workingApps.insert(item, at: safeIdx)
                    case .others:
                        let safeIdx = min(max(0, index), workingOthers.count)
                        workingOthers.insert(item, at: safeIdx)
                    }

                case let .remove(section, index):
                    let removedItem: DockItem?
                    switch section {
                    case .apps:
                        if index >= 0 && index < workingApps.count {
                            removedItem = workingApps.remove(at: index)
                        } else {
                            removedItem = nil
                        }
                    case .others:
                        if index >= 0 && index < workingOthers.count {
                            removedItem = workingOthers.remove(at: index)
                        } else {
                            removedItem = nil
                        }
                    }

                    let itemName = removedItem?.displayName ?? "Item"
                    rems.append(
                        RemovalRow(
                            id: "rem-\(opIdx)",
                            item: removedItem,
                            name: itemName,
                            section: section,
                            index: index,
                            detail: removedItem?.detailDescription,
                            systemImage: removedItem?.symbolName ?? "minus.circle"
                        )
                    )

                case let .move(section, from, to):
                    let movedItem: DockItem?
                    switch section {
                    case .apps:
                        if from >= 0 && from < workingApps.count {
                            let item = workingApps.remove(at: from)
                            let safeTo = min(max(0, to), workingApps.count)
                            workingApps.insert(item, at: safeTo)
                            movedItem = item
                        } else {
                            movedItem = nil
                        }
                    case .others:
                        if from >= 0 && from < workingOthers.count {
                            let item = workingOthers.remove(at: from)
                            let safeTo = min(max(0, to), workingOthers.count)
                            workingOthers.insert(item, at: safeTo)
                            movedItem = item
                        } else {
                            movedItem = nil
                        }
                    }

                    let itemName = movedItem?.displayName ?? "Item"
                    mvs.append(
                        MoveRow(
                            id: "move-\(opIdx)",
                            item: movedItem,
                            name: itemName,
                            section: section,
                            fromIndex: from,
                            toIndex: to,
                            detail: "Position \(from + 1) → \(to + 1)",
                            systemImage: movedItem?.symbolName ?? "arrow.up.and.down"
                        )
                    )

                case .replaceAll:
                    break
                }
            }
        }

        self.additions = adds
        self.removals = rems
        self.moves = mvs

        self.prefs = (preview.prefsDiff?.entries ?? []).map { entry in
            PrefRow(
                id: "pref-\(entry.key.rawValue)",
                name: Self.title(of: entry.key),
                current: entry.current.map(Self.text(of:)) ?? "Default",
                target: Self.text(of: entry.target)
            )
        }
        let plan = preview.switchPlan
        self.apps = (plan?.willQuit ?? []).map {
            AppRow(id: "quit-\($0.processIdentifier)", name: $0.name, action: .quit)
        } + (plan?.willLaunch ?? []).map {
            AppRow(id: "open-\($0.bundleId)", name: $0.name, action: .open)
        }
    }

    private static func title(of key: DockPrefs.Key) -> String {
        switch key {
        case .tileSize: "Icon size"
        case .magnification: "Magnification"
        case .largeSize: "Magnified size"
        case .orientation: "Position on screen"
        case .autohide: "Automatically hide"
        case .autohideDelay: "Hide delay"
        case .autohideTimeModifier: "Hide animation time"
        case .showRecents: "Show recent apps"
        case .staticOnly: "Show only open apps"
        case .minimizeEffect: "Minimize effect"
        case .minimizeToApplication: "Minimize into app icon"
        case .showProcessIndicators: "Open-app indicators"
        case .launchAnimation: "Opening animation"
        case .scrollToOpen: "Scroll to open"
        }
    }

    private static func text(of value: DockPrefs.Value) -> String {
        switch value {
        case let .bool(flag): flag ? "On" : "Off"
        case let .double(number): number.formatted(.number.precision(.fractionLength(0...2)))
        case let .string(string): string.capitalized
        }
    }

    private static func diffStates(
        current: DockState,
        target: DockState,
        additions: inout [AdditionRow],
        removals: inout [RemovalRow],
        moves: inout [MoveRow]
    ) {
        diffSection(
            section: .apps,
            current: current.apps,
            target: target.apps,
            additions: &additions,
            removals: &removals,
            moves: &moves
        )
        diffSection(
            section: .others,
            current: current.others,
            target: target.others,
            additions: &additions,
            removals: &removals,
            moves: &moves
        )
    }

    private static func diffSection(
        section: DockSection,
        current: [DockItem],
        target: [DockItem],
        additions: inout [AdditionRow],
        removals: inout [RemovalRow],
        moves: inout [MoveRow]
    ) {
        // Items in target not in current -> additions
        for (idx, targetItem) in target.enumerated() {
            if let currentIdx = current.firstIndex(of: targetItem) {
                if currentIdx != idx {
                    moves.append(
                        MoveRow(
                            id: "move-\(section.rawValue)-\(idx)",
                            item: targetItem,
                            name: targetItem.displayName,
                            section: section,
                            fromIndex: currentIdx,
                            toIndex: idx,
                            detail: "Position \(currentIdx + 1) → \(idx + 1)",
                            systemImage: targetItem.symbolName
                        )
                    )
                }
            } else {
                additions.append(
                    AdditionRow(
                        id: "add-\(section.rawValue)-\(idx)",
                        item: targetItem,
                        name: targetItem.displayName,
                        section: section,
                        index: idx,
                        detail: targetItem.detailDescription,
                        systemImage: targetItem.symbolName
                    )
                )
            }
        }

        // Items in current not in target -> removals
        for (idx, currentItem) in current.enumerated() {
            if !target.contains(currentItem) {
                removals.append(
                    RemovalRow(
                        id: "rem-\(section.rawValue)-\(idx)",
                        item: currentItem,
                        name: currentItem.displayName,
                        section: section,
                        index: idx,
                        detail: currentItem.detailDescription,
                        systemImage: currentItem.symbolName
                    )
                )
            }
        }
    }
}

// MARK: - DockSection extension

extension DockSection {
    public var title: String {
        switch self {
        case .apps: "Apps"
        case .others: "Folders & Documents"
        }
    }
}

// MARK: - Presentation helpers on DockItem

extension DockItem {
    public var displayName: String {
        switch self {
        case let .app(ref):
            return ref.name.isEmpty ? ref.bundleId : ref.name
        case let .folder(f):
            if let label = f.label, !label.isEmpty { return label }
            return URL(fileURLWithPath: f.path).lastPathComponent
        case let .file(f):
            if let label = f.label, !label.isEmpty { return label }
            return URL(fileURLWithPath: f.path).lastPathComponent
        case let .url(u):
            if let label = u.label, !label.isEmpty { return label }
            return u.url.host ?? u.url.absoluteString
        case let .spacer(kind):
            switch kind {
            case .normal: return "Spacer"
            case .small: return "Small spacer"
            case .flex: return "Flexible spacer"
            }
        case let .unknown(raw):
            return "Tile (\(raw.tileType))"
        }
    }

    public var symbolName: String {
        switch self {
        case .app: return "app.fill"
        case .folder: return "folder.fill"
        case .file: return "doc.fill"
        case .url: return "globe"
        case .spacer: return "space"
        case .unknown: return "questionmark.square"
        }
    }

    public var detailDescription: String? {
        switch self {
        case let .app(ref):
            return ref.path ?? (ref.bundleId.isEmpty ? nil : ref.bundleId)
        case let .folder(f):
            return f.path
        case let .file(f):
            return f.path
        case let .url(u):
            return u.url.absoluteString
        case .spacer, .unknown:
            return nil
        }
    }
}
