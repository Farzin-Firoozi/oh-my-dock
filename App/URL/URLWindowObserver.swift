import SwiftUI

/// Bridges URL `open` commands into SwiftUI window actions.
struct URLWindowObserver: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .ohMyDockOpenWindow)) { notification in
                guard let window = notification.object as? OhMyDockURLParser.OpenWindow else { return }
                switch window {
                case .editor:
                    openWindow(id: "editor")
                case .history:
                    openWindow(id: "history")
                case .settings:
                    openSettings()
                }
            }
    }
}
