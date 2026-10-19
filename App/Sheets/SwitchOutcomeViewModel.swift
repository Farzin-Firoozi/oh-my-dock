import Foundation
import Observation
import OhMyDockCore

/// View model driving `SwitchOutcomeView`.
///
/// Summarizes the result of switching apps (quit count, refused/still running apps, launch failures)
/// and provides gated, explicitly confirmed force-quit actions for stragglers.
@MainActor
@Observable
public final class SwitchOutcomeViewModel: Identifiable {
    public struct StragglerItem: Identifiable, Equatable, Sendable {
        public let id: Int32
        public let app: RunningAppInfo
        public let statusDescription: String
        public let canForceQuit: Bool

        public init(app: RunningAppInfo, statusDescription: String, canForceQuit: Bool) {
            self.id = app.processIdentifier
            self.app = app
            self.statusDescription = statusDescription
            self.canForceQuit = canForceQuit
        }
    }

    public struct LaunchFailureItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let error: String

        public init(id: String, name: String, error: String) {
            self.id = id
            self.name = name
            self.error = error
        }
    }

    public let outcome: SwitchOutcome
    public let options: SwitchingOptions
    public let switcher: (any AppSwitching)?
    public let onDismiss: (() -> Void)?

    /// The app currently pending a second explicit user confirmation before force quitting.
    public var appPendingForceQuit: RunningAppInfo?
    public var isPerformingForceQuit: Bool = false
    public private(set) var forceQuitResults: [Int32: ForceQuitResult] = [:]

    public init(
        outcome: SwitchOutcome,
        options: SwitchingOptions = SwitchingOptions(),
        switcher: (any AppSwitching)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.outcome = outcome
        self.options = options
        self.switcher = switcher
        self.onDismiss = onDismiss
    }

    public var quitCount: Int {
        outcome.quitCount
    }

    public var summary: String {
        outcome.summary
    }

    public var canOfferForceQuit: Bool {
        options.offerForceQuit
    }

    public var stragglers: [StragglerItem] {
        outcome.quits.compactMap { q in
            guard q.status.isStraggler else { return nil }
            let desc: String
            switch q.status {
            case .refused:
                desc = "Refused to quit"
            case .stillRunningAfterTimeout:
                desc = "Still running after timeout"
            case .quitRequestedUnconfirmed:
                desc = "Quit unconfirmed"
            default:
                desc = "Still running"
            }
            return StragglerItem(
                app: q.app,
                statusDescription: desc,
                canForceQuit: canForceQuit(app: q.app)
            )
        }
    }

    public var launchFailures: [LaunchFailureItem] {
        outcome.launchFailures.enumerated().map { idx, failure in
            let errorMsg: String
            if case let .failed(msg) = failure.status {
                errorMsg = msg
            } else {
                errorMsg = "Launch failed"
            }
            return LaunchFailureItem(
                id: "failure-\(idx)-\(failure.request.bundleId)",
                name: failure.request.name,
                error: errorMsg
            )
        }
    }

    public func canForceQuit(app: RunningAppInfo) -> Bool {
        // Gating 1: Profile must have offerForceQuit enabled
        guard options.offerForceQuit else { return false }

        // Gating 2: App must be a straggler in this outcome
        guard outcome.stragglers.contains(where: { $0.processIdentifier == app.processIdentifier }) else {
            return false
        }

        // Gating 3: App must not already be terminated by a previous force-quit call
        if let result = forceQuitResults[app.processIdentifier] {
            return result != .terminated && result != .alreadyExited
        }

        return true
    }

    /// Step 1 of force-quit: User requests force quit, requiring a second explicit confirmation.
    public func promptForceQuit(for app: RunningAppInfo) {
        guard canForceQuit(app: app) else { return }
        appPendingForceQuit = app
    }

    public func cancelForceQuitPrompt() {
        appPendingForceQuit = nil
    }

    /// Step 2 of force-quit: User confirms second explicit prompt; calls the separate force-quit method.
    public func confirmForceQuit() async -> ForceQuitResult {
        guard let app = appPendingForceQuit else { return .notOffered }
        appPendingForceQuit = nil
        guard canForceQuit(app: app), let switcher else {
            return .notOffered
        }

        isPerformingForceQuit = true
        defer { isPerformingForceQuit = false }

        let result = await switcher.forceQuit(app, after: outcome, options: options)
        forceQuitResults[app.processIdentifier] = result
        return result
    }

    public func dismiss() {
        onDismiss?()
    }
}
