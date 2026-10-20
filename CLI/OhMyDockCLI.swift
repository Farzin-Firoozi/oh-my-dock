import ArgumentParser
import Foundation
import OhMyDockCore

struct OhMyDockCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ohmydock",
        abstract: "Control oh-my-dock from the command line.",
        discussion: """
        GLOBAL OPTIONS:
          --json                  Emit one JSON document on stdout.
          --quiet                 Minimal stdout on success.
          --no-color              Disable ANSI color on human output.
          --yes                   Assume defaults; never prompt.
          --non-interactive       Non-interactive mode (no prompts in v0.3).
          --lock-timeout <sec>    Lock acquire timeout in seconds (0 = try once).
        """,
        subcommands: [
            List.self,
            Show.self,
            Current.self,
            Apply.self,
            Save.self,
            Delete.self,
            Rename.self,
            Duplicate.self,
            Undo.self,
            Snapshots.self,
            History.self,
            Restore.self,
            Export.self,
            Import.self,
            Status.self,
            Doctor.self,
            Version.self,
            Completions.self,
        ],
        defaultSubcommand: nil
    )

    @Flag(name: .long, help: "Print version and exit.")
    var version: Bool = false

    mutating func run() async throws {
        if version {
            throw ExitCode(await CommandDispatch.run(.version))
        }
        throw CLIUsageError.message("Missing subcommand. Run `ohmydock --help` for usage.")
    }
}

// MARK: - Profiles

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List saved Dock profiles.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.list))
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a profile document.")

    @Argument(help: "Profile name or UUID.")
    var profile: String

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.show(profile: profile)))
    }
}

struct Current: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compare the live Dock to saved profiles.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.current))
    }
}

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply a profile to the Dock.")

    @Argument(help: "Profile name or UUID.")
    var profile: String

    @Flag(name: .long, help: "Preview without writing.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Allow quitting apps (requires --yes).")
    var allowQuit: Bool = false

    @Option(name: .long, help: "Override quit scope for this apply.")
    var quitScope: QuitScopeOption?

    @Option(name: .customLong("keep-running"), help: "Bundle ID to keep running (repeatable).")
    var keepRunning: [String] = []

    enum QuitScopeOption: String, ExpressibleByArgument {
        case previous, all, none

        var model: SwitchingOptions.QuitScope {
            switch self {
            case .previous: .previousProfileApps
            case .all: .allNotInProfile
            case .none: .none
            }
        }
    }

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(
            .apply(
                profile: profile,
                dryRun: dryRun,
                quitScope: quitScope?.model,
                keepRunning: keepRunning
            ),
            allowQuit: allowQuit
        ))
    }
}

struct Save: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save the current Dock as a profile.")

    @Argument(help: "Profile name.")
    var name: String

    @Flag(name: .long, help: "Replace an existing profile with the same name.")
    var force: Bool = false

    @Flag(name: .long, help: "Capture Dock preference keys onto the profile.")
    var includePrefs: Bool = false

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.save(name: name, force: force, includePrefs: includePrefs)))
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a saved profile.")

    @Argument(help: "Profile name or UUID.")
    var profile: String

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.delete(profile: profile)))
    }
}

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a profile.")

    @Argument(help: "Profile name or UUID.")
    var profile: String
    @Argument(help: "New name.")
    var newName: String

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.rename(profile: profile, newName: newName)))
    }
}

struct Duplicate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Duplicate a profile under a new name.")

    @Argument(help: "Profile name or UUID.")
    var profile: String
    @Argument(help: "New profile name.")
    var newName: String

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.duplicate(profile: profile, newName: newName)))
    }
}

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore the previous Dock snapshot.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.undo))
    }
}

// MARK: - Snapshots

struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List or manage Dock snapshots.",
        subcommands: [SnapshotsList.self, SnapshotsPin.self, SnapshotsUnpin.self, SnapshotsDelete.self, SnapshotsRestore.self],
        defaultSubcommand: SnapshotsList.self
    )
}

struct SnapshotsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List snapshots.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.snapshots))
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Alias for snapshots list.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.snapshots))
    }
}

struct SnapshotsPin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pin", abstract: "Pin a snapshot.")

    @Argument(help: "Snapshot UUID.")
    var id: UUID

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.snapshotsPin(id: id)))
    }
}

struct SnapshotsUnpin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unpin", abstract: "Unpin a snapshot.")

    @Argument(help: "Snapshot UUID.")
    var id: UUID

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.snapshotsUnpin(id: id)))
    }
}

struct SnapshotsDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a snapshot.")

    @Argument(help: "Snapshot UUID.")
    var id: UUID

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.snapshotsDelete(id: id)))
    }
}

