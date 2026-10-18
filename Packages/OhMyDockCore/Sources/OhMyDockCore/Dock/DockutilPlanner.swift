import Foundation

/// Argument lists for a batch of operations, ready to hand to dockutil.
struct DockutilPlan: Equatable, Sendable {
    /// One dockutil invocation each, WITHOUT the trailing `--no-restart` and plist location.
    var commands: [[String]]
    /// True when addressing was ambiguous and the whole batch became one full rewrite.
    var isFullRewrite: Bool
}

/// Translates `DockOperation`s into dockutil 3.1.3 invocations. Pure: no I/O.
///
/// dockutil addresses tiles by label, bundle id, path or URL (first match across apps, recents,
/// others), never by index. So `remove` / `move` only translate when the tile's address matches
/// exactly one persistent tile; otherwise the whole batch becomes `--remove all` plus an
/// `--add` per tile. Every dockutil behaviour relied on here is cited from
/// `kcrawford/dockutil` tag 3.1.3 (`Sources/DockUtil/`).
enum DockutilPlanner {
    /// Label given to spacer `--add`s. Without `--label`, dockutil labels the (never stored)
    /// spacer with the last component of the working directory, which could collide with a real
    /// tile and make `Dock.add` refuse it (`Dock.swift:243-261`).
    static let spacerLabel = "oh-my-dock-spacer"

    static func plan(operations: [DockOperation], from before: DockState) throws -> DockutilPlan {
        let expected = try before.applying(operations)
        if let commands = try incrementalCommands(for: operations, from: before) {
            return DockutilPlan(commands: commands, isFullRewrite: false)
        }
        return DockutilPlan(commands: try rewriteCommands(for: expected), isFullRewrite: true)
    }

    // MARK: - Incremental

    /// Nil when the batch cannot be expressed as individual edits.
    private static func incrementalCommands(
        for operations: [DockOperation],
        from before: DockState
    ) throws -> [[String]]? {
        var simulation = Simulation(before)
        var commands: [[String]] = []

        for operation in operations {
            switch operation {
            case let .insert(item, section, index):
                try validate(item)
                guard !simulation.wouldReject(item, in: section) else { return nil }
                // `--position` is 1-based and inserts before the current occupant
                // (`Dock.swift:432-450`), so index N becomes position N + 1.
                commands.append(addCommand(item, section: section, position: index + 1))
                simulation.insert(item, in: section, at: index)

            case let .remove(section, index):
                guard let address = simulation.uniqueAddress(section: section, index: index) else {
                    return nil
                }
                // `=` form: a value starting with `-` is a "Missing value" error otherwise.
                commands.append(["--remove=\(address)"])
                simulation.remove(section: section, index: index)

            case let .move(section, from, to):
                guard let address = simulation.uniqueAddress(section: section, index: from) else {
                    return nil
                }
                if from != to {
                    // `moveItem` removes the tile, then inserts at position - 1 in the
                    // shortened list (`Dock.swift:399-450`): the same meaning as `to`.
                    commands.append(["--move=\(address)", "--position", String(to + 1)])
                    simulation.move(section: section, from: from, to: to)
                }

            case let .replaceAll(state):
                commands += try rewriteCommands(for: state)
                simulation = Simulation(state)
            }
        }
        return commands
    }

    // MARK: - Full rewrite

    /// `--remove all` then one `--add` per tile, apps section first.
    ///
    /// `--remove all` empties `persistent-apps`, `recent-apps` AND `persistent-others`
    /// (`Dock.swift:360-364`, `sections` is all three), and `save` writes all three keys back
    /// (`Dock.swift:97-104`). So a rewrite also clears the Dock's recent-apps list. That list is
    /// Dock-managed, not part of `DockState`, and the Dock refills it.
    static func rewriteCommands(for state: DockState) throws -> [[String]] {
        var simulation = Simulation(DockState())
        var commands: [[String]] = [["--remove", "all"]]

        for section in DockSection.allCases {
            for item in state[section] {
                try validate(item)
                guard !simulation.wouldReject(item, in: section) else {
                    throw DockBackendError.invalidOperation(
                        "dockutil cannot add \(describe(item)) to the \(section.rawValue) section: "
                            + "another tile there already has the label \"\(computedLabel(of: item))\""
                    )
                }
                commands.append(addCommand(item, section: section, position: nil))
                simulation.insert(item, in: section, at: simulation.count(in: section))
            }
        }
        return commands
    }

