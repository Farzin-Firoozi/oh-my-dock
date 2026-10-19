import Foundation
import Observation
import OhMyDockCore

extension DockPrefs {
    /// What macOS uses for each key when none is set. “Reset to defaults” writes these.
    static let appleDefaults = DockPrefs(
        tileSize: 48,
        magnification: false,
        largeSize: 128,
        orientation: .bottom,
        autohide: false,
        autohideDelay: 0.5,
        autohideTimeModifier: 0.5,
        showRecents: true,
        staticOnly: false,
        minimizeEffect: .genie,
        minimizeToApplication: false,
        showProcessIndicators: true,
        launchAnimation: true,
        scrollToOpen: false
    )

    /// Every field set: those in `self` win, the rest come from `defaults`.
    func filled(with defaults: DockPrefs = .appleDefaults) -> DockPrefs {
        DockPrefs(
            tileSize: tileSize ?? defaults.tileSize,
            magnification: magnification ?? defaults.magnification,
            largeSize: largeSize ?? defaults.largeSize,
            orientation: orientation ?? defaults.orientation,
            autohide: autohide ?? defaults.autohide,
            autohideDelay: autohideDelay ?? defaults.autohideDelay,
            autohideTimeModifier: autohideTimeModifier ?? defaults.autohideTimeModifier,
            showRecents: showRecents ?? defaults.showRecents,
            staticOnly: staticOnly ?? defaults.staticOnly,
            minimizeEffect: minimizeEffect ?? defaults.minimizeEffect,
            minimizeToApplication: minimizeToApplication ?? defaults.minimizeToApplication,
            showProcessIndicators: showProcessIndicators ?? defaults.showProcessIndicators,
            launchAnimation: launchAnimation ?? defaults.launchAnimation,
            scrollToOpen: scrollToOpen ?? defaults.scrollToOpen
        )
    }

    /// Numeric fields pulled into their allowed ranges (non-finite values become the lower bound).
    func clamped() -> DockPrefs {
        func clamp(_ key: Key, _ value: Double?) -> Double? {
            guard let value, let range = key.allowedRange else { return value }
            guard value.isFinite else { return range.lowerBound }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        var copy = self
        copy.tileSize = clamp(.tileSize, tileSize)
        copy.largeSize = clamp(.largeSize, largeSize)
        copy.autohideDelay = clamp(.autohideDelay, autohideDelay)
        copy.autohideTimeModifier = clamp(.autohideTimeModifier, autohideTimeModifier)
        return copy
    }
}

/// State of the “Dock preferences” panel for the profile selected in the editor. Edits are
/// clamped, handed to `persist` (the editor's store write) and, on request, previewed on the Dock
/// through `DockOperationGate` with a revert path. Nothing here knows about views.
@MainActor
@Observable
final class PrefsPanelViewModel {
    struct Message: Equatable {
        enum Kind: Equatable { case info, success, error }
        var kind: Kind
        var text: String
    }

    /// The selected profile's preferences; nil means the profile leaves the Dock's untouched.
    private(set) var prefs: DockPrefs?
    private(set) var profileID: UUID?
    private(set) var session: PrefsPreviewSession?
    /// Name of the profile whose values are on the Dock now, for the banner.
    private(set) var previewedProfileName: String?
    /// True while a capture-free Dock operation (preview or revert) is queued or running.
    private(set) var isWorking = false
    private(set) var message: Message?

    @ObservationIgnored private let previewer: any DockPrefsPreviewing
    @ObservationIgnored private let persist: @MainActor (UUID, DockPrefs?) -> Bool
    let gate: DockOperationGate
    @ObservationIgnored private var profileName: String?

    /// `persist` writes the profile's preferences through the editor and returns false if it refused.
    init(
        previewer: any DockPrefsPreviewing,
        gate: DockOperationGate,
        persist: @escaping @MainActor (UUID, DockPrefs?) -> Bool
    ) {
        self.previewer = previewer
        self.gate = gate
        self.persist = persist
    }

