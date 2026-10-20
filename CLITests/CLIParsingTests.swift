import ArgumentParser
import Foundation
import Testing

@Suite struct CLIParsingTests {
    // MARK: - Global Flags Extraction

    @Test func globalJSONFromArgv() {
        let (options, remaining) = try! GlobalFlagParser.extract(from: ["--json", "list"])
        #expect(options.json)
        #expect(remaining == ["list"])
    }

    @Test func globalJSONAfterSubcommandInArgv() {
        let (options, remaining) = try! GlobalFlagParser.extract(from: ["list", "--json", "--quiet", "--no-color", "--yes", "--non-interactive"])
        #expect(options.json)
        #expect(options.quiet)
        #expect(options.noColor)
        #expect(options.yes)
        #expect(options.nonInteractive)
        #expect(remaining == ["list"])
    }

    @Test func lockTimeoutParsing() throws {
        let (options1, rem1) = try GlobalFlagParser.extract(from: ["--lock-timeout", "15", "list"])
        #expect(options1.lockTimeout == 15)
        #expect(rem1 == ["list"])

        let (options2, rem2) = try GlobalFlagParser.extract(from: ["list", "--lock-timeout=42"])
        #expect(options2.lockTimeout == 42)
        #expect(rem2 == ["list"])

        // Negative timeout must throw CLIUsageError
        #expect(throws: CLIUsageError.self) {
            _ = try GlobalFlagParser.extract(from: ["--lock-timeout", "-5", "list"])
        }

        // Non-integer timeout must throw CLIUsageError
        #expect(throws: CLIUsageError.self) {
            _ = try GlobalFlagParser.extract(from: ["--lock-timeout", "abc", "list"])
        }
    }

    // MARK: - Subcommand Parsers

    @Test func applyQuitScopeParses() throws {
        let command = try Apply.parse(["Work", "--quit-scope", "none", "--dry-run", "--allow-quit", "--keep-running", "Safari", "--keep-running", "Slack"])
        #expect(command.profile == "Work")
        #expect(command.quitScope == Apply.QuitScopeOption.none)
        #expect(command.dryRun)
        #expect(command.allowQuit)
        #expect(command.keepRunning == ["Safari", "Slack"])
    }

    @Test func saveOptionsParse() throws {
        let command = try Save.parse(["Personal", "--force", "--include-prefs"])
        #expect(command.name == "Personal")
        #expect(command.force)
        #expect(command.includePrefs)
    }

    @Test func deleteParses() throws {
        let command = try Delete.parse(["OldProfile"])
        #expect(command.profile == "OldProfile")
    }

    @Test func renameParses() throws {
        let command = try Rename.parse(["Old", "New"])
        #expect(command.profile == "Old")
        #expect(command.newName == "New")
    }

    @Test func duplicateParses() throws {
        let command = try Duplicate.parse(["Source", "Copy"])
        #expect(command.profile == "Source")
        #expect(command.newName == "Copy")
    }

    @Test func restoreParses() throws {
        let uuid = UUID()
        let command = try Restore.parse([uuid.uuidString])
        #expect(command.id == uuid)
    }

    @Test func importStdinPathIsDash() throws {
        let command = try Import.parse(["-"])
        #expect(command.path == "-")

        let fileCommand = try Import.parse(["/path/to/profile.json"])
        #expect(fileCommand.path == "/path/to/profile.json")
    }

    @Test func exportFormatScript() throws {
        let command = try Export.parse(["Work", "--format", "script"])
        #expect(command.format == .script)

        let defaultCommand = try Export.parse(["Work"])
        #expect(defaultCommand.format == .json)
    }

    @Test func completionsShellParses() throws {
        let zsh = try Completions.parse(["zsh"])
        #expect(zsh.shell == .zsh)

        let bash = try Completions.parse(["bash"])
        #expect(bash.shell == .bash)

        let fish = try Completions.parse(["fish"])
        #expect(fish.shell == .fish)
    }

    // MARK: - CLIRunner Exit Codes & Error Handling

    @Test func runnerMissingSubcommandExitsTwo() async {
        let exitCode = await CLIRunner.run(["ohmydock"])
        #expect(exitCode == 2)
    }

    @Test func runnerUnknownSubcommandExitsTwo() async {
        let exitCode = await CLIRunner.run(["ohmydock", "invalid-subcommand"])
        #expect(exitCode == 2)
    }

    @Test func runnerUnknownOptionExitsTwo() async {
        let exitCode = await CLIRunner.run(["ohmydock", "list", "--unknown-flag"])
        #expect(exitCode == 2)
    }

    @Test func runnerCompletionsJSONExitsTwo() async {
        let exitCode = await CLIRunner.run(["ohmydock", "completions", "zsh", "--json"])
        #expect(exitCode == 2)
    }

    @Test func runnerVersionExitsZero() async {
        let exitCode = await CLIRunner.run(["ohmydock", "version"])
        #expect(exitCode == 0)
    }

    @Test func runnerHelpExitsZero() async {
        let exitCode = await CLIRunner.run(["ohmydock", "--help"])
        #expect(exitCode == 0)

        let listHelp = await CLIRunner.run(["ohmydock", "list", "--help"])
        #expect(listHelp == 0)
    }
}
