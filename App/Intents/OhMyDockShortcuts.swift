import AppIntents

public struct OhMyDockShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor {
        .navy
    }

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyProfileIntent(),
            phrases: [
                "Apply \(\.$profile) Dock profile with \(.applicationName)",
                "Switch Dock to \(\.$profile) with \(.applicationName)"
            ],
            shortTitle: "Apply Profile",
            systemImageName: "dock.rectangle"
        )
        AppShortcut(
            intent: SaveCurrentDockIntent(),
            phrases: [
                "Save my Dock as a profile with \(.applicationName)"
            ],
            shortTitle: "Save Dock",
            systemImageName: "dock.rectangle"
        )
        AppShortcut(
            intent: UndoLastChangeIntent(),
            phrases: [
                "Undo my last Dock change with \(.applicationName)"
            ],
            shortTitle: "Undo Dock Change",
            systemImageName: "dock.rectangle"
        )
    }
}
