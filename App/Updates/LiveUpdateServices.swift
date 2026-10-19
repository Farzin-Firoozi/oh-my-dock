import AppKit
import Foundation
import OhMyDockCore

struct WorkspaceReleasePageOpener: ReleasePageOpening {
    @MainActor func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum AppVersion {
    /// `CFBundleShortVersionString`, or "0.0.0" if missing (which only ever shows an update).
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
