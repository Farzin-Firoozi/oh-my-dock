import AppKit

/// Shows a confirmation as an app-modal `NSAlert`, so a hotkey apply that needs the user's say-so
/// is visible even when the menu bar popover is closed.
@MainActor
final class AlertConfirmationPresenter: ConfirmationPresenting {
    private var alert: NSAlert?

    func present(_ confirmation: MenuBarViewModel.Confirmation, answer: @escaping @MainActor (Bool) -> Void) {
        dismiss()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some apps are missing"
        var text = "“\(confirmation.profileName)” can still be applied without: "
            + confirmation.skippedApps.joined(separator: ", ") + "."
        if confirmation.clearsRecentApps { text += " This also clears the Dock's recent apps." }
        alert.informativeText = text
        alert.addButton(withTitle: "Apply Anyway")
        alert.addButton(withTitle: "Cancel")
        self.alert = alert

        // Start the modal loop after the caller has finished installing its continuation.
        Task { @MainActor [weak self] in
            guard let self, self.alert === alert else { return }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if self.alert === alert { self.alert = nil }
            answer(response == .alertFirstButtonReturn)
        }
    }

    func dismiss() {
        guard let alert else { return }
        self.alert = nil
        if NSApp.modalWindow === alert.window { NSApp.abortModal() }
    }
}
