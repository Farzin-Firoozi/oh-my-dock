import AppKit

/// Reverts an active Dock preferences preview before the app quits (Cmd-Q or any other quit path).
/// All decisions live in `PreviewQuitCoordinator`; this only adapts them to AppKit's
/// `.terminateLater` / reply handshake.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once by `OhMyDockApp` before the first quit can happen.
    static var quitCoordinator: PreviewQuitCoordinator?
    /// Handles `ohmydock://` URLs once the menu bar has finished starting.
    static var urlRouter: OhMyDockURLRouter?

    private var pendingURLs: [URL] = []
    private var startupComplete = false

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        Task { await drainPendingURLs() }
    }

    /// Called after `MenuBarViewModel.start()` (including first-launch capture).
    func markStartupComplete() {
        startupComplete = true
        Task { await drainPendingURLs() }
    }

    private func drainPendingURLs() async {
        guard startupComplete, let router = Self.urlRouter else { return }
        let batch = pendingURLs
        pendingURLs.removeAll()
        for url in batch {
            await router.handle(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = Self.quitCoordinator, coordinator.hasActivePreview else { return .terminateNow }
        Task { @MainActor in
            let outcome = await coordinator.revertForQuit()
            sender.reply(toApplicationShouldTerminate: outcome.leavesDockRestored || Self.confirmQuitAnyway(outcome))
        }
        return .terminateLater
    }

    /// The preview is still on the Dock; let the user choose between quitting anyway and staying.
    private static func confirmQuitAnyway(_ outcome: PreviewQuitCoordinator.Outcome) -> Bool {
        let alert = NSAlert()
        alert.messageText = "The Dock preview couldn't be reverted"
        alert.informativeText = (outcome == .timedOut ? "Reverting took too long. " : "")
            + "Your Dock may still show previewed preferences. After quitting, restore “Before previewing Dock preferences” from History."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
