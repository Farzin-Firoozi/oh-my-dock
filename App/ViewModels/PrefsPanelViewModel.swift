import Foundation
import Observation
import OhMyDockCore

extension DockPrefs {
    /// DISPLAY ONLY: where a control sits when its key is untouched (`nil`). These are never
    /// written to the Dock or stored in a profile; “Reset to Defaults” removes keys instead.
    static let displayDefaults = DockPrefs(
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

    /// What the Dock holds: keys it stores keep their value, keys it doesn't store are reset to the
    /// system default (no value is invented for them).
    func resettingAbsentKeys() -> DockPrefs {
        var copy = self
        copy.resetKeys = Set(Key.allCases).subtracting(values.keys)
        return copy
    }

    /// Drops a key from `resetKeys` once it has a value again.
    func normalizingResets() -> DockPrefs {
        var copy = self
        copy.resetKeys.subtract(values.keys)
        return copy
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
        var seed = DockPrefs.allSystemDefaults
        do {
            seed = try previewer.captureCurrent().resettingAbsentKeys()
        } catch {
            message = Message(kind: .error, text: "Couldn't read the Dock, so every setting was left at the system default: \(Self.describe(error))")
        }
        commit(seed)
    }

    /// Applies `edit` to the preferences, clamps the result into the valid ranges and saves it.
    func update(_ edit: (inout DockPrefs) -> Void) {
        guard var next = prefs else { return }
        edit(&next)
        commit(next.clamped().normalizingResets())
    }

    func set<Value>(_ keyPath: WritableKeyPath<DockPrefs, Value?>, to value: Value) {
        update { $0[keyPath: keyPath] = value }
    }

    func captureFromDock() {
        guard canEdit, !isPreviewing else { return }
        do {
            // Keys the Dock doesn't store are at the system default, so they stay reset.
            commit(try previewer.captureCurrent().resettingAbsentKeys().clamped())
            message = Message(kind: .success, text: "Captured the current Dock preferences.")
        } catch {
            message = Message(kind: .error, text: "Couldn't read the Dock preferences: \(Self.describe(error))")
        }
    }

    /// Resets every key to the system default: applying the profile removes them from the Dock's
    /// domain and macOS uses its own values.
    func resetToDefaults() {
        guard canEdit else { return }
        commit(.allSystemDefaults)
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
                    setSession(nil)
                    previewedProfileName = nil
                }
                let began = try await previewer.begin(target)
                // Set before the gate is released, so a queued apply sees the preview.
                setSession(began)
                return began
            }
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
            setSession(nil)
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
        setSession(nil)
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

    /// The one place `session` changes, so the gate's shared preview flag never drifts from it.
    private func setSession(_ next: PrefsPreviewSession?) {
        session = next
        gate.isPreviewActive = next != nil
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
