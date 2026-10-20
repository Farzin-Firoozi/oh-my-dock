import Foundation
import OhMyDockCore

private final class URLApplyConfirmBridge: @unchecked Sendable {
    private weak var target: (any URLApplyConfirming)?

    init(_ target: any URLApplyConfirming) {
        self.target = target
    }

    func call(_ preview: ApplyPreview) async -> ApplyConfirmResult {
        await Task { @MainActor in
            guard let target else { return .cancelled }
            return await target.confirmApply(preview: preview)
        }.value
    }
}

@MainActor
final class OhMyDockURLRouter {
    private let commandCenter: any ExternalCommandRunning
    private let gate: DockOperationGate
    private let opener: any URLOpening
    private let consent: any URLConsentPresenting
    private let confirm: any URLApplyConfirming
    private let messaging: any URLUserMessaging
    private let profileNameExists: @Sendable (String) async -> Bool
    private var deduper = URLCommandDeduper()
    private let defaults: UserDefaults

    init(
        commandCenter: any ExternalCommandRunning,
        gate: DockOperationGate,
        opener: any URLOpening,
        consent: any URLConsentPresenting,
        confirm: any URLApplyConfirming,
        messaging: any URLUserMessaging,
        profileNameExists: @escaping @Sendable (String) async -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.commandCenter = commandCenter
        self.gate = gate
        self.opener = opener
        self.consent = consent
        self.confirm = confirm
        self.messaging = messaging
        self.profileNameExists = profileNameExists
        self.defaults = defaults
    }

    func handle(_ url: URL) async {
        switch OhMyDockURLParser.parse(url) {
        case let .failure(failure):
            let message = message(for: failure)
            if let base = failure.errorCallback,
               let built = CallbackURLBuilder.errorURL(base: base, errorCode: errorCode(for: failure), message: message) {
                opener.openURL(built)
            }
            return
        case let .success(parsed):
            await handle(parsed: parsed)
        }
    }

    private func handle(parsed: OhMyDockURLParser.Parsed) async {
        let host = commandHost(parsed.route)
        let isMutating = isMutatingRoute(parsed.route)

        switch deduper.begin(host: host, query: parsed.query, isMutating: isMutating) {
        case .duplicate:
            if let error = parsed.errorCallback,
               let built = CallbackURLBuilder.errorURL(base: error, errorCode: "duplicate", message: "Duplicate URL.") {
                opener.openURL(built)
            }
            return
        case .rateLimited:
            if let error = parsed.errorCallback,
               let built = CallbackURLBuilder.errorURL(base: error, errorCode: "rateLimited", message: "Too many URLs.") {
                opener.openURL(built)
            }
            return
        case .proceed:
            break
        }

        defer { deduper.finish(host: host, query: parsed.query) }

        switch parsed.route {
        case let .open(window):
            open(window: window)
            emitSuccess(parsed: parsed, status: "opened")
        case .importRemote:
            emitError(
                parsed: parsed,
                code: "notImplemented",
                message: "import from a remote URL is not implemented."
            )
        case .apply, .save, .undo:
            guard await allowMutatingURL(parsed: parsed) else { return }
            switch parsed.route {
            case let .apply(profile):
                await runApply(profile: profile, parsed: parsed)
            case let .save(name):
                await runSave(name: name, parsed: parsed)
            case .undo:
                await runUndo(parsed: parsed)
            default:
                break
            }
        }
    }

    private func allowMutatingURL(parsed: OhMyDockURLParser.Parsed) async -> Bool {
        switch ExternalControlMode.read(from: defaults) {
        case .denied:
            messaging.showExternalControlDeniedBanner()
            if let error = parsed.errorCallback,
               let built = CallbackURLBuilder.errorURL(
                   base: error,
                   errorCode: "externalControlDenied",
                   message: "External control is denied in Settings."
               ) {
                opener.openURL(built)
            }
            return false
        case .allowed:
            return true
        case .ask:
            let allowed = await consent.requestExternalControlConsent()
            return allowed
        }
    }

    private func runApply(profile: String, parsed: OhMyDockURLParser.Parsed) async {
        do {
            try gate.requireNoPreview()
        } catch {
            emitError(parsed: parsed, code: "locked", message: DockOperationGate.previewActiveMessage)
            return
        }

        let confirmBridge = URLApplyConfirmBridge(confirm)
        let request = ExternalRequest(
            command: .apply(profile: profile, dryRun: false, quitScope: nil, keepRunning: []),
            source: .url,
            confirm: { preview in await confirmBridge.call(preview) }
        )

        let result = await gate.run("URL apply") {
            await commandCenter.run(request)
        }
        if result.ok {
            finishSuccess(parsed: parsed, result: result)
        } else {
            finishFailure(parsed: parsed, result: result)
        }
    }

