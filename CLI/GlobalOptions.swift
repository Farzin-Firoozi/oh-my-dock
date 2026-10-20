import Foundation

struct GlobalOptions: Sendable, Equatable {
    var json: Bool = false
    var quiet: Bool = false
    var noColor: Bool = false
    var yes: Bool = false
    var nonInteractive: Bool = false
    var lockTimeout: Int?

    init(
        json: Bool = false,
        quiet: Bool = false,
        noColor: Bool = false,
        yes: Bool = false,
        nonInteractive: Bool = false,
        lockTimeout: Int? = nil
    ) {
        self.json = json
        self.quiet = quiet
        self.noColor = noColor
        self.yes = yes
        self.nonInteractive = nonInteractive
        self.lockTimeout = lockTimeout
    }

    var usesColor: Bool {
        if noColor { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fileno(stdout)) != 0
    }
}

enum CLIUsageError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        }
    }
}