    var isManaged: Bool { prefs != nil }
    var isPreviewing: Bool { session != nil }
    var canEdit: Bool { profileID != nil }
    /// Waiting on another Dock operation (or running ours): previews and reverts are disabled.
    var isBusy: Bool { isWorking || gate.isBusy }

    func dismissMessage() { message = nil }

    /// Follows the editor's selection. Does not touch an active preview: the Dock keeps showing it
    /// until the user reverts or keeps it.
    func bind(profileID: UUID?, name: String?, prefs: DockPrefs?) {
        self.profileID = profileID
        profileName = name
        self.prefs = prefs
    }

    // MARK: - Editing

    func setManaged(_ managed: Bool) {
        guard canEdit, managed != isManaged else { return }
        if !managed {
            commit(nil)
            return
        }
        var seed = DockPrefs.appleDefaults
        do {
            seed = try previewer.captureCurrent().filled()
        } catch {
            message = Message(kind: .error, text: "Couldn't read the Dock, so Apple's defaults were used: \(Self.describe(error))")
        }
        commit(seed)
    }

    /// Applies `edit` to the preferences, clamps the result into the valid ranges and saves it.
    func update(_ edit: (inout DockPrefs) -> Void) {
        guard var next = prefs else { return }
        edit(&next)
        commit(next.clamped())
    }

    func set<Value>(_ keyPath: WritableKeyPath<DockPrefs, Value?>, to value: Value) {
        update { $0[keyPath: keyPath] = value }
    }

    func captureFromDock() {
        guard canEdit, !isPreviewing else { return }
        do {
            // Keys the Dock doesn't store are at Apple's default, so fill them in.
            commit(try previewer.captureCurrent().filled().clamped())
            message = Message(kind: .success, text: "Captured the current Dock preferences.")
        } catch {
            message = Message(kind: .error, text: "Couldn't read the Dock preferences: \(Self.describe(error))")
        }
    }

    func resetToDefaults() {
        guard canEdit else { return }
        commit(.appleDefaults)
    }

    private func commit(_ next: DockPrefs?) {
        guard let profileID else { return }
        guard next != prefs else { return }
        if persist(profileID, next) {
            prefs = next
        } else {
            message = Message(kind: .error, text: "Couldn't save the Dock preferences.")
        }
    }

    // MARK: - Preview

    /// Puts this profile's preferences (and only those) on the Dock. Pressed again while a preview
    /// is active it takes the old one back first so the revert target stays the real pre-preview Dock.
    func preview() async {
        guard let target = prefs, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            let started = try await gate.run("Previewing Dock preferences") { () async throws -> PrefsPreviewSession? in
                if let old = session {
                    try await previewer.revert(old)
                    session = nil
                    previewedProfileName = nil
                }
                return try await previewer.begin(target)
            }
            session = started
            previewedProfileName = started == nil ? nil : profileName
            message = started == nil
                ? Message(kind: .info, text: "The Dock already uses these preferences.")
                : nil
        } catch {
            message = Message(kind: .error, text: Self.describe(error))
        }
    }

    /// Restores the values from before the preview. Keeps the preview open on failure so the user can retry.
    @discardableResult
    func revert() async -> Bool {
        guard let active = session else { return true }
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await gate.run("Reverting Dock preferences") { try await previewer.revert(active) }
            session = nil
            previewedProfileName = nil
            message = Message(kind: .success, text: "Dock preferences reverted.")
            return true
        } catch {
            message = Message(kind: .error, text: Self.describe(error))
            return false
        }
    }

    /// Leaves the previewed values on the Dock and ends the preview.
    func keepPreview() {
        session = nil
        previewedProfileName = nil
    }

    /// The editor is closing or the user is leaving the panel with a preview active: revert it
    /// (`revert == true`) or keep it. Returns false when the revert failed and the preview is still active.
    @discardableResult
    func resolvePreview(revert shouldRevert: Bool) async -> Bool {
        guard isPreviewing else { return true }
        if shouldRevert { return await revert() }
        keepPreview()
        return true
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