    private func runSave(name: String?, parsed: OhMyDockURLParser.Parsed) async {
        guard let name else {
            messaging.beginNamingProfileForURL()
            emitSuccess(parsed: parsed, status: "namingUI")
            return
        }

        do {
            try gate.requireNoPreview()
        } catch {
            emitError(parsed: parsed, code: "locked", message: DockOperationGate.previewActiveMessage)
            return
        }

        let overwriting = await profileNameExists(name)

        guard await confirm.confirmSave(name: name, overwriting: overwriting) else {
            emitSuccess(parsed: parsed, status: "cancelled")
            return
        }

        let request = ExternalRequest(
            command: .save(name: name, force: overwriting, includePrefs: false),
            source: .url
        )
        let result = await gate.run("URL save") {
            await commandCenter.run(request)
        }
        if result.ok {
            finishSuccess(parsed: parsed, result: result)
        } else {
            finishFailure(parsed: parsed, result: result)
        }
    }

    private func runUndo(parsed: OhMyDockURLParser.Parsed) async {
        do {
            try gate.requireNoPreview()
        } catch {
            emitError(parsed: parsed, code: "locked", message: DockOperationGate.previewActiveMessage)
            return
        }

        guard await confirm.confirmUndo() else {
            emitSuccess(parsed: parsed, status: "cancelled")
            return
        }

        let request = ExternalRequest(command: .undo, source: .url)
        let result = await gate.run("URL undo") {
            await commandCenter.run(request)
        }
        if result.ok {
            finishSuccess(parsed: parsed, result: result)
        } else {
            finishFailure(parsed: parsed, result: result)
        }
    }

    private func open(window: OhMyDockURLParser.OpenWindow) {
        switch window {
        case .editor: opener.openEditor()
        case .history: opener.openHistory()
        case .settings: opener.openSettings()
        }
    }

    private func finishSuccess(parsed: OhMyDockURLParser.Parsed, result: ExternalResult) {
        guard let base = parsed.successCallback,
              let url = CallbackURLBuilder.successURL(base: base, result: result) else { return }
        opener.openURL(url)
    }

    private func finishFailure(parsed: OhMyDockURLParser.Parsed, result: ExternalResult) {
        guard let base = parsed.errorCallback,
              let url = CallbackURLBuilder.errorURL(base: base, result: result) else { return }
        opener.openURL(url)
    }

    private func emitSuccess(parsed: OhMyDockURLParser.Parsed, status: String) {
        guard let base = parsed.successCallback,
              let url = CallbackURLBuilder.successURL(base: base, status: status) else { return }
        opener.openURL(url)
    }

    private func emitError(parsed: OhMyDockURLParser.Parsed, code: String, message: String) {
        guard let base = parsed.errorCallback,
              let url = CallbackURLBuilder.errorURL(base: base, errorCode: code, message: message) else { return }
        opener.openURL(url)
    }

    private func isMutatingRoute(_ route: OhMyDockURLParser.Route) -> Bool {
        switch route {
        case .apply, .save, .undo: true
        case .open, .importRemote: false
        }
    }

    private func commandHost(_ route: OhMyDockURLParser.Route) -> String {
        switch route {
        case .apply: "apply"
        case .save: "save"
        case .undo: "undo"
        case .open: "open"
        case .importRemote: "import"
        }
    }

    private func message(for failure: OhMyDockURLParser.ParseFailure) -> String {
        switch failure {
        case .invalidURL: "Invalid URL."
        case .wrongScheme: "Wrong URL scheme."
        case .forbiddenAuthorization: "URL cannot carry quit authorization."
        case .illegalCallback: "Illegal callback URL."
        case .unknownHost: "Unknown command."
        case let .usage(text, _): text
        }
    }

    private func errorCode(for failure: OhMyDockURLParser.ParseFailure) -> String {
        switch failure {
        case .forbiddenAuthorization: "forbiddenAuthorization"
        case .illegalCallback: "illegalCallback"
        case .unknownHost, .usage: "usage"
        case .invalidURL, .wrongScheme: "usage"
        }
    }
}
