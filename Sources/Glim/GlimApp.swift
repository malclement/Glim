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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands { GlimCommands() }
    }
}

/// The menu bar's menus, shown while Glim is a regular app. SwiftUI gives an
/// app without a document window no File menu, and so no ⌘W.
struct GlimCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close") { Self.close(NSApp.keyWindow) }
                .keyboardShortcut("w")
        }
        SidebarCommands()
        CommandGroup(replacing: .help) {
            Button("Glim Help") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
        }
    }

    /// What ⌘W does: closes `window` if it has a close button, which the menu
    /// bar's panel doesn't.
    @MainActor
    static func close(_ window: NSWindow?) {
        guard let window, window.styleMask.contains(.closable) else { return }
        window.performClose(nil)
    }
}
