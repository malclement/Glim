import os

/// The app's own log category, beside GlimCore's `ddc`, `discovery`, `audio`
/// and `state`: the window opening and closing, Glim joining or leaving the
/// Dock, the launch and the login item.
enum AppLog {
    static let app = Logger(subsystem: "io.github.malclement.Glim", category: "app")
}

/// How this run of Glim started, for the diagnostics report.
@MainActor
enum LaunchInfo {
    /// Whether macOS started Glim as a login item. nil before launch.
    static var launchedAtLogin: Bool?
}
