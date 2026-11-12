import AppKit
import GlimCore
import SwiftUI

@main
struct GlimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared with the settings, and with the user, who can drag the icon out
    /// of the menu bar. ``AppPresence`` keeps Glim in the Dock while it is off.
    @AppStorage(Preferences.showMenuBarIcon) private var showsMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("Glim", systemImage: "sun.max", isInserted: $showsMenuBarIcon) {
            MenuContentView(manager: appDelegate.manager)
                .environment(\.openMainWindow, OpenMainWindowAction { [appDelegate] in appDelegate.showMainWindow() })
                .environment(\.glimStore, appDelegate.store)
                .environment(\.adaptive, appDelegate.adaptive)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands { GlimCommands(store: appDelegate.store, manager: appDelegate.manager, front: .shared) }
    }
}

/// The menu bar's menus, shown while Glim is a regular app. SwiftUI gives an
/// app without a document window no File menu, and so no ⌘W.
struct GlimCommands: Commands {
    let store: GlimStore
    let manager: MonitorManager
    let front: MainWindowFront

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close") { Self.close(NSApp.keyWindow) }
                .keyboardShortcut("w")
        }
        SidebarCommands()
        // The window's own toolbar actions, as menu items with their keys.
        CommandGroup(replacing: .newItem) {
            Button("New Scene") { Self.newScene(store: store, manager: manager) }
                .keyboardShortcut("n")
                .disabled(!front.isMainWindowKey || !Self.canCaptureScene(manager))
            Button("Look for Displays") { Task { await manager.rescan() } }
                .keyboardShortcut("r")
                .disabled(!front.isMainWindowKey || manager.availability != .available)
        }
        CommandMenu("Scenes") {
            if store.scenes.isEmpty {
                Text("No Scenes")
            }
            ForEach(store.scenes) { scene in
                // A tick marks the scene the displays show now.
                Toggle(scene.name, isOn: Binding(
                    get: { scene.isActive(on: manager.monitors) },
                    set: { _ in scene.apply(to: manager.monitors) }
                ))
                .modifier(SceneShortcut(digit: store.shortcutDigit(for: scene.id)))
                .disabled(scene.connected(in: manager.monitors).isEmpty)
            }
        }
        CommandGroup(replacing: .help) {
            Button("Glim Help") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
        }
    }

    /// Whether there is anything to save as a scene.
    @MainActor
    static func canCaptureScene(_ manager: MonitorManager) -> Bool {
        manager.monitors.contains { DisplayScene.Settings(capturing: $0) != nil }
    }

    /// Saves what the displays show as a scene, and lets the window select it.
    @MainActor
    static func newScene(store: GlimStore, manager: MonitorManager) {
        guard canCaptureScene(manager) else { return }
        let scene = store.addScene(capturing: manager.monitors)
        NotificationCenter.default.post(name: .glimDidAddScene, object: scene.id)
    }

    /// What ⌘W does: closes `window` if it has a close button, which the menu
    /// bar's panel doesn't.
    @MainActor
    static func close(_ window: NSWindow?) {
        guard let window, window.styleMask.contains(.closable) else { return }
        window.performClose(nil)
    }
}

extension Notification.Name {
    /// Posted with the new scene's id when a menu command makes a scene.
    static let glimDidAddScene = Notification.Name("io.github.malclement.Glim.didAddScene")
}

/// Whether Glim's main window is the key window, for commands that act on it.
/// Commands can't see the key window themselves, so this watches it.
@MainActor @Observable
final class MainWindowFront {
    static let shared = MainWindowFront()

    private(set) var isMainWindowKey = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let isKey = NSApp.keyWindow?.identifier == MainWindowController.identifier
                    if let self, self.isMainWindowKey != isKey { self.isMainWindowKey = isKey }
                }
            })
        }
    }
}
