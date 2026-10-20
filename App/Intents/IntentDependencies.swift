import AppKit
import Foundation
import OhMyDockCore

public enum IntentError: LocalizedError, CustomLocalizedStringResourceConvertible, CustomStringConvertible, Equatable, Sendable {
    case nothingToUndo
    case previewActive(String)
    case locked(String)
    case conflict(String)
    case failure(code: String, message: String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToUndo:
            return "There is nothing to undo."
        case let .previewActive(message):
            return LocalizedStringResource(stringLiteral: message)
        case let .locked(message):
            return LocalizedStringResource(stringLiteral: message)
        case let .conflict(message):
            return LocalizedStringResource(stringLiteral: message)
        case let .failure(_, message):
            return LocalizedStringResource(stringLiteral: message)
        }
    }

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .nothingToUndo:
            return "There is nothing to undo."
        case let .previewActive(message),
             let .locked(message),
             let .conflict(message),
             let .failure(_, message):
            return message
        }
    }
}

@MainActor
protocol IntentApplyConfirming: AnyObject, Sendable {
    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult
    func confirmSave(name: String, overwriting: Bool) async -> Bool
}

@MainActor
final class IntentApplyConfirmationService: IntentApplyConfirming, @unchecked Sendable {
    private weak var presenter: (any ConfirmationPresenting)?
    private let timeout: Duration

    init(presenter: (any ConfirmationPresenting)?, timeout: Duration = .seconds(120)) {
        self.presenter = presenter
        self.timeout = timeout
    }

    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult {
        guard ExternalConfirmationPolicy.requiresPrompt(source: .intent, preview: preview)
            || preview.confirmationRequired
        else {
            return .accepted
        }

        guard let presenter else {
            return .cancelled
        }

        return await withCheckedContinuation { continuation in
            let question = MenuBarViewModel.Confirmation(
                profileName: preview.profileName,
                skippedApps: preview.skipped.map { $0.app.name.isEmpty ? $0.app.bundleId : $0.app.name },
                clearsRecentApps: preview.clearsRecentApps,
                preview: preview,
                quitApps: preview.willQuitApps.map(\.name),
                launchApps: (preview.switchPlan?.willLaunch ?? []).map(\.name)
            )

            var finished = false
            let model = SwitchConfirmationViewModel(confirmation: question) { [weak presenter] result in
                guard !finished else { return }
                finished = true
                presenter?.dismiss()
                continuation.resume(returning: result)
            }

            presenter.present(question, model: model)

            Task { [weak presenter, timeout] in
                try? await Task.sleep(for: timeout)
                guard !finished else { return }
                finished = true
                presenter?.dismiss()
                continuation.resume(returning: .cancelled)
            }
        }
    }

    func confirmSave(name: String, overwriting: Bool) async -> Bool {
        guard overwriting else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace “\(name)”?"
        alert.informativeText = "A profile with this name already exists. Overwrite it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

public struct IntentDependencies: @unchecked Sendable {
    @MainActor public static var shared: IntentDependencies?

    @MainActor let commandCenter: any ExternalCommandRunning
    @MainActor let gate: DockOperationGate
    @MainActor let confirm: any IntentApplyConfirming
    @MainActor let profileNameExists: @Sendable (String) async -> Bool
    @MainActor let fetchProfiles: @Sendable () async -> [Profile]

    @MainActor
    init(
        commandCenter: any ExternalCommandRunning,
        gate: DockOperationGate,
        confirm: any IntentApplyConfirming,
        profileNameExists: @escaping @Sendable (String) async -> Bool,
        fetchProfiles: @escaping @Sendable () async -> [Profile]
    ) {
        self.commandCenter = commandCenter
        self.gate = gate
        self.confirm = confirm
        self.profileNameExists = profileNameExists
        self.fetchProfiles = fetchProfiles
    }

    @MainActor
    static func resolve() -> IntentDependencies {
        guard let shared else {
            fatalError("IntentDependencies.shared has not been configured")
        }
        return shared
    }
}
