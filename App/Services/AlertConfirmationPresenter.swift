import AppKit
import OhMyDockCore
import SwiftUI

/// Shows a confirmation in a floating, non-modal alert panel, so a hotkey apply that needs the
/// user's say-so is visible even when the menu bar popover is closed.
///
/// Hosts the modern SwiftUI `SwitchConfirmationView` inside an `NSHostingView`, bound to the same
/// `SwitchConfirmationViewModel` the popover card and diff sheet use. The model's `onConfirm`
/// answers the question (and ends up calling `dismiss()`), so this class holds no answer callback.
/// Deliberately not `NSAlert.runModal()`: that blocks the main actor in a nested loop, so the
/// view model's timeout could never fire while the alert was up and the Dock gate would stay held.
/// The panel returns immediately; `dismiss()` can take it down at any time.
@MainActor
final class AlertConfirmationPresenter: ConfirmationPresenting {
    private var active: Presentation?

    func present(_ confirmation: MenuBarViewModel.Confirmation, model: SwitchConfirmationViewModel) {
        dismiss()
        let presentation = Presentation(model: model)
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
        private let model: SwitchConfirmationViewModel

        init(model: SwitchConfirmationViewModel) {
            self.model = model
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()

            let hostingView = NSHostingView(rootView: SwitchConfirmationView(model: model, showsFooterButtons: true))
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
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }

        /// The title-bar close button counts as Cancel.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            model.cancelAction()
            return false
        }
    }
}
