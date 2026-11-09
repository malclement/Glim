import AppKit
import GlimCore
import SwiftUI

/// Owns Glim's main window. There is at most one: it is made the first time
/// it is shown, and kept when it closes, so it comes back where it was and
/// on the monitor that was selected.
///
/// AppKit owns the window, not a SwiftUI `Window` scene, because Glim opens
/// it from the app delegate: when Glim is opened again while it runs, and at
/// launch unless macOS started it at login. A scene can only be opened from
/// inside a view, and on macOS 14 its launch and restoration behaviour can't
/// be turned off (`defaultLaunchBehavior` and `restorationBehavior` are
/// macOS 15).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// Tall enough for every row of the HP's detail, diagnostics included.
    static let defaultContentSize = NSSize(width: 760, height: 740)

    private let manager: MonitorManager
    /// nil in tests that don't need scenes or display names.
    let store: GlimStore?
    private let frameAutosaveName: String?
    private let present: @MainActor (NSWindow) -> Void
    private let onOpenChange: @MainActor (Bool) -> Void
    private(set) var window: NSWindow?
    /// From ``show()`` until the window closes. A minimised window is open.
    private(set) var isOpen = false

    /// - Parameters:
    ///   - frameAutosaveName: The defaults name the window's frame is kept
    ///     under, or nil not to keep it.
    ///   - present: Brings the window forward; tests replace it so that no
    ///     window appears on screen.
    ///   - onOpenChange: Told when the window opens and closes.
    init(manager: MonitorManager,
         store: GlimStore? = nil,
         frameAutosaveName: String? = nil,
         present: @escaping @MainActor (NSWindow) -> Void = MainWindowController.bringForward,
         onOpenChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.manager = manager
        self.store = store
        self.frameAutosaveName = frameAutosaveName
        self.present = present
        self.onOpenChange = onOpenChange
    }

    /// Shows the window, active and in front, making it the first time.
    func show() {
        let window = prepareWindow()
        if !isOpen {
            isOpen = true
            AppLog.app.info("window opened")
            // First, so that Glim is a regular app, in the Dock and with its
            // menus, by the time it activates.
            onOpenChange(true)
        }
        present(window)
    }

    /// What ``show()`` does to the window, outside tests.
    static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The window, made if needed, without showing it.
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let controller = NSHostingController(rootView: MainWindowView(manager: manager).environment(\.glimStore, store))
        // SwiftUI's toolbar items go into the window's toolbar.
        controller.sceneBridgingOptions = [.toolbars]
        // The window can't be made smaller than the view allows.
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(Self.defaultContentSize)
        window.title = "Glim"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        // Glim decides at launch whether to show the window; macOS must not
        // bring it back by itself, for instance at login.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        if let frameAutosaveName {
            if !window.setFrameUsingName(frameAutosaveName) { window.center() }
            window.setFrameAutosaveName(frameAutosaveName)
        }
        self.window = window
        return window
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // As the menu does when it opens: read every monitor now rather than
        // poll. The manager skips monitors read in the last two seconds.
        Task { await manager.refresh() }
    }

    func windowWillMiniaturize(_ notification: Notification) {
        endInteractions()
    }

    func windowWillClose(_ notification: Notification) {
        endInteractions()
        guard isOpen else { return }
        isOpen = false
        AppLog.app.info("window closed")
        onOpenChange(false)
    }

    /// An input switch left unconfirmed must not wait in a window nobody is
    /// looking at, and no drag can outlive the window. Controls are shared, so
    /// this also clears whatever the menu left half done.
    private func endInteractions() {
        for monitor in manager.monitors { monitor.endInteractions() }
    }
}
