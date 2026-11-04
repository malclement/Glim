import AppKit
import SwiftUI

extension View {
    /// Runs `action(true)` each time the window holding this view becomes
    /// key and `action(false)` when it stops being key. For a menu bar window
    /// that is each time it opens and closes, which `onAppear` does not
    /// reliably report, because the window is reused.
    func onWindowKeyChange(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        background(WindowKeyObserver(action: action))
    }
}

private struct WindowKeyObserver: NSViewRepresentable {
    let action: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.action = action
    }

    final class ObserverView: NSView {
        var action: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else { return }
            for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.action?(isKey) }
                })
            }
            if window.isKeyWindow { action?(true) }
        }
    }
}
