import Foundation

let cliExitCode = await CLIRunner.run(Array(CommandLine.arguments))
exit(cliExitCode)
