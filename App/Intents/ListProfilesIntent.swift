import AppIntents
import Foundation
import OhMyDockCore

public struct ListProfilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Profiles"
    public static let description = IntentDescription("Lists all saved Dock profiles.")
    public static let openAppWhenRun: Bool = false

    var dependencies: IntentDependencies?

    public init() {
        self.dependencies = nil
    }

    init(dependencies: IntentDependencies? = nil) {
        self.dependencies = dependencies
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ProfileEntity]> & ProvidesDialog {
        let deps = dependencies ?? IntentDependencies.resolve()
        let request = ExternalRequest(command: .list, source: .intent)
        let result = await deps.commandCenter.run(request)

        if result.ok {
            let entries = result.envelope.result?.profiles ?? []
            let entities = entries.map { ProfileEntity(id: $0.id, name: $0.name) }
            let dialog = IntentDialog(stringLiteral: "Listed \(entities.count) profile(s).")
            return .result(value: entities, dialog: dialog)
        }

        throw IntentError.failure(code: result.envelope.error?.code ?? "failure", message: result.message)
    }
}
