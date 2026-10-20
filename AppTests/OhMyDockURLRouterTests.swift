import Foundation
import OhMyDockCore
import Testing

// MARK: - Fakes

@MainActor
private final class FakeCommandCenter: ExternalCommandRunning {
    private(set) var requests: [ExternalRequest] = []
    var results: [ExternalResult] = []
    private var defaultResult: ExternalResult

    init(defaultResult: ExternalResult) {
        self.defaultResult = defaultResult
    }

    func run(_ request: ExternalRequest) async -> ExternalResult {
        requests.append(request)
        if !results.isEmpty { return results.removeFirst() }
        return defaultResult
    }
}

@MainActor
private final class FakeURLOpener: URLOpening {
    private(set) var opened: [URL] = []
    private(set) var editor = false
    private(set) var history = false
    private(set) var settings = false

    func openEditor() { editor = true }
    func openHistory() { history = true }
    func openSettings() { settings = true }
    func openURL(_ url: URL) { opened.append(url) }
}

@MainActor
private final class FakeConsent: URLConsentPresenting {
    var allow = true
    var defaults: UserDefaults = .standard
    private(set) var asked = false

    func requestExternalControlConsent() async -> Bool {
        asked = true
        ExternalControlMode.write(allow ? .allowed : .denied, to: defaults)
        return allow
    }
}

@MainActor
private final class FakeURLConfirm: URLApplyConfirming, @unchecked Sendable {
    var applyAnswers: [ApplyConfirmResult] = [.accepted]
    var saveAnswers: [Bool] = [true]
    var undoAnswers: [Bool] = [true]
    private(set) var applyPreviews: [ApplyPreview] = []

    func confirmApply(preview: ApplyPreview) async -> ApplyConfirmResult {
        applyPreviews.append(preview)
        return applyAnswers.isEmpty ? .accepted : applyAnswers.removeFirst()
    }

    func confirmSave(name: String, overwriting: Bool) async -> Bool {
        saveAnswers.isEmpty ? true : saveAnswers.removeFirst()
    }

    func confirmUndo() async -> Bool {
        undoAnswers.isEmpty ? true : undoAnswers.removeFirst()
    }
}

@MainActor
private final class FakeURLMessaging: URLUserMessaging {
    private(set) var deniedBanner = false
    private(set) var naming = false

    func showExternalControlDeniedBanner() { deniedBanner = true }
    func beginNamingProfileForURL() { naming = true }
}

private func okApplyResult() -> ExternalResult {
    ExternalResult(
        exitCode: 0,
        message: "Applied.",
        envelope: ExternalEnvelope(command: "apply", ok: true)
    )
}

@MainActor
private func makeRouter(
    center: FakeCommandCenter,
    opener: FakeURLOpener,
    consent: FakeConsent = FakeConsent(),
    confirm: FakeURLConfirm = FakeURLConfirm(),
    messaging: FakeURLMessaging = FakeURLMessaging(),
    mode: ExternalControlMode = .allowed,
    nameExists: @escaping @Sendable (String) async -> Bool = { _ in false }
) -> OhMyDockURLRouter {
    let defaults = UserDefaults(suiteName: "ohmydock-url-tests-\(UUID().uuidString)")!
    ExternalControlMode.write(mode, to: defaults)
    return OhMyDockURLRouter(
        commandCenter: center,
        gate: DockOperationGate(),
        opener: opener,
        consent: consent,
        confirm: confirm,
        messaging: messaging,
        profileNameExists: nameExists,
        defaults: defaults
    )
}

// MARK: - Parser

@Suite struct OhMyDockURLParserTests {
    @Test func plusSignInProfileNameIsNotSpace() {
        let url = URL(string: "ohmydock://apply?profile=A%2BB")!
        guard case let .success(parsed) = OhMyDockURLParser.parse(url) else {
            Issue.record("expected success")
            return
        }
        if case let .apply(profile) = parsed.route {
            #expect(profile == "A+B")
        } else {
            Issue.record("expected apply")
        }
    }

    @Test func unicodeProfileName() {
        let url = URL(string: "ohmydock://apply?profile=%E2%98%83")!
        guard case let .success(parsed) = OhMyDockURLParser.parse(url) else {
            Issue.record("expected success")
            return
        }
        if case let .apply(profile) = parsed.route {
            #expect(profile == "☃")
        } else {
            Issue.record("expected apply")
        }
    }

    @Test func forbiddenQuitQueryRejectsURL() {
        let url = URL(string: "ohmydock://apply?profile=Work&allowQuit=1")!
        guard case .failure(.forbiddenAuthorization) = OhMyDockURLParser.parse(url) else {
            Issue.record("expected forbidden")
            return
        }
    }

    @Test func forbiddenQuitQueryIsCaseInsensitive() {
        for key in ["ALLOWQUIT", "allow-quit", "allow_quit", "Yes"] {
            let url = URL(string: "ohmydock://apply?profile=Work&\(key)=1")!
            guard case .failure(.forbiddenAuthorization) = OhMyDockURLParser.parse(url) else {
                Issue.record("expected forbidden for \(key)")
                return
            }
        }
    }

