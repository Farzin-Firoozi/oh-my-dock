import OhMyDockCore
import SwiftUI

@main
struct OhMyDockApp: App {
    @State private var shell: AppEnvironment.Shell

    init() {
        let shell = AppEnvironment.makeShell()
        _shell = State(initialValue: shell)
        // The popover's content is not built until it is first opened; capture the first-launch
        // profile and load the profile list now.
        Task {
            await shell.menuBar.start()
            await shell.settings.load()
        }
    }

    var body: some Scene {
        MenuBarExtra("oh-my-dock", systemImage: "dock.rectangle") {
            MenuBarContentView(model: shell.menuBar)
                .onChange(of: shell.menuBar.profiles) { _, profiles in
                    shell.hotkeys.sync(profiles: profiles)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: shell.settings)
        }

        Window("Editor", id: "editor") { EditorWindow() }
        .defaultSize(width: 900, height: 600)

        Window("History", id: "history") { HistoryWindow() }
        .defaultSize(width: 700, height: 420)
    }
}
