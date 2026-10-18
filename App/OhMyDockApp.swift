import AppKit
import OhMyDockCore
import SwiftUI

@main
struct OhMyDockApp: App {
    private let dockutilFound = BundledTools.dockutilURL() != nil

    var body: some Scene {
        MenuBarExtra("oh-my-dock", systemImage: "dock.rectangle") {
            Button("No profiles yet") {}
                .disabled(true)
            Text(dockutilFound ? "dockutil: found" : "dockutil: not found")
            Divider()
            Button("Quit oh-my-dock") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
