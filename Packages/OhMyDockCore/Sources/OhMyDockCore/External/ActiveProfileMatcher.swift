import Foundation

public struct ActiveProfileMatch: Sendable, Equatable {
    public var primary: Profile?
    public var otherMatches: [Profile]

    public init(primary: Profile?, otherMatches: [Profile]) {
        self.primary = primary
        self.otherMatches = otherMatches
    }
}

public enum ActiveProfileMatcher {
    public static func match(
        profiles: [Profile],
        current: DockState,
        lastAppliedID: UUID?
    ) -> ActiveProfileMatch {
        let matching = profiles.filter { $0.dockState.matchesAfterWrite(current) }
        guard !matching.isEmpty else { return ActiveProfileMatch(primary: nil, otherMatches: []) }

        let primary: Profile?
        if let id = lastAppliedID, let applied = matching.first(where: { $0.id == id }) {
            primary = applied
        } else {
            primary = matching.reduce(nil) { best, candidate in
                guard let best else { return candidate }
                return exactTiles(candidate, current) > exactTiles(best, current) ? candidate : best
            }
        }

        guard let primary else { return ActiveProfileMatch(primary: nil, otherMatches: matching) }
        let others = matching.filter { $0.id != primary.id }
        return ActiveProfileMatch(primary: primary, otherMatches: others)
    }

    private static func exactTiles(_ profile: Profile, _ current: DockState) -> Int {
        DockSection.allCases.reduce(0) { total, section in
            total + zip(profile.dockState[section], current[section]).filter { $0 == $1 }.count
        }
    }
}
