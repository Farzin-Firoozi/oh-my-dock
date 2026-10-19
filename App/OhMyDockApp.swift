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

        Window("Editor", id: "editor") {
            EditorPlaceholderView()
        }
        .defaultSize(width: 720, height: 480)
    }
}
