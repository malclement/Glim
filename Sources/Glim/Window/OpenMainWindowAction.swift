import SwiftUI

/// Opens Glim's main window from inside a view, the way `openSettings` opens
/// the settings. The app sets it; anywhere else it does nothing.
struct OpenMainWindowAction: Sendable {
    let open: @MainActor @Sendable () -> Void

    @MainActor
    func callAsFunction() { open() }
}

// Written out because the `@Entry` macro needs Xcode's SwiftUI macro plugin,
// which the Command Line Tools don't have.
private struct OpenMainWindowKey: EnvironmentKey {
    static let defaultValue = OpenMainWindowAction {}
}

extension EnvironmentValues {
    var openMainWindow: OpenMainWindowAction {
        get { self[OpenMainWindowKey.self] }
        set { self[OpenMainWindowKey.self] = newValue }
    }
}
