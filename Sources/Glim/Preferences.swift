import Foundation

/// `UserDefaults` keys. Glim keeps no other state of its own: monitor values
/// always come from the monitor.
enum Preferences {
    static let showContrast = "showContrast"
    static let showVolume = "showVolume"
    static let showInput = "showInput"
    /// Whether the sun is in the menu bar. On by default.
    static let showMenuBarIcon = "showMenuBarIcon"
    /// Whether Glim stays in the Dock while its window is closed. Off by
    /// default.
    static let alwaysShowDockIcon = "alwaysShowDockIcon"
}

extension UserDefaults {
    // Key paths for observing the two settings that decide where Glim
    // appears. Each property's name is its defaults key, which is what makes
    // key-value observing of UserDefaults work, for changes made by the app
    // and by `defaults write` alike.
    @objc dynamic var showMenuBarIcon: Bool {
        object(forKey: Preferences.showMenuBarIcon) as? Bool ?? true
    }

    @objc dynamic var alwaysShowDockIcon: Bool {
        bool(forKey: Preferences.alwaysShowDockIcon)
    }
}
