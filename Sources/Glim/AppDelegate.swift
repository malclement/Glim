import AppKit
import GlimCore

/// Owns the monitor manager and ties it to the app's lifecycle and to system
/// events: wake from sleep and display reconfiguration.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = MonitorManager()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle's LSUIElement already keeps Glim out of the Dock; this
        // also covers running the bare executable during development.
        NSApp.setActivationPolicy(.accessory)
        // Two copies would talk DDC/CI over each other.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()
        let workspace = NSWorkspace.shared.notificationCenter
        // After a sleep the display transport is often recreated; give it a
        // moment, then look again.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.scheduleRescan(after: .seconds(2)) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.scheduleRescan(after: .seconds(2)) }
        // Fires when a display is connected, disconnected or reconfigured. The
        // IOKit notifications inside the manager usually get there first.
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRescan() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        manager.stop()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (MonitorManager) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self.manager)
            }
        }
        observers.append((center, observer))
    }
}
