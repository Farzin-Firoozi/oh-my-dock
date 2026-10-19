import AppKit
import OhMyDockCore
import SwiftUI

/// Shows a confirmation in a floating, non-modal alert panel, so a hotkey apply that needs the
/// user's say-so is visible even when the menu bar popover is closed.
///
/// Hosts the modern SwiftUI `SwitchConfirmationView` inside an `NSHostingView`.
/// Deliberately not `NSAlert.runModal()`: that blocks the main actor in a nested loop, so the
/// view model's timeout could never fire while the alert was up and the Dock gate would stay held.
/// The panel returns immediately; `dismiss()` can take it down at any time.
@MainActor
final class AlertConfirmationPresenter: ConfirmationPresenting {
    private var active: Presentation?

    func present(_ confirmation: MenuBarViewModel.Confirmation, answer: @escaping @MainActor (ApplyConfirmResult) -> Void) {
        dismiss()
        let presentation = Presentation(confirmation: confirmation) { [weak self] result, presentation in
            // Only the presentation still on screen may answer, and only once.
            guard let self, self.active === presentation else { return }
            self.active = nil
            presentation.close()
            answer(result)
        }
        active = presentation
        presentation.show()
    }

    func dismiss() {
        guard let presentation = active else { return }
        active = nil
        presentation.close()
    }

    @MainActor
    private final class Presentation: NSObject, NSWindowDelegate {
        private let panel: NSPanel
        private var onFinish: ((ApplyConfirmResult, Presentation) -> Void)?

        init(confirmation: MenuBarViewModel.Confirmation, onFinish: @escaping (ApplyConfirmResult, Presentation) -> Void) {
            self.onFinish = onFinish
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()

            let plan = confirmation.preview?.switchPlan ?? SwitchPlan(
                scope: .previousProfileApps,
                willQuit: confirmation.quitApps.map { RunningAppInfo(processIdentifier: 0, bundleId: $0, name: $0) },
                willLaunch: confirmation.launchApps.map { LaunchRequest(bundleId: $0, name: $0) }
            )

            let viewModel = SwitchConfirmationViewModel(
                plan: plan,
                profileName: confirmation.profileName,
                skippedApps: confirmation.skippedApps,
                clearsRecentApps: confirmation.clearsRecentApps,
                onConfirm: { [weak self] result in
                    self?.finish(result)
                }
            )

            let hostingView = NSHostingView(rootView: SwitchConfirmationView(model: viewModel, showsFooterButtons: true))
            panel.contentView = hostingView
            panel.title = "Oh My Dock"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.setContentSize(hostingView.fittingSize)
        }

        func show() {
            NSApp.activate(ignoringOtherApps: true)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }

        /// Takes the panel down without answering.
        func close() {
            onFinish = nil
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }

        /// The title-bar close button counts as Cancel.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            finish(.cancelled)
            return false
        }

        private func finish(_ result: ApplyConfirmResult) {
            guard let onFinish else { return }
            self.onFinish = nil
            onFinish(result, self)
        }
    }
}
