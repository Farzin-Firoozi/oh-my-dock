import Foundation

@MainActor
final class MenuBarURLMessaging: URLUserMessaging {
    private weak var menuBar: MenuBarViewModel?

    init(menuBar: MenuBarViewModel) {
        self.menuBar = menuBar
    }

    func showExternalControlDeniedBanner() {
        menuBar?.showExternalControlDeniedBanner()
    }

    func beginNamingProfileForURL() {
        menuBar?.beginSavingCurrentDock()
    }
}
