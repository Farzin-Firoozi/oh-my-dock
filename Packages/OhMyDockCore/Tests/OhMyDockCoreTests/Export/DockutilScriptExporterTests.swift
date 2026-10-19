import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockutilScriptExporterTests {
    private let home = "/Users/me"

    private func export(_ profile: Profile, homeDirectory: String? = nil) throws -> String {
        try DockutilScriptExporter.export(profile, homeDirectory: homeDirectory ?? home)
    }

    // MARK: - Golden script

    @Test func fullProfileMatchesGoldenScript() throws {
        let script = try export(Self.fullProfile)
        let url = try #require(
            Bundle.module.url(forResource: "full-profile.dockutil", withExtension: "sh", subdirectory: "Fixtures")
        )
        let golden = try String(contentsOf: url, encoding: .utf8)
        #expect(script == golden)
        #expect(golden.contains("oh-my-dock \(OhMyDockCore.version)"))
        try checkSyntax(script)
    }

    @Test func scriptShape() throws {
        let script = try export(Self.fullProfile)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        let lines = script.components(separatedBy: "\n")
        #expect(lines.contains("set -eu"))
        #expect(script.contains("brew install dockutil"))
        #expect(lines.contains("dockutil --remove 'all' --no-restart"))

        let dockutil = lines.filter { $0.hasPrefix("dockutil ") }
        #expect(dockutil.allSatisfy { $0.hasSuffix(" --no-restart") })
        #expect(dockutil.count == 1 + Self.fullProfile.apps.count + Self.fullProfile.others.count)
        #expect(lines.filter { $0 == "killall Dock" }.count == 1)
        #expect(script.hasSuffix("killall Dock\n"))

        #expect(script.contains("--section 'apps'"))
        #expect(script.contains("--section 'others'"))
        #expect(script.contains("--view 'grid' --display 'folder' --sort 'dateadded'"))
        #expect(script.contains("--type 'spacer'"))
        #expect(script.contains("--type 'small-spacer'"))
        #expect(script.contains("--type 'flex-spacer'"))
        #expect(script.contains("--label='oh-my-dock-spacer'"))
        #expect(!script.contains("allNotInProfile"))
        #expect(!script.contains("keyCode"))
        #expect(!script.contains(home))
    }

    @Test func omitsDefaultsWhenPrefsAreAbsent() throws {
        let script = try export(Profile(
            name: "Empty",
            apps: [.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))]
        ))
        #expect(!script.contains("defaults "))
        #expect(script.contains("dockutil --remove 'all' --no-restart"))
        #expect(script.hasSuffix("killall Dock\n"))
        try checkSyntax(script)
    }

    @Test func emptyPrefsWriteNoDefaultsLines() throws {
        let script = try export(Profile(
            name: "Empty",
            apps: [.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))],
            prefs: DockPrefs()
        ))
        #expect(!script.contains("defaults "))
    }

    @Test func resetKeysEmitTolerantDefaultsDelete() throws {
        let script = try export(Profile(
            name: "Reset",
            prefs: DockPrefs(autohide: true, resetKeys: [.tileSize, .minimizeEffect])
        ))
        let defaults = script.components(separatedBy: "\n").filter { $0.hasPrefix("defaults ") }
        #expect(defaults == [
            "defaults delete com.apple.dock tilesize 2>/dev/null || true",
            "defaults write com.apple.dock autohide -bool 'true'",
            "defaults delete com.apple.dock mineffect 2>/dev/null || true",
        ])
        try checkSyntax(script)
    }

    @Test func writesEveryDockPref() throws {
        let script = try export(Profile(
            name: "Prefs",
            prefs: DockPrefs(
                tileSize: 16,
                magnification: false,
                largeSize: 128,
                orientation: .right,
                autohide: true,
                autohideDelay: 0.25,
                autohideTimeModifier: 1.5,
                showRecents: false,
                staticOnly: true,
                minimizeEffect: .scale,
                minimizeToApplication: true,
                showProcessIndicators: false,
                launchAnimation: false,
                scrollToOpen: true
            )
        ))
        let defaults = script.components(separatedBy: "\n").filter { $0.hasPrefix("defaults ") }
        #expect(defaults == [
            "defaults write com.apple.dock tilesize -float '16'",
            "defaults write com.apple.dock magnification -bool 'false'",
            "defaults write com.apple.dock largesize -float '128'",
            "defaults write com.apple.dock orientation -string 'right'",
            "defaults write com.apple.dock autohide -bool 'true'",
            "defaults write com.apple.dock autohide-delay -float '0.25'",
            "defaults write com.apple.dock autohide-time-modifier -float '1.5'",
            "defaults write com.apple.dock show-recents -bool 'false'",
            "defaults write com.apple.dock static-only -bool 'true'",
            "defaults write com.apple.dock mineffect -string 'scale'",
            "defaults write com.apple.dock minimize-to-application -bool 'true'",
            "defaults write com.apple.dock show-process-indicators -bool 'false'",
            "defaults write com.apple.dock launchanim -bool 'false'",
            "defaults write com.apple.dock scroll-to-open -bool 'true'",
        ])
        try checkSyntax(script)
    }

    // MARK: - Home directory

    @Test func rewritesOnlyPathsUnderHome() throws {
        let script = try export(Profile(
            name: "Paths",
            apps: [
                .app(AppRef(bundleId: "com.example.Inside", name: "Inside", path: "/Users/me/Apps/Inside.app")),
                .app(AppRef(bundleId: "com.example.Sibling", name: "Sibling", path: "/Users/mehack/Sibling.app")),
                .app(AppRef(bundleId: "com.example.Home", name: "Home", path: "/Users/me")),
            ],
            others: [
                .folder(FolderItem(path: "/Users/me/Downloads")),
                .file(FileItem(path: "/Applications/Notes.txt")),
            ]
        ))
        #expect(script.contains("--add \"$HOME\"'/Apps/Inside.app'"))
        #expect(script.contains("--add \"$HOME\" --type 'file'"))
        #expect(script.contains("--add \"$HOME\"'/Downloads'"))
        #expect(script.contains("--add '/Users/mehack/Sibling.app'"))
        #expect(script.contains("--add '/Applications/Notes.txt'"))
        #expect(!script.contains("/Users/me/"))
        #expect(!script.contains("'/Users/me'"))
    }

    @Test func trailingSlashOnHomeDoesNotChangeSubstitution() throws {
        let profile = Profile(
            name: "Paths",
            others: [.folder(FolderItem(path: "/Users/me/Downloads"))]
        )
        let script = try export(profile, homeDirectory: "/Users/me/")
        #expect(script.contains("\"$HOME\"'/Downloads'"))
        #expect(!script.contains("/Users/me"))
    }

    // MARK: - Quoting and injection

    @Test func unquotedTextDropsSingleQuotedSpans() {
        #expect(unquotedText("'$(reboot)'") == "")
        #expect(unquotedText("'a'\\''$(reboot)'") == "")
        #expect(unquotedText("\"$HOME\"'/it'\\''s'") == "$HOME")
    }

    @Test func shellQuoteEscapesMetacharacters() {
        #expect(DockutilScriptExporter.shellQuote("") == "''")
        #expect(DockutilScriptExporter.shellQuote("a b") == "'a b'")
        #expect(DockutilScriptExporter.shellQuote("a'b'c") == "'a'\\''b'\\''c'")
        #expect(DockutilScriptExporter.shellQuote("$(reboot)") == "'$(reboot)'")
        #expect(DockutilScriptExporter.shellQuote("`reboot`") == "'`reboot`'")
        #expect(DockutilScriptExporter.shellQuote("a\nb") == "'a\nb'")
        #expect(DockutilScriptExporter.shellQuote("文档 🦀") == "'文档 🦀'")
        #expect(DockutilScriptExporter.shellQuote("-rf") == "'-rf'")
    }

    @Test(arguments: [
        "it's",
        "$(reboot)",
        "`reboot`",
        "a\nb",
        "文档 🦀",
        "-rf",
        "'; rm -rf /; echo '",
    ])
    func hostileTileValuesStayQuoted(payload: String) throws {
        let profile = Profile(
            name: "Name \(payload)",
            apps: [
                .app(AppRef(bundleId: "com.example.App", name: "App \(payload)", path: "/Applications/Safe.app")),
            ],
            others: [
                .folder(FolderItem(path: "/Users/me/\(payload)", view: .list, display: .stack, sort: .kind, label: payload)),
                .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "url \(payload)")),
                .file(FileItem(path: "/Users/me/file-\(payload).txt", label: "file \(payload)")),
            ]
        )
        let script = try export(profile)
        let outsideQuotes = unquotedText(script)

        #expect(script.contains(DockutilScriptExporter.shellQuote(payload)))
        #expect(script.contains("\"$HOME\"" + DockutilScriptExporter.shellQuote("/\(payload)")))
        #expect(script.contains("--label=\(DockutilScriptExporter.shellQuote(payload))"))
        #expect(!outsideQuotes.contains(payload))
        #expect(!outsideQuotes.contains("$("))
        #expect(!outsideQuotes.contains("`"))
        #expect(!outsideQuotes.contains("reboot"))
        #expect(!outsideQuotes.contains("rm "))
        // The only semicolon in the script skeleton is the `if` test's `2>&1; then`.
        let withoutIf = outsideQuotes.replacingOccurrences(of: "2>&1; then", with: "")
        #expect(!withoutIf.contains(";"))
        if payload.hasPrefix("-") {
            #expect(!script.contains("--label \(payload)"))
            #expect(!script.contains("--label '\(payload)'"))
        }
        try checkSyntax(script)
    }

    @Test func profileNameCannotBreakOutOfTheHeaderComment() throws {
        let name = "Work'\nkillall Finder\r\n# $(reboot) `id`\u{2028}next"
        let script = try export(Profile(
            name: name,
            apps: [.app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))]
        ))
        let comment = try #require(script.components(separatedBy: "\n").dropFirst().first)
        let stripped = "Work'killall Finder# $(reboot) `id`next"
        #expect(comment == "# oh-my-dock profile: \(DockutilScriptExporter.shellQuote(stripped))")
        let outsideQuotes = unquotedText(script)
        #expect(!outsideQuotes.contains("killall Finder"))
        #expect(!outsideQuotes.contains("$("))
        #expect(!outsideQuotes.contains("`"))
        #expect(script.components(separatedBy: "\n").filter { $0 == "killall Dock" }.count == 1)
        try checkSyntax(script)
    }

    @Test func newlineInAPathStaysInsideQuotes() throws {
        let script = try export(Profile(
            name: "Lines",
            others: [.file(FileItem(path: "/Users/me/a\nb.txt", label: "x\ny"))]
        ))
        #expect(script.contains("\"$HOME\"'/a\nb.txt'"))
        #expect(script.contains("--label='x\ny'"))
        #expect(!unquotedText(script).contains("a\nb"))
        try checkSyntax(script)
    }

    // MARK: - Refusal

    @Test func refusesNULInATileOrTheName() {
        #expect(throws: DockutilScriptExportError.containsNUL(field: "name")) {
            try export(Profile(name: "a\0b"))
        }
        #expect(throws: DockutilScriptExportError.containsNUL(field: "others[0].path")) {
            try export(Profile(name: "Ok", others: [.file(FileItem(path: "/Users/me/a\0b"))]))
        }
        #expect(throws: DockutilScriptExportError.containsNUL(field: "apps[0].brewCask")) {
            try export(Profile(
                name: "Ok",
                apps: [.app(AppRef(bundleId: "com.example.App", name: "App", path: "/Applications/App.app", brewCask: "a\0b"))]
            ))
        }
        #expect(throws: DockutilScriptExportError.containsNUL(field: "others[0].label")) {
            try export(Profile(
                name: "Ok",
                others: [.url(URLItem(url: URL(string: "https://example.com")!, label: "a\0b"))]
            ))
        }
    }

    @Test func refusesAnAppWithoutAPath() {
        #expect(throws: DockutilScriptExportError.appMissingPath(.apps, index: 1)) {
            try export(Profile(name: "P", apps: [
                .app(AppRef(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")),
                .app(AppRef(bundleId: "com.apple.mail", name: "Mail")),
            ]))
        }
    }

    @Test func refusesAnInvalidProfile() {
        #expect(throws: DockutilScriptExportError.invalidProfile(.emptyName)) {
            try export(Profile(name: " "))
        }
        #expect(throws: DockutilScriptExportError.invalidProfile(.unknownItem(.apps, index: 0, tileType: "recents-tile"))) {
            try export(Profile(name: "P", apps: [.unknown(UnknownTile(tileType: "recents-tile"))]))
        }
        #expect(throws: DockutilScriptExportError.invalidProfile(.pathNotAbsolute(.others, index: 0, path: "Downloads"))) {
            try export(Profile(name: "P", others: [.folder(FolderItem(path: "Downloads"))]))
        }
    }

    // MARK: - Syntax check

    /// `sh -n` reads the script and checks syntax. It does not execute it.
    /// The script is passed on stdin; it is never written out and run.
    private func checkSyntax(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "sh -n failed: \(stderr)")
    }
}

