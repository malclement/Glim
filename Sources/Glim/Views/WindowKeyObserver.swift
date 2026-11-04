import AppKit
import SwiftUI

extension View {
    /// Runs `action` each time the window holding this view becomes key.
    /// For a menu bar window that is each time it opens, which `onAppear`
    /// does not reliably report, because the window is reused.
    func onWindowBecomesKey(_ action: @escaping @MainActor () -> Void) -> some View {
        background(WindowKeyObserver(action: action))
    }
}

private struct WindowKeyObserver: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.action = action
    }

    final class ObserverView: NSView {
        var action: (@MainActor () -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.action?() }
            }
            if window.isKeyWindow { action?() }
        }
    }
}