    // MARK: - Commands

    static func addCommand(_ item: DockItem, section: DockSection, position: Int?) -> [String] {
        let target: String
        let type: String
        var extras: [String] = []

        switch item {
        case let .app(ref):
            target = ref.path ?? ""
            type = "file"
        case let .file(file):
            target = file.path
            type = "file"
            extras += labelArguments(file.label)
        case let .folder(folder):
            target = folder.path
            type = "directory"
            extras += labelArguments(folder.label)
            extras += ["--view", folder.view.rawValue, "--display", folder.display.rawValue, "--sort", folder.sort.rawValue]
        case let .url(url):
            target = url.url.absoluteString
            type = "url"
            extras += labelArguments(url.label)
        case let .spacer(kind):
            target = ""
            type = kind.rawValue
            extras += labelArguments(spacerLabel)
        case .unknown:
            // `validate` rejects these before any command is built.
            target = ""
            type = "file"
        }

        // An explicit `--type` skips dockutil's guessing (directory on disk, "://" in the
        // argument), and an explicit `--section` skips its `.app` heuristic.
        var arguments = ["--add", target, "--type", type, "--section", section.rawValue]
        if let position {
            arguments += ["--position", String(position)]
        }
        return arguments + extras
    }

    private static func labelArguments(_ label: String?) -> [String] {
        // An empty label is not "no label": it would match every URL tile whose path is empty
        // (spike 0.5, `--find ""` bug).
        guard let label, !label.isEmpty else { return [] }
        return ["--label=\(label)"]
    }

    // MARK: - Validation

    /// Everything dockutil would mis-handle is refused up front, before the first command runs.
    static func validate(_ item: DockItem) throws {
        switch item {
        case let .app(ref):
            guard let path = ref.path, !path.isEmpty else {
                throw DockBackendError.invalidOperation(
                    "App \(ref.bundleId.isEmpty ? ref.name : ref.bundleId) has no path; dockutil adds apps by path"
                )
            }
            try requireAbsolute(path)
        case let .file(file):
            try requireAbsolute(file.path)
        case let .folder(folder):
            try requireAbsolute(folder.path)
        case let .url(url):
            // dockutil strips a leading `file://` and would store the rest as a bare path.
            guard url.url.scheme != nil, !url.url.isFileURL else {
                throw DockBackendError.invalidOperation(
                    "URL \(url.url.absoluteString) needs a non-file scheme"
                )
            }
        case .spacer:
            break
        case let .unknown(tile):
            throw DockBackendError.invalidOperation(
                "Unknown dock tile of type \"\(tile.tileType)\" cannot be written"
            )
        }
    }

