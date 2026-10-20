import AppIntents
import Foundation
import OhMyDockCore

public struct UndoLastChangeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Undo Last Change"
    public static let description = IntentDescription("Restores the Dock to the previous state.")
    public static let openAppWhenRun: Bool = false

    public static let confirmationPrompt = "Restore the previous Dock? Apps that were quit are not reopened."

    var dependencies: IntentDependencies?
    var confirmUndoAction: (@Sendable () async throws -> Void)?

    public init() {
        self.dependencies = nil
        self.confirmUndoAction = nil
    }

    init(
        dependencies: IntentDependencies? = nil,
        confirmUndoAction: (@Sendable () async throws -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.confirmUndoAction = confirmUndoAction
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let confirmUndoAction {
            try await confirmUndoAction()
        } else {
            let prompt = IntentDialog(stringLiteral: Self.confirmationPrompt)
            if #available(macOS 15.0, *) {
                try await requestConfirmation(dialog: prompt)
            } else {
                try await requestConfirmation(result: .result(dialog: prompt))
            }
        }

        let deps = dependencies ?? IntentDependencies.resolve()
        do {
            try deps.gate.requireNoPreview()
        } catch {
            throw IntentError.previewActive(DockOperationGate.previewActiveMessage)
        }

        let request = ExternalRequest(command: .undo, source: .intent)
        let result = await deps.gate.run("Intent undo") {
            await deps.commandCenter.run(request)
        }

        if result.ok {
            return .result(dialog: IntentDialog(stringLiteral: result.message))
        }

        if result.envelope.error?.code == "nothingToUndo" {
            throw IntentError.nothingToUndo
        }
        if result.envelope.error?.reason == "previewActive" {
            throw IntentError.previewActive(DockOperationGate.previewActiveMessage)
        }
        if result.envelope.error?.reason == "operationLock" {
            throw IntentError.locked(result.message)
        }
        throw IntentError.failure(code: result.envelope.error?.code ?? "failure", message: result.message)
    }
}
