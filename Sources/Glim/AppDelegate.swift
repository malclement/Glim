import AppKit
import GlimCore

/// Owns the monitor manager and the main window, and ties them to the app's
/// lifecycle and to system events: launch and reopen, wake from sleep and
/// display reconfiguration.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: MonitorManager
    /// Scenes and per-display choices.
    let store: GlimStore
    /// Automatic brightness and evening warmth.
    let adaptive: AdaptiveController
    /// Whether Glim is in the Dock.
    let presence: AppPresence
    private(set) lazy var mainWindow = MainWindowController(
        manager: manager, store: store, adaptive: adaptive, frameAutosaveName: frameAutosaveName, present: present
    ) { [weak self] isOpen in
        self?.presence.isWindowOpen = isOpen
    }
    private let frameAutosaveName: String?
    private let present: @MainActor (NSWindow) -> Void
    private let isAnotherCopyRunning: @MainActor () -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    override convenience init() {
        self.init(manager: MonitorManager(), defaults: .standard, frameAutosaveName: "MainWindow",
                  present: MainWindowController.bringForward)
    }

    /// Tests pass a manager on a fake platform, a defaults suite of their own,
    /// a window that never comes on screen nor saves its frame, and a policy
    /// recorder, so that launching never touches the test process itself.
    init(manager: MonitorManager, defaults: UserDefaults, adaptiveEnvironment: (any AdaptiveEnvironment)? = nil,
         frameAutosaveName: String? = nil,
         present: @escaping @MainActor (NSWindow) -> Void,
         setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) },
         isAnotherCopyRunning: @escaping @MainActor () -> Bool = AppDelegate.anotherCopyIsRunning) {
        self.manager = manager
        let store = GlimStore(defaults: defaults)
        self.store = store
        self.adaptive = AdaptiveController(manager: manager, environment: adaptiveEnvironment ?? LiveAdaptiveEnvironment(),
                                           settings: store.loadAdaptive(), save: { store.saveAdaptive($0) })
        self.presence = AppPresence(defaults: defaults, setPolicy: setPolicy)
        self.frameAutosaveName = frameAutosaveName
        self.present = present
        self.isAnotherCopyRunning = isAnotherCopyRunning
        super.init()
    }

    /// Whether a copy of Glim with this bundle identifier is already running.
    static func anotherCopyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies would talk DDC/CI over each other.
        if isAnotherCopyRunning() {
            NSApp.terminate(nil)
            return
        }
        // The bundle's LSUIElement keeps Glim out of the Dock at launch; from
        // here on the presence decides. Applying it now also covers running
        // the bare executable during development.
        presence.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch's Apple event says how Glim was started, and only while
        // launching: read it first.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        manager.start()
        adaptive.start()
        let workspace = NSWorkspace.shared.notificationCenter
        // Nothing is read while the displays sleep; on wake every display
        // catches up with the light at once.
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.adaptive.setSuspended(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.adaptive.setSuspended(false) }
        // After a sleep the display transport is often recreated, and a
        // monitor can come back with other values than it slept with: look
        // again after a moment, then read everything again.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.displaysDidWake() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysDidWake() }
        // Fires when a display is connected, disconnected or reconfigured. The
        // IOKit notifications inside the manager usually get there first.
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRescan() }
        showWindowUnlessLoginItem(launchEvent)
    }

    /// Opening Glim from Finder, Spotlight or Launchpad shows its window;
    /// macOS starting it at login leaves it in the menu bar.
    func showWindowUnlessLoginItem(_ launchEvent: NSAppleEventDescriptor?) {
        guard !Self.isLoginItemLaunch(launchEvent) else {
            AppLog.app.info("started at login; the window stays closed")
            return
        }
        mainWindow.show()
    }

    /// Whether `event`, the launch's open-application event, says macOS
    /// started Glim as a login item rather than someone opening it.
    nonisolated static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opening Glim while it runs, from Finder, Spotlight, the Dock or
    /// `open`, brings its window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    /// Glim lives on in the menu bar when its window closes. SwiftUI asks
    /// this each time the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showMainWindow() {
        mainWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        adaptive.stop()
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
