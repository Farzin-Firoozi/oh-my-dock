import AppIntents
import Foundation
import OhMyDockCore

public struct SaveCurrentDockIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save Current Dock"
    public static let description = IntentDescription("Saves the current Dock layout as a profile.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Name")
    public var name: String

    @Parameter(title: "Overwrite Existing", default: false)
    public var overwrite: Bool

    var dependencies: IntentDependencies?

    public init() {
        self.name = ""
        self.overwrite = false
        self.dependencies = nil
    }

    init(name: String, overwrite: Bool = false, dependencies: IntentDependencies? = nil) {
        self.name = name
        self.overwrite = overwrite
        self.dependencies = dependencies
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = dependencies ?? IntentDependencies.resolve()
        do {
            try deps.gate.requireNoPreview()
        } catch {
            throw IntentError.previewActive(DockOperationGate.previewActiveMessage)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > Profile.maxNameLength {
            throw IntentError.failure(code: "usage", message: "Profile name must be 1–\(Profile.maxNameLength) characters.")
        }

        let exists = await deps.profileNameExists(trimmed)
        if overwrite && exists {
            let confirmed = await deps.confirm.confirmSave(name: trimmed, overwriting: true)
            guard confirmed else {
                return .result(dialog: "Cancelled.")
            }
        }

        let request = ExternalRequest(
            command: .save(name: trimmed, force: overwrite, includePrefs: false),
            source: .intent
        )
        let result = await deps.gate.run("Intent save") {
            await deps.commandCenter.run(request)
        }

        if result.ok {
            return .result(dialog: IntentDialog(stringLiteral: result.message))
        }

        if result.envelope.error?.reason == "previewActive" {
            throw IntentError.previewActive(DockOperationGate.previewActiveMessage)
        }
        if result.envelope.error?.reason == "operationLock" {
            throw IntentError.locked(result.message)
        }
        if result.envelope.error?.reason == "nameInUse" {
            throw IntentError.conflict(result.message)
        }
        throw IntentError.failure(code: result.envelope.error?.code ?? "failure", message: result.message)
    }
}
