import AppKit
import AppIntents
import Foundation
import OhMyDockCore

public struct ProfileEntity: AppEntity, Identifiable, Sendable, Equatable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dock Profile"
    public static let defaultQuery = ProfileEntityQuery()

    public var id: String
    public var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(id: UUID, name: String) {
        self.id = id.uuidString
        self.name = name
    }

    public init(from profile: Profile) {
        self.id = profile.id.uuidString
        self.name = profile.name
    }
}

public struct ProfileEntityQuery: EntityStringQuery, Sendable {
    var dependencies: IntentDependencies?

    public init() {
        self.dependencies = nil
    }

    init(dependencies: IntentDependencies?) {
        self.dependencies = dependencies
    }

    @MainActor
    private func fetchProfiles() async -> [Profile] {
        let deps = dependencies ?? IntentDependencies.resolve()
        return await deps.fetchProfiles()
    }

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        let idSet = Set(identifiers.map { $0.uppercased() })
        let all = await fetchProfiles()
        return all
            .filter { idSet.contains($0.id.uuidString.uppercased()) }
            .map { ProfileEntity(from: $0) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [ProfileEntity] {
        let all = await fetchProfiles()
        let sorted = all.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        return sorted.map { ProfileEntity(from: $0) }
    }

    @MainActor
    public func entities(matching string: String) async throws -> [ProfileEntity] {
        let all = await fetchProfiles()
        let filtered = all.filter {
            $0.name.localizedCaseInsensitiveContains(string)
        }
        return filtered.map { ProfileEntity(from: $0) }
    }
}
