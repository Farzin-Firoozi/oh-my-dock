import OhMyDockCore
import SwiftUI

@main
struct OhMyDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var shell: AppEnvironment.Shell

    init() {
        let shell = AppEnvironment.makeShell()
        _shell = State(initialValue: shell)
        AppDelegate.quitCoordinator = shell.previewQuit
        AppDelegate.urlRouter = shell.urlRouter
        // The popover's content is not built until it is first opened; capture the first-launch
        // profile and load the profile list now.
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: shell.menuBar, updates: shell.updates)
                .background { URLWindowObserver() }
                .task {
                    await shell.menuBar.start()
                    appDelegate.markStartupComplete()
                    await shell.settings.load()
                    await shell.updates.checkIfDue()
                }
                .onChange(of: shell.menuBar.profiles) { _, profiles in
                    shell.hotkeys.sync(profiles: profiles)
                }
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("oh-my-dock")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: shell.settings, updates: shell.updates)
        }

        Window("Editor", id: "editor") { EditorWindow(store: shell.profiles, previewer: shell.prefsPreviewer, gate: shell.gate, quit: shell.previewQuit) }
        .defaultSize(width: 900, height: 600)

        Window("History", id: "history") { HistoryWindow(model: shell.history) }
        .defaultSize(width: 700, height: 420)
    }
}
