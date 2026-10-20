import AppKit
import Foundation
import OhMyDockCore
import SwiftUI
import Testing

private actor LayoutFakePreviewer: DockPrefsPreviewing {
    nonisolated func captureCurrent() throws -> DockPrefs { DockPrefs() }
    func begin(_ prefs: DockPrefs) async throws -> PrefsPreviewSession? { nil }
    func revert(_ session: PrefsPreviewSession) async throws {}
}

private actor LayoutFakeStore: EditorProfileStore {
    let profile: Profile
    init(profile: Profile) { self.profile = profile }
    func list() -> ProfileStore.ListResult { ProfileStore.ListResult(profiles: [profile], failures: []) }
    func save(_ profile: Profile) throws {}
    func update(id: UUID, _ transform: @Sendable (inout Profile) throws -> Void) throws -> Profile {
        var copy = profile
        try transform(&copy)
        return copy
    }
    func delete(id: UUID) throws {}
    func profileFileModificationDate(for id: UUID) async throws -> Date? { nil }
}

/// Drives AppKit layout the way a display cycle would; returns the worst single-cycle constraint pass count.
@MainActor
private func worstConstraintPassCount(on window: NSWindow, cycles: Int = 48) async -> Int {
    guard let root = window.contentView else { return 0 }
    var worst = 0
    for _ in 0..<cycles {
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        var passes = 0
        for _ in 0..<120 {
            root.layoutSubtreeIfNeeded()
            root.updateConstraintsForSubtreeIfNeeded()
            passes += 1
            if !root.needsUpdateConstraints && !root.needsLayout { break }
        }
        worst = max(worst, passes)
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(8))
    }
    return worst
}

@MainActor
private func hostEditor(plainStrip: Bool) async -> NSWindow {
    if plainStrip {
        UserDefaults.standard.set(true, forKey: MockupSettingsStore.plainStripKey)
    } else {
        UserDefaults.standard.removeObject(forKey: MockupSettingsStore.plainStripKey)
    }

    let app = NSApplication.shared
    if app.activationPolicy() == .prohibited {
        app.setActivationPolicy(.accessory)
    }

    let profile = Profile(name: "Layout")
    let view = EditorWindow(
        store: LayoutFakeStore(profile: profile),
        previewer: LayoutFakePreviewer(),
        gate: DockOperationGate(),
        profileStoreChanges: DockChangeSignal(),
        quit: PreviewQuitCoordinator()
    )
    let host = NSHostingController(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 960, height: 620),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = host
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(120))
    return window
}

@MainActor
@Suite struct EditorWindowLayoutTests {
    /// AppKit aborts once constraint passes exceed an internal limit; stay well below that.
    private static let maxAllowedConstraintPasses = 24

    @Test(arguments: [false, true])
    func editorSurvivesLayoutAtDefaultSize(plainStrip: Bool) async throws {
        let window = await hostEditor(plainStrip: plainStrip)
        defer {
            window.close()
            UserDefaults.standard.removeObject(forKey: MockupSettingsStore.plainStripKey)
        }
        let worst = await worstConstraintPassCount(on: window)
        #expect(worst <= Self.maxAllowedConstraintPasses, "constraint passes: \(worst)")
    }

    @Test(arguments: [false, true])
    func editorSurvivesLayoutAtWindowMinimum(plainStrip: Bool) async throws {
        let window = await hostEditor(plainStrip: plainStrip)
        defer {
            window.close()
            UserDefaults.standard.removeObject(forKey: MockupSettingsStore.plainStripKey)
        }
        window.layoutIfNeeded()
        let minSize = window.contentMinSize
        window.setContentSize(NSSize(width: max(minSize.width, 760), height: max(minSize.height, 440)))
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        let worst = await worstConstraintPassCount(on: window)
        #expect(worst <= Self.maxAllowedConstraintPasses)
    }
}
