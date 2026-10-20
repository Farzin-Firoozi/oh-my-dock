import AppKit

@MainActor
final class URLConsentAlertPresenter: URLConsentPresenting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func requestExternalControlConsent() async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Allow other apps to control oh-my-dock?"
            alert.informativeText = "Web pages and other apps can ask oh-my-dock to apply a profile, save the Dock, or undo. They still cannot quit apps without the in-app confirmation sheet."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            alert.buttons.first?.keyEquivalent = "\r"
            let allowed = alert.runModal() == .alertFirstButtonReturn
            ExternalControlMode.write(allowed ? .allowed : .denied, to: defaults)
            continuation.resume(returning: allowed)
        }
    }
}
