import os

/// The app's own log category, beside GlimCore's `ddc`, `discovery`, `audio`
/// and `state`: the window opening and closing, and Glim joining or leaving
/// the Dock.
enum AppLog {
    static let app = Logger(subsystem: "io.github.malclement.Glim", category: "app")
}
