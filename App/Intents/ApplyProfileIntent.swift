import AppIntents
import Foundation
import OhMyDockCore

private final class IntentApplyConfirmBridge: @unchecked Sendable {
    private weak var target: (any IntentApplyConfirming)?

    init(_ target: any IntentApplyConfirming) {
        self.target = target
    }

    func call(_ preview: ApplyPreview) async -> ApplyConfirmResult {
        await Task { @MainActor in
            guard let target else { return .cancelled }
            return await target.confirmApply(preview: preview)
        }.value
    }
}

public struct ApplyProfileIntent: AppIntent {
    public static let title: LocalizedStringResource = "Apply Profile"
    public static let description = IntentDescription("Applies a saved Dock profile.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Profile")
    public var profile: ProfileEntity

    var dependencies: IntentDependencies?

    public init() {
        self.profile = ProfileEntity(id: "", name: "")
        self.dependencies = nil
    }

    init(profile: ProfileEntity, dependencies: IntentDependencies? = nil) {
        self.profile = profile
        self.dependencies = dependencies
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ProfileEntity> & ProvidesDialog {
        let deps = dependencies ?? IntentDependencies.resolve()
        do {
            try deps.gate.requireNoPreview()
        } catch {
            throw IntentError.previewActive(DockOperationGate.previewActiveMessage)
        }

        let confirmBridge = IntentApplyConfirmBridge(deps.confirm)
        let request = ExternalRequest(
            command: .apply(profile: profile.id, dryRun: false, quitScope: nil, keepRunning: []),
            source: .intent,
            confirm: { preview in await confirmBridge.call(preview) }
        )

        let result = await deps.gate.run("Intent apply") {
            await deps.commandCenter.run(request)
        }

        if result.ok {
            if result.envelope.result?.status == "cancelled" {
                return .result(value: profile, dialog: "Cancelled.")
            }
            return .result(value: profile, dialog: IntentDialog(stringLiteral: result.message))
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