extension DockutilScriptExporterTests {
    fileprivate static let fullProfile = Profile(
        id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
        name: "Work",
        apps: [
            .app(AppRef(
                bundleId: "com.figma.Desktop",
                name: "Figma",
                path: "/Applications/Figma.app",
                brewCask: "figma",
                launchOnSwitch: true
            )),
            .spacer(.normal),
            .spacer(.small),
            .app(AppRef(
                bundleId: "com.apple.Safari",
                name: "Safari",
                path: "/Users/me/Applications/Safari.app"
            )),
        ],
        others: [
            .folder(FolderItem(
                path: "/Users/me/Downloads",
                view: .grid,
                display: .folder,
                sort: .dateAdded,
                label: "Downloads"
            )),
            .url(URLItem(url: URL(string: "https://example.com/docs")!, label: "Docs")),
            .file(FileItem(path: "/Users/me/notes.txt", label: "Notes")),
            .spacer(.flex),
        ],
        prefs: DockPrefs(tileSize: 48, magnification: true, largeSize: 96, orientation: .left, autohideDelay: 0.5),
        switching: SwitchingOptions(quitScope: .allNotInProfile, launchHidden: true, offerForceQuit: true),
        hotkey: Hotkey(keyCode: 18, modifiers: [.command, .option])
    )
}

/// Characters the shell would see outside single quotes.
///
/// `'a'\''b'` is the POSIX encoding of `a'b`: a quoted `a`, a backslash-escaped quote,
/// then a quoted `b`. The escaped quote is data, not a quote that reopens a string one
/// character early.
private func unquotedText(_ script: String) -> String {
    var result = ""
    var index = script.startIndex
    while index < script.endIndex {
        let character = script[index]
        if character == "'" {
            index = script.index(after: index)
            while index < script.endIndex, script[index] != "'" {
                index = script.index(after: index)
            }
            if index < script.endIndex { index = script.index(after: index) }
            continue
        }
        if character == "\\", script.index(after: index) < script.endIndex {
            index = script.index(script.index(after: index), offsetBy: 1)
            continue
        }
        if character == "\"" {
            index = script.index(after: index)
            while index < script.endIndex, script[index] != "\"" {
                if script[index] == "\\", script.index(after: index) < script.endIndex {
                    index = script.index(after: index)
                }
                result.append(script[index])
                index = script.index(after: index)
            }
            if index < script.endIndex { index = script.index(after: index) }
            continue
        }
        result.append(character)
        index = script.index(after: index)
    }
    return result
}
