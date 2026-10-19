import Foundation

public enum DockutilScriptExportError: Error, Hashable, Sendable {
    /// A profile name or tile string contains a NUL byte. A shell script cannot carry one.
    case containsNUL(field: String)
    case invalidProfile(ProfileValidationError)
    /// dockutil adds an app by path. A bundle id alone is not enough for the script.
    case appMissingPath(DockSection, index: Int)
}

/// A profile rendered as a POSIX `sh` script that rebuilds the Dock on a clean account.
///
/// The result is text. `export` does not run the script, launch dockutil, or touch the Dock.
public enum DockutilScriptExporter {
    /// - Parameter homeDirectory: Paths strictly under this directory are written as `$HOME/...`.
    ///   Compared as text, with a trailing slash ignored. The script runs on another account,
    ///   so this does not resolve symlinks.
    public static func export(
        _ profile: Profile,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws(DockutilScriptExportError) -> String {
        try rejectNUL(in: profile)
        do {
            try profile.validate()
        } catch {
            throw .invalidProfile(error)
        }
        try rejectAppsWithoutPaths(in: profile)

        var lines = [
            "#!/bin/sh",
            "# oh-my-dock profile: \(shellQuote(commentText(profile.name)))",
            "# generator: oh-my-dock \(OhMyDockCore.version)",
            "set -eu",
            "if ! command -v dockutil >/dev/null 2>&1; then",
            "  printf '%s\\n' 'dockutil is required. Install it with: brew install dockutil' >&2",
            "  exit 1",
            "fi",
            render(["--remove", "all"], homeDirectory: homeDirectory),
        ]
        for section in DockSection.allCases {
            for (index, item) in profile.items(in: section).enumerated() {
                let command = DockutilPlanner.addCommand(item, section: section, position: index + 1)
                lines.append(render(command, homeDirectory: homeDirectory))
            }
        }
        if let prefs = profile.prefs {
            lines.append(contentsOf: defaultsLines(for: prefs))
        }
        lines.append("killall Dock")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Single-quotes `value` for POSIX `sh`. `'` becomes `'\''`, which is the only escape
    /// single quotes allow, so `$`, backticks, newlines, and quotes stay data.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Commands

    /// Renders one dockutil invocation. User-controlled text is single-quoted. A path under
    /// the home directory is `"$HOME"` joined to a single-quoted suffix: the suffix must not
    /// sit inside the double quotes, where `$()` and backticks would run.
    private static func render(_ arguments: [String], homeDirectory: String) -> String {
        var words = ["dockutil"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--label=") {
                let value = String(argument.dropFirst("--label=".count))
                words.append("--label=\(shellQuote(value))")
                index += 1
                continue
            }
            let nextIsValue = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
            if argument.hasPrefix("--"), nextIsValue {
                let value = arguments[index + 1]
                words.append(argument)
                let quoted = argument == "--add"
                    ? shellPath(value, homeDirectory: homeDirectory)
                    : shellQuote(value)
                words.append(quoted)
                index += 2
                continue
            }
            words.append(argument)
            index += 1
        }
        words.append("--no-restart")
        return words.joined(separator: " ")
    }

    /// `$HOME` when `path` is the home directory, `"$HOME"` plus a quoted suffix when it is
    /// under it, otherwise the path in single quotes. `/Users/mehack` is not under `/Users/me`.
    static func shellPath(_ path: String, homeDirectory: String) -> String {
        let home = normalizedHome(homeDirectory)
        guard !home.isEmpty, path.hasPrefix("/") else { return shellQuote(path) }
        if path == home { return "\"$HOME\"" }
        if home == "/" { return "\"$HOME\"" + shellQuote(path) }
        let prefix = home + "/"
        guard path.hasPrefix(prefix) else { return shellQuote(path) }
        return "\"$HOME\"" + shellQuote(String(path.dropFirst(home.count)))
    }

    private static func normalizedHome(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: - Dock preferences

    private static func defaultsLines(for prefs: DockPrefs) -> [String] {
        DockPrefs.Key.allCases.compactMap { key in
            if let value = prefs.values[key] { return defaultsLine(key: key, value: value) }
            // `defaults delete` fails on an absent key, which `set -e` would turn into an abort.
            if prefs.resetKeys.contains(key) {
                return "defaults delete com.apple.dock \(key.defaultsKey) 2>/dev/null || true"
            }
            return nil
        }
    }

    private static func defaultsLine(key: DockPrefs.Key, value: DockPrefs.Value) -> String {
        let flag: String
        let literal: String
        switch value {
        case .bool(let bool):
            flag = "-bool"
            literal = bool ? "true" : "false"
        case .double(let number):
            flag = "-float"
            literal = formatFloat(number)
        case .string(let text):
            flag = "-string"
            literal = text
        }
        return "defaults write com.apple.dock \(key.defaultsKey) \(flag) \(shellQuote(literal))"
    }

    /// `%.15g` in the POSIX locale: `48` stays `48`, `0.5` stays `0.5`, and the decimal
    /// mark is `.` regardless of the user's region.
    static func formatFloat(_ value: Double) -> String {
        String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
    }

    // MARK: - Refusal

    private static func rejectAppsWithoutPaths(in profile: Profile) throws(DockutilScriptExportError) {
        for section in DockSection.allCases {
            for (index, item) in profile.items(in: section).enumerated() {
                if case .app(let ref) = item, ref.path?.isEmpty ?? true {
                    throw .appMissingPath(section, index: index)
                }
            }
        }
    }

    private static func rejectNUL(in profile: Profile) throws(DockutilScriptExportError) {
        try rejectNUL(profile.name, field: "name")
        for section in DockSection.allCases {
            for (index, item) in profile.items(in: section).enumerated() {
                for (field, value) in strings(in: item) {
                    try rejectNUL(value, field: "\(section.rawValue)[\(index)].\(field)")
                }
            }
        }
    }

    private static func rejectNUL(_ value: String, field: String) throws(DockutilScriptExportError) {
        if value.contains("\0") { throw .containsNUL(field: field) }
    }

    private static func strings(in item: DockItem) -> [(field: String, value: String)] {
        switch item {
        case .app(let ref):
            var fields = [("bundleId", ref.bundleId), ("name", ref.name)]
            if let path = ref.path { fields.append(("path", path)) }
            if let brewCask = ref.brewCask { fields.append(("brewCask", brewCask)) }
            return fields
        case .url(let item):
            var fields = [("url", item.url.absoluteString)]
            if let label = item.label { fields.append(("label", label)) }
            return fields
        case .folder(let item):
            var fields = [("path", item.path)]
            if let label = item.label { fields.append(("label", label)) }
            return fields
        case .file(let item):
            var fields = [("path", item.path)]
            if let label = item.label { fields.append(("label", label)) }
            return fields
        case .spacer:
            return []
        case .unknown(let tile):
            var fields = [("tileType", tile.tileType)]
            if let label = tile.label { fields.append(("label", label)) }
            return fields
        }
    }

    /// Newlines are removed so a profile name cannot leave the header comment.
    /// U+2028/U+2029/U+0085 are stripped too: they are line breaks in Unicode and must
    /// not become a new shell line if a shell treats them as one.
    private static func commentText(_ name: String) -> String {
        var result = name
        for separator in ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}"] {
            result = result.replacingOccurrences(of: separator, with: "")
        }
        return result
    }
}
