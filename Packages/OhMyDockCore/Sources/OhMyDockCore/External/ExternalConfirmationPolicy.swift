import Foundation

/// Whether an external shell (URL vs App Intent) must show a confirmation sheet before applying.
public enum ExternalConfirmationPolicy {
    /// URL: sheet whenever the preview would write the Dock or launch an app, even when
    /// `confirmationRequired` is false. Intent: sheet only when `confirmationRequired` is true.
    public static func requiresPrompt(source: ControlSource, preview: ApplyPreview) -> Bool {
        switch source {
        case .url:
            return preview.hasDockChanges || !(preview.switchPlan?.willLaunch.isEmpty ?? true)
        case .intent:
            return preview.confirmationRequired
        case .menu, .hotkey, .cli:
            return preview.confirmationRequired
        }
    }
}
