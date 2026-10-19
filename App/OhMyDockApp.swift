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
            await shell.updates.checkIfDue()
        }
    }

    var body: some Scene {
        MenuBarExtra("oh-my-dock", systemImage: "dock.rectangle") {
            MenuBarContentView(model: shell.menuBar, updates: shell.updates)
                .onChange(of: shell.menuBar.profiles) { _, profiles in
                    shell.hotkeys.sync(profiles: profiles)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: shell.settings, updates: shell.updates)
        }

        Window("Editor", id: "editor") { EditorWindow(store: shell.profiles, previewer: shell.prefsPreviewer, gate: shell.gate) }
        .defaultSize(width: 900, height: 600)

        Window("History", id: "history") { HistoryWindow(model: shell.history) }
        .defaultSize(width: 700, height: 420)
    }
}
