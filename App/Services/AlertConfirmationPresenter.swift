import AppKit

/// Shows a confirmation in a floating, non-modal alert panel, so a hotkey apply that needs the
/// user's say-so is visible even when the menu bar popover is closed.
///
/// Deliberately not `NSAlert.runModal()`: that blocks the main actor in a nested loop, so the
/// view model's timeout could never fire while the alert was up and the Dock gate would stay held.
/// The panel returns immediately; `dismiss()` can take it down at any time.
@MainActor
final class AlertConfirmationPresenter: ConfirmationPresenting {
    private var active: Presentation?

    func present(_ confirmation: MenuBarViewModel.Confirmation, answer: @escaping @MainActor (Bool) -> Void) {
        dismiss()
        let presentation = Presentation(confirmation: confirmation) { [weak self] accepted, presentation in
            // Only the presentation still on screen may answer, and only once.
            guard let self, self.active === presentation else { return }
            self.active = nil
            presentation.close()
            answer(accepted)
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
        private var onFinish: ((Bool, Presentation) -> Void)?

        init(confirmation: MenuBarViewModel.Confirmation, onFinish: @escaping (Bool, Presentation) -> Void) {
            self.onFinish = onFinish
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()

            let title = NSTextField(labelWithString: "Some apps are missing")
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
            var text = "“\(confirmation.profileName)” can still be applied without: "
                + confirmation.skippedApps.joined(separator: ", ") + "."
            if confirmation.clearsRecentApps { text += " This also clears the Dock's recent apps." }
            let body = NSTextField(wrappingLabelWithString: text)
            body.preferredMaxLayoutWidth = 380

            let apply = NSButton(title: "Apply Anyway", target: self, action: #selector(accept))
            apply.keyEquivalent = "\r"
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(decline))
            cancel.keyEquivalent = "\u{1b}"
            let buttons = NSStackView(views: [cancel, apply])
            buttons.orientation = .horizontal
            buttons.spacing = 12

            let stack = NSStackView(views: [title, body, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            stack.setCustomSpacing(18, after: body)

            panel.contentView = stack
            panel.title = "Oh My Dock"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.setContentSize(stack.fittingSize)
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

        @objc private func accept() { finish(true) }
        @objc private func decline() { finish(false) }

        /// The title-bar close button counts as Cancel.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            finish(false)
            return false
        }

        private func finish(_ accepted: Bool) {
            guard let onFinish else { return }
            self.onFinish = nil
            onFinish(accepted, self)
        }
    }
}
