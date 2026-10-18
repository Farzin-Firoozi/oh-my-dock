import Foundation

public enum DockRestartError: Error, Equatable, Sendable {
    case launchFailed(executablePath: String, message: String)
    case commandFailed(exitStatus: Int32, standardError: String)
}

/// Restarts the Dock so it picks up written preferences. Backends never restart it
/// themselves (`--no-restart`), so a batch of edits costs one restart.
public protocol DockRestarting: Sendable {
    func restart() async throws
}

/// Runs `/usr/bin/killall Dock`. Never construct this in tests.
public struct LiveDockRestarter: DockRestarting {
    public static let executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    public static let arguments = ["Dock"]

    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner = FoundationProcessRunner()) {
        self.processRunner = processRunner
    }

    public func restart() async throws {
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executableURL: Self.executableURL,
                arguments: Self.arguments
            )
        } catch {
            throw DockRestartError.launchFailed(
                executablePath: Self.executableURL.path,
                message: String(describing: error)
            )
        }
        guard result.terminationStatus == 0 else {
            throw DockRestartError.commandFailed(
                exitStatus: result.terminationStatus,
                standardError: result.standardError
            )
        }
    }
}

/// Restarts nothing. For `.file` targets and tests.
public struct NoopDockRestarter: DockRestarting {
    public init() {}

    public func restart() async throws {}
}