struct SnapshotsRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore a snapshot.")

    @Argument(help: "Snapshot UUID.")
    var id: UUID

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.restore(id: id)))
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore a snapshot (requires --yes).")

    @Argument(help: "Snapshot UUID.")
    var id: UUID

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.restore(id: id)))
    }
}

// MARK: - Exchange

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a profile as JSON or a dockutil script.")

    @Argument(help: "Profile name or UUID.")
    var profile: String

    @Option(name: .long, help: "Output format.")
    var format: ExportFormatOption = .json

    @Option(name: .long, help: "Write to a file instead of stdout.")
    var output: String?

    @Flag(name: .long, help: "Overwrite an existing output file.")
    var force: Bool = false

    enum ExportFormatOption: String, ExpressibleByArgument {
        case json, script

        var model: ExportFormat {
            switch self {
            case .json: .json
            case .script: .script
            }
        }
    }

    mutating func run() async throws {
        let url = output.map { URL(fileURLWithPath: $0) }
        throw ExitCode(await CommandDispatch.run(
            .export(profile: profile, format: format.model, output: url, force: force)
        ))
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import a profile file (or - for stdin).")

    @Argument(help: "Path to a profile file, or - for stdin.")
    var path: String

    @Option(name: .long, help: "Use this name when the sanitized name is taken.")
    var name: String?

    mutating func run() async throws {
        let source: ImportSource
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-" {
            if isatty(fileno(stdin)) != 0 {
                throw CLIUsageError.message("Import from stdin requires a pipe or file redirection.")
            }
            source = .stdin
        } else if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            throw CLIUsageError.message("HTTP URLs are not supported.")
        } else {
            let fileURL: URL
            if trimmed.lowercased().hasPrefix("file://") {
                if let url = URL(string: trimmed) {
                    fileURL = url
                } else {
                    fileURL = URL(fileURLWithPath: trimmed)
                }
            } else {
                fileURL = URL(fileURLWithPath: trimmed)
            }
            source = .file(fileURL)
        }
        throw ExitCode(await CommandDispatch.run(.import(source: source, overrideName: name)))
    }
}

// MARK: - Meta

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report app, lock, and active profile status.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.status))
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run environment checks.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.doctor))
    }
}

struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print oh-my-dock version.")

    mutating func run() async throws {
        throw ExitCode(await CommandDispatch.run(.version))
    }
}

struct Completions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print shell completion scripts.")

    @Argument(help: "Shell name: zsh, bash, or fish.")
    var shell: ShellName

    enum ShellName: String, CaseIterable, ExpressibleByArgument {
        case zsh, bash, fish
    }

    mutating func run() async throws {
        if CLIGlobals.current.json {
            throw ExitCode(CLIOutput.emitUsage("completions does not support --json.", options: CLIGlobals.current))
        }
        let script = try await generateCompletionScript(for: shell)
        print(script, terminator: script.hasSuffix("\n") ? "" : "\n")
    }

    private func generateCompletionScript(for shell: ShellName) async throws -> String {
        let base: String
        switch shell {
        case .zsh:
            base = OhMyDockCLI.completionScript(for: .zsh)
        case .bash:
            base = OhMyDockCLI.completionScript(for: .bash)
        case .fish:
            base = OhMyDockCLI.completionScript(for: .fish)
        }
        let profiles = (try? await profileNamesForCompletion()) ?? []
        switch shell {
        case .zsh:
            return base + "\n" + zshProfileSuffix(profiles)
        case .bash:
            return base + "\n" + bashProfileSuffix(profiles)
        case .fish:
            return base + "\n" + fishProfileSuffix(profiles)
        }
    }

    private func profileNamesForCompletion() async throws -> [String] {
        let center = try CLIEnvironment.makeCenter()
        let result = await center.run(ExternalRequest(command: .list))
        return (result.envelope.result?.profiles ?? []).map(\.name)
    }

    private func zshProfileSuffix(_ names: [String]) -> String {
        let escaped = names.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        return """
        _ohmydock_profile_names() {
          local -a profiles
          profiles=(\(escaped))
          compadd -a profiles
        }
        """
    }

    private func bashProfileSuffix(_ names: [String]) -> String {
        let list = names.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        return """
        _ohmydock_profile_names() {
          local profiles=(\(list))
          COMPREPLY=( $(compgen -W "${profiles[*]}" -- "${cur}") )
        }
        """
    }

    private func fishProfileSuffix(_ names: [String]) -> String {
        let list = names.joined(separator: " ")
        return "complete -c ohmydock -n '__fish_use_subcommand' -a '\(list)' -d 'Profile'\n"
    }
}
