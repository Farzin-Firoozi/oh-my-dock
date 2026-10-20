import Foundation
import OhMyDockCore

@MainActor
protocol ExternalCommandRunning {
    func run(_ request: ExternalRequest) async -> ExternalResult
}

extension ExternalCommandCenter: ExternalCommandRunning {}

@MainActor
protocol URLOpening: AnyObject {
    func openEditor()
    func openHistory()
    func openSettings()
    func openURL(_ url: URL)
}

@MainActor
protocol URLConsentPresenting: AnyObject {
    /// First-use external control consent. `true` means Allow (persist allowed).
    func requestExternalControlConsent() async -> Bool
}

@MainActor
protocol URLUserMessaging: AnyObject {
    func showExternalControlDeniedBanner()
    func beginNamingProfileForURL()
}

@MainActor
protocol URLApplyConfirming: AnyObject, Sendable {
    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult
    func confirmSave(name: String, overwriting: Bool) async -> Bool
    func confirmUndo() async -> Bool
}
