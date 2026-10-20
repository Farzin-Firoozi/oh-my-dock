import Foundation
import OhMyDockCore

enum CommandRunner {
    static func run(
        _ command: ExternalCommand,
        global: GlobalOptions,
        allowQuit: Bool = false
    ) async -> Int32 {
        let commandName = ExternalCommandName.canonical(command)
        if commandName == "completions", global.json {
            return CLIOutput.emitUsage("completions does not support --json.", options: global)
        }

        let center: ExternalCommandCenter
        do {
            center = try CLIEnvironment.makeCenter()
        } catch {
            return CLIOutput.emitUsage(String(describing: error), options: global)
        }

        let request = ExternalRequest(
            command: command,
            source: .cli,
            yes: global.yes,
            allowQuit: allowQuit,
            nonInteractive: global.nonInteractive || global.json || isatty(fileno(stdin)) == 0,
            lockTimeout: global.lockTimeout.map { $0 == 0 ? .zero : .seconds($0) }
        )
        let result = await center.run(request)
        return CLIOutput.emit(result, options: global, command: commandName)
    }
}
