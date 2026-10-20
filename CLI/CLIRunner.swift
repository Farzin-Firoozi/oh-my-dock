import ArgumentParser
import Foundation

enum CLIRunner {
    static func run(_ arguments: [String]) async -> Int32 {
        let rawArgs = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        let options: GlobalOptions
        let remaining: [String]

        do {
            (options, remaining) = try GlobalFlagParser.extract(from: rawArgs)
        } catch let error as CLIUsageError {
            var fallback = GlobalOptions()
            if rawArgs.contains("--json") { fallback.json = true }
            if rawArgs.contains("--quiet") { fallback.quiet = true }
            if rawArgs.contains("--no-color") { fallback.noColor = true }
            CLIGlobals.current = fallback
            return CLIOutput.emitUsage(error.localizedDescription, options: fallback)
        } catch {
            return CLIOutput.emitUsage(String(describing: error), options: GlobalOptions())
        }

        CLIGlobals.current = options

        do {
            var command = try OhMyDockCLI.parseAsRoot(remaining)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        } catch let error as CLIUsageError {
            return CLIOutput.emitUsage(error.localizedDescription, options: CLIGlobals.current)
        } catch {
            return handleParserError(error, options: CLIGlobals.current)
        }
    }

    private static func handleParserError(_ error: Error, options: GlobalOptions) -> Int32 {
        let exitCode = OhMyDockCLI.exitCode(for: error)
        if exitCode.rawValue == 0 {
            let message = OhMyDockCLI.message(for: error)
            if !message.isEmpty {
                FileHandle.standardOutput.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
            }
            return 0
        } else {
            let message = OhMyDockCLI.message(for: error)
            return CLIOutput.emitUsage(message, options: options)
        }
    }
}
