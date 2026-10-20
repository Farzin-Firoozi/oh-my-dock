import Foundation
import OhMyDockCore

enum CommandDispatch {
    static func run(_ command: ExternalCommand, allowQuit: Bool = false) async -> Int32 {
        await CommandRunner.run(command, global: CLIGlobals.current, allowQuit: allowQuit)
    }
}
