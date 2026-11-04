import GlimCore
import SwiftUI

@main
struct GlimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Glim", systemImage: "sun.max") {
            MenuContentView(manager: appDelegate.manager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: appDelegate.manager)
        }
    }
}
