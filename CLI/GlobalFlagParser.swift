import Foundation

enum CLIGlobals {
    nonisolated(unsafe) static var current = GlobalOptions()
}

enum GlobalFlagParser {
    /// Extracts global flags from the arguments (excluding argv[0]),
    /// storing them in `GlobalOptions` and returning the remaining arguments for ArgumentParser.
    static func extract(from rawArgs: [String]) throws -> (options: GlobalOptions, remaining: [String]) {
        var options = GlobalOptions()
        var remaining: [String] = []
        var index = 0
        var stopParsingOptions = false

        while index < rawArgs.count {
            let arg = rawArgs[index]

            if stopParsingOptions {
                remaining.append(arg)
                index += 1
                continue
            }

            if arg == "--" {
                stopParsingOptions = true
                remaining.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--json":
                options.json = true
            case "--quiet":
                options.quiet = true
            case "--no-color":
                options.noColor = true
            case "--yes":
                options.yes = true
            case "--non-interactive":
                options.nonInteractive = true
            case "--lock-timeout":
                index += 1
                guard index < rawArgs.count else {
                    throw CLIUsageError.message("--lock-timeout requires a non-negative integer argument.")
                }
                guard let seconds = Int(rawArgs[index]), seconds >= 0 else {
                    throw CLIUsageError.message("Invalid value for --lock-timeout: '\(rawArgs[index])'. Expected a non-negative integer.")
                }
                options.lockTimeout = seconds
            default:
                if arg.hasPrefix("--lock-timeout=") {
                    let val = String(arg.dropFirst("--lock-timeout=".count))
                    guard let seconds = Int(val), seconds >= 0 else {
                        throw CLIUsageError.message("Invalid value for --lock-timeout: '\(val)'. Expected a non-negative integer.")
                    }
                    options.lockTimeout = seconds
                } else {
                    remaining.append(arg)
                }
            }
            index += 1
        }

        return (options, remaining)
    }

    /// Backward-compatible helper for tests or raw argv scanning
    static func parse(_ arguments: [String]) -> GlobalOptions {
        let args = arguments.count > 0 && !arguments[0].hasPrefix("-") ? Array(arguments.dropFirst()) : arguments
        return (try? extract(from: args).options) ?? GlobalOptions()
    }
}
