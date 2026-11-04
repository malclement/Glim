import os

/// Glim's log categories. Frame dumps are logged at debug level, which macOS
/// does not persist; watch them live with
/// `log stream --level debug --predicate 'subsystem == "io.github.malclement.Glim"'`.
enum Log {
    static let subsystem = "io.github.malclement.Glim"
    static let ddc = Logger(subsystem: subsystem, category: "ddc")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let state = Logger(subsystem: subsystem, category: "state")
}
