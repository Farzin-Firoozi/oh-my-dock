import AppKit
import SwiftUI

/// Lets a SwiftUI window veto its own close (for example to offer reverting a Dock preview) by
/// putting a delegate in front of SwiftUI's own, which keeps receiving everything else.
struct WindowCloseGuard: NSViewRepresentable {
    /// Called when the window is about to close. Return true to let it; false to hold it (the
    /// caller closes the window itself once it is ready).
    let shouldClose: @MainActor (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
    }

    @MainActor
    final class GuardView: NSView {
        var shouldClose: (@MainActor (NSWindow) -> Bool)?
        private var proxy: CloseProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, proxy == nil else { return }
            let proxy = CloseProxy(original: window.delegate) { [weak self] window in
                self?.shouldClose?(window) ?? true
            }
            self.proxy = proxy
            window.delegate = proxy
        }
    }

    @MainActor
    final class CloseProxy: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private let original: (any NSWindowDelegate)?
        private let decide: @MainActor (NSWindow) -> Bool

        init(original: (any NSWindowDelegate)?, decide: @escaping @MainActor (NSWindow) -> Bool) {
            self.original = original
            self.decide = decide
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
               original.windowShouldClose?(sender) == false {
                return false
            }
            return decide(sender)
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original as? NSObject)?.responds(to: selector) == true
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }
    }
}
