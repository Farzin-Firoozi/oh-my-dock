import AppKit
import OhMyDockCore
import SwiftUI

/// Shows what a hotkey apply has to say in floating, non-modal panels, so it is visible even when
/// the menu bar popover is closed: the confirmation question, a failure notice, and the outcome of
/// the app switch.
///
/// The question hosts the modern SwiftUI `SwitchConfirmationView`, bound to the same
/// `SwitchConfirmationViewModel` the popover card and diff sheet use. That model's `onConfirm`
/// answers the question (and ends up calling `dismiss()`), so this class holds no answer callback.
/// Deliberately not `NSAlert.runModal()`: that blocks the main actor in a nested loop, so the
/// view model's timeout could never fire while the alert was up and the Dock gate would stay held.
/// The panels return immediately; `dismiss()` can take them down at any time.
@MainActor
final class AlertConfirmationPresenter: ConfirmationPresenting {
    private var question: FloatingPanel?
    private var notice: FloatingPanel?
    private var outcome: FloatingPanel?

    func present(_ confirmation: MenuBarViewModel.Confirmation, model: SwitchConfirmationViewModel) {
        dismiss()
        // The title-bar close button counts as Cancel.
        question = FloatingPanel(
            rootView: SwitchConfirmationView(model: model, showsFooterButtons: true),
            onUserClose: { model.cancelAction() }
        )
        question?.show()
    }

    func dismiss() {
        question?.close()
        question = nil
    }

    func presentNotice(_ banner: MenuBarViewModel.Banner) {
        dismissNotice()
        notice = FloatingPanel(
            rootView: NoticeView(banner: banner) { [weak self] in self?.dismissNotice() },
            onUserClose: { [weak self] in self?.dismissNotice() }
        )
        notice?.show()
    }

    func presentOutcome(_ model: SwitchOutcomeViewModel) {
        dismissOutcome()
        outcome = FloatingPanel(
            rootView: SwitchOutcomeView(model: model),
            onUserClose: { model.dismiss() }
        )
        outcome?.show()
    }

    func dismissOutcome() {
        outcome?.close()
        outcome = nil
    }

    private func dismissNotice() {
        notice?.close()
        notice = nil
    }

    /// A titled, floating panel around a SwiftUI view. Closing it from the title bar asks
    /// `onUserClose` instead; `close()` takes it down without asking.
    @MainActor
    private final class FloatingPanel: NSObject, NSWindowDelegate {
        private let panel: NSPanel
        private let onUserClose: () -> Void

        init<Content: View>(rootView: Content, onUserClose: @escaping () -> Void) {
            self.onUserClose = onUserClose
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()

            let hostingView = NSHostingView(rootView: rootView)
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

        func close() {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            onUserClose()
            return false
        }
    }
}

/// Why a hotkey apply did not run or did not finish.
private struct NoticeView: View {
    let banner: MenuBarViewModel.Banner
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(banner.kind == .success ? Color.green : Color.red)
                    .accessibilityHidden(true)
                Text(banner.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
