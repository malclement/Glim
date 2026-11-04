import GlimCore
import SwiftUI

@main
struct GlimApp: App {
    var body: some Scene {
        MenuBarExtra("Glim", systemImage: "sun.max") {
            Text("Glim")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
