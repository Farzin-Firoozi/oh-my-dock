import Foundation

public struct ProfileMatch: Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum ProfileAddressResult: Sendable, Equatable {
    case found(Profile)
    case notFound
    case ambiguous([ProfileMatch])
}

public enum ProfileAddressing {
    public static func resolve(_ address: String, in profiles: [Profile]) -> ProfileAddressResult {
        if let uuid = UUID(uuidString: address) {
            if let profile = profiles.first(where: { $0.id == uuid }) {
                return .found(profile)
            }
            return .notFound
        }
        let matches = profiles.filter {
            $0.name.localizedCaseInsensitiveCompare(address) == .orderedSame
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default:
            let listed = matches
                .map { ProfileMatch(id: $0.id, name: $0.name) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            return .ambiguous(listed)
        }
    }
}
