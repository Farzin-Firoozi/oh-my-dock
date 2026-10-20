import AppKit
import Foundation

extension Notification.Name {
    static let ohMyDockOpenWindow = Notification.Name("ohMyDockOpenWindow")
}

@MainActor
final class LiveURLOpener: URLOpening {
    func openEditor() {
        NotificationCenter.default.post(name: .ohMyDockOpenWindow, object: OhMyDockURLParser.OpenWindow.editor)
    }

    func openHistory() {
        NotificationCenter.default.post(name: .ohMyDockOpenWindow, object: OhMyDockURLParser.OpenWindow.history)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .ohMyDockOpenWindow, object: OhMyDockURLParser.OpenWindow.settings)
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