    /// `~` expands relative to the plist path (`DockUtil.swift:399-402`), and relative paths
    /// resolve against the working directory, so only absolute paths are safe.
    private static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw DockBackendError.invalidOperation("Path is not absolute: \(path)")
        }
    }

    // MARK: - dockutil's view of the Dock

    /// The label `Dock.add` computes when none is given (`Dock.swift:243-253`).
    static func computedLabel(of item: DockItem) -> String {
        switch item {
        case let .app(ref):
            ref.path.map(lastComponent(deletingAppExtension:)) ?? ref.name
        case let .file(file):
            file.label.nonEmpty ?? lastComponent(of: file.path)
        case let .folder(folder):
            folder.label.nonEmpty ?? lastComponent(of: folder.path)
        case let .url(url):
            url.label.nonEmpty ?? url.url.absoluteString
        case .spacer:
            spacerLabel
        case let .unknown(tile):
            tile.label ?? ""
        }
    }

    /// Every string by which `index(within:item:)` (`Dock.swift:332-343`) could match the tile:
    /// label, bundle id, URL path and full URL. Deliberately a superset of what the plist
    /// holds (a resolved bundle id the plist lacks, the computed label), so it can only make
    /// the planner more cautious.
    static func matchKeys(of item: DockItem) -> Set<String> {
        var keys: Set<String> = []
        switch item {
        case let .app(ref):
            keys = [ref.name, ref.bundleId, ref.path ?? "", computedLabel(of: item)]
        case let .file(file):
            keys = [file.path, file.label ?? "", computedLabel(of: item)]
        case let .folder(folder):
            keys = [folder.path, folder.label ?? "", computedLabel(of: item)]
        case let .url(url):
            keys = [url.url.absoluteString, url.url.path, url.label ?? "", computedLabel(of: item)]
        case .spacer:
            break
        case let .unknown(tile):
            keys = [tile.label ?? ""]
        }
        keys.remove("")
        return keys
    }

    /// The string to pass to `--remove` / `--move` for `item`, or nil when it has none.
    /// Paths and URLs are preferred over labels: they are exact, and the tile's bundle id may
    /// have been resolved by us rather than stored in the plist.
    static func address(of item: DockItem) -> String? {
        switch item {
        case let .app(ref):
            ref.path.nonEmpty ?? ref.bundleId.nonEmpty ?? ref.name.nonEmpty
        case let .file(file):
            file.path.nonEmpty
        case let .folder(folder):
            folder.path.nonEmpty
        case let .url(url):
            url.url.absoluteString
        case .spacer:
            nil
        case let .unknown(tile):
            tile.label.nonEmpty
        }
    }

    static func describe(_ item: DockItem) -> String {
        switch item {
        case let .app(ref): "app \(ref.bundleId.isEmpty ? ref.name : ref.bundleId)"
        case let .file(file): "file \(file.path)"
        case let .folder(folder): "folder \(folder.path)"
        case let .url(url): "URL \(url.url.absoluteString)"
        case let .spacer(kind): "\(kind.rawValue)"
        case let .unknown(tile): "unknown tile \(tile.tileType)"
        }
    }

    private static func lastComponent(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func lastComponent(deletingAppExtension path: String) -> String {
        path.hasSuffix(".app") || path.hasSuffix(".app/")
            ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            : lastComponent(of: path)
    }

    // MARK: - Simulation

    /// Tracks the Dock as dockutil would see it while the batch's earlier commands have
    /// already run, so addresses are judged against the state each command meets.
    private struct Simulation {
        struct Tile {
            var item: DockItem
            var keys: Set<String>
        }

        private var tiles: [DockSection: [Tile]]

        init(_ state: DockState) {
            tiles = [:]
            for section in DockSection.allCases {
                tiles[section] = state[section].map { Tile(item: $0, keys: DockutilPlanner.matchKeys(of: $0)) }
            }
        }

        func count(in section: DockSection) -> Int {
            tiles[section]?.count ?? 0
        }

        /// `Dock.add` refuses a tile when the FIRST tile matching its label, searching apps then
        /// others, sits in the destination section (`Dock.swift:255-261`).
        func wouldReject(_ item: DockItem, in section: DockSection) -> Bool {
            let label = DockutilPlanner.computedLabel(of: item)
            for candidate in DockSection.allCases {
                if tiles[candidate, default: []].contains(where: { $0.keys.contains(label) }) {
                    return candidate == section
                }
            }
            return false
        }

        /// The address of the tile at `section[index]` when exactly one persistent tile in the
        /// whole Dock matches it; nil for spacers, unlabelled unknowns, and duplicates.
        func uniqueAddress(section: DockSection, index: Int) -> String? {
            guard let tile = tiles[section]?[index],
                  let address = DockutilPlanner.address(of: tile.item)
            else { return nil }
            let matches = DockSection.allCases.reduce(0) { total, candidate in
                total + tiles[candidate, default: []].filter { $0.keys.contains(address) }.count
            }
            return matches == 1 ? address : nil
        }

        mutating func insert(_ item: DockItem, in section: DockSection, at index: Int) {
            tiles[section, default: []].insert(
                Tile(item: item, keys: DockutilPlanner.matchKeys(of: item)),
                at: index
            )
        }

        mutating func remove(section: DockSection, index: Int) {
            tiles[section]?.remove(at: index)
        }

        mutating func move(section: DockSection, from: Int, to: Int) {
            guard let tile = tiles[section]?.remove(at: from) else { return }
            tiles[section]?.insert(tile, at: to)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
