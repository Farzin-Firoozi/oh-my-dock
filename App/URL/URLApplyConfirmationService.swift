import AppKit
import Foundation
import OhMyDockCore

/// Reuses the menu-bar confirmation model and floating presenter for URL-driven applies.
@MainActor
final class URLApplyConfirmationService: URLApplyConfirming, @unchecked Sendable {
    private let presenter: any ConfirmationPresenting
    private let timeout: Duration

    init(presenter: any ConfirmationPresenting, timeout: Duration = .seconds(120)) {
        self.presenter = presenter
        self.timeout = timeout
    }

    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult {
        guard ExternalConfirmationPolicy.requiresPrompt(source: .url, preview: preview)
            || preview.confirmationRequired
        else {
            return .accepted
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
            let model = SwitchConfirmationViewModel(confirmation: question) { result in
                guard !finished else { return }
                finished = true
                self.presenter.dismiss()
                continuation.resume(returning: result)
            }
            self.presenter.present(question, model: model)
            Task { [timeout] in
                try? await Task.sleep(for: timeout)
                guard !finished else { return }
                finished = true
                self.presenter.dismiss()
                continuation.resume(returning: .cancelled)
            }
        }
    }

    func confirmSave(name: String, overwriting: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            if overwriting {
                alert.messageText = "Replace profile “\(name)”?"
                alert.informativeText = "The current Dock layout will replace this profile's tiles. Hotkey, switching options, and stored preferences are kept."
            } else {
                alert.messageText = "Save the current Dock as “\(name)”?"
                alert.informativeText = "A new profile will be created from the Dock layout on screen."
            }
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let accepted = alert.runModal() == .alertFirstButtonReturn
            continuation.resume(returning: accepted)
        }
    }

    func confirmUndo() async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Restore the previous Dock?"
            alert.informativeText = "Apps that were quit are not reopened."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            let accepted = alert.runModal() == .alertFirstButtonReturn
            continuation.resume(returning: accepted)
        }
    }
}