    @Test func httpsSuccessCallbackRejectsURL() {
        let url = URL(string: "ohmydock://apply?profile=Work&x-success=https://evil.test/cb")!
        guard case .failure(.illegalCallback) = OhMyDockURLParser.parse(url) else {
            Issue.record("expected illegal callback")
            return
        }
    }

    @Test func importWithoutFetch() {
        let url = URL(string: "ohmydock://import?url=https://example.com/p.json")!
        guard case let .success(parsed) = OhMyDockURLParser.parse(url) else {
            Issue.record("expected parse")
            return
        }
        if case let .importRemote(remote) = parsed.route {
            #expect(remote == "https://example.com/p.json")
        } else {
            Issue.record("expected import")
        }
    }
}

// MARK: - Router

@Suite struct OhMyDockURLRouterTests {
    @Test @MainActor func applyUsesURLSourceAndConfirm() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let opener = FakeURLOpener()
        let confirm = FakeURLConfirm()
        let router = makeRouter(center: center, opener: opener, confirm: confirm)
        let url = URL(string: "ohmydock://apply?profile=Work")!
        await router.handle(url)
        #expect(center.requests.count == 1)
        #expect(center.requests[0].source == .url)
        #expect(center.requests[0].confirm != nil)
    }

    @Test @MainActor func duplicateApplyWithinOneSecondDoesNotRunTwice() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let opener = FakeURLOpener()
        let router = makeRouter(center: center, opener: opener)
        let url = URL(string: "ohmydock://apply?profile=Work&x-error=myapp://err")!
        await router.handle(url)
        await router.handle(url)
        #expect(center.requests.count == 1)
        #expect(opener.opened.count == 1)
        #expect(opener.opened[0].absoluteString.contains("errorCode=duplicate"))
    }

    @Test @MainActor func deniedBlocksApplyButOpenStillWorks() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let opener = FakeURLOpener()
        let messaging = FakeURLMessaging()
        let router = makeRouter(center: center, opener: opener, messaging: messaging, mode: .denied)
        await router.handle(URL(string: "ohmydock://apply?profile=Work&x-error=myapp://err")!)
        #expect(center.requests.isEmpty)
        #expect(messaging.deniedBanner)
        #expect(opener.opened.contains { $0.absoluteString.contains("externalControlDenied") })

        await router.handle(URL(string: "ohmydock://open?window=settings")!)
        #expect(opener.settings)
    }

    @Test @MainActor func askConsentAllowPersistsAndRuns() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let opener = FakeURLOpener()
        let consent = FakeConsent()
        consent.allow = true
        let defaults = UserDefaults(suiteName: "ohmydock-url-tests-\(UUID().uuidString)")!
        ExternalControlMode.write(.ask, to: defaults)
        consent.defaults = defaults
        let router = OhMyDockURLRouter(
            commandCenter: center,
            gate: DockOperationGate(),
            opener: opener,
            consent: consent,
            confirm: FakeURLConfirm(),
            messaging: FakeURLMessaging(),
            profileNameExists: { _ in false },
            defaults: defaults
        )
        await router.handle(URL(string: "ohmydock://apply?profile=Work")!)
        #expect(consent.asked)
        #expect(ExternalControlMode.read(from: defaults) == .allowed)
        #expect(center.requests.count == 1)
    }

    @Test @MainActor func askConsentDenyDropsURL() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let consent = FakeConsent()
        consent.allow = false
        let defaults = UserDefaults(suiteName: "ohmydock-url-tests-\(UUID().uuidString)")!
        ExternalControlMode.write(.ask, to: defaults)
        consent.defaults = defaults
        let router = OhMyDockURLRouter(
            commandCenter: center,
            gate: DockOperationGate(),
            opener: FakeURLOpener(),
            consent: consent,
            confirm: FakeURLConfirm(),
            messaging: FakeURLMessaging(),
            profileNameExists: { _ in false },
            defaults: defaults
        )
        await router.handle(URL(string: "ohmydock://apply?profile=Work")!)
        #expect(center.requests.isEmpty)
        #expect(ExternalControlMode.read(from: defaults) == .denied)
    }

    @Test @MainActor func importReturnsNotImplemented() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let opener = FakeURLOpener()
        let router = makeRouter(center: center, opener: opener)
        await router.handle(URL(string: "ohmydock://import?url=https://x.test/p.json&x-error=myapp://err")!)
        #expect(center.requests.isEmpty)
        #expect(opener.opened.contains { $0.absoluteString.contains("errorCode=notImplemented") })
    }

    @Test @MainActor func saveWithoutNameOpensNamingUI() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let messaging = FakeURLMessaging()
        let router = makeRouter(center: center, opener: FakeURLOpener(), messaging: messaging)
        await router.handle(URL(string: "ohmydock://save")!)
        #expect(messaging.naming)
        #expect(center.requests.isEmpty)
    }

    @Test @MainActor func forbiddenQueryDoesNotCallCenter() async {
        let center = FakeCommandCenter(defaultResult: okApplyResult())
        let router = makeRouter(center: center, opener: FakeURLOpener())
        await router.handle(URL(string: "ohmydock://apply?profile=Work&yes=1")!)
        #expect(center.requests.isEmpty)
    }
}
