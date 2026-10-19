import OhMyDockCore
import SwiftUI

@main
struct OhMyDockApp: App {
    @State private var model: MenuBarViewModel

    init() {
        let model = AppEnvironment.makeMenuBarViewModel()
        _model = State(initialValue: model)
        // The popover's content is not built until it is first opened; capture the first-launch
        // profile and load the profile list now.
        Task { await model.start() }
    }

    var body: some Scene {
        MenuBarExtra("oh-my-dock", systemImage: "dock.rectangle") {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Editor", id: "editor") { EditorWindow() }
        .defaultSize(width: 900, height: 600)

        Window("History", id: "history") { HistoryWindow() }
        .defaultSize(width: 700, height: 420)
    }
}
