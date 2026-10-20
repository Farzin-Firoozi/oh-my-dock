import ArgumentParser
import Foundation

extension UUID: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        guard let value = UUID(uuidString: argument) else { return nil }
        self = value
    }
}
