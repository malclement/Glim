import Foundation
import os

/// The last few rare events, kept in memory for the diagnostics report.
///
/// Unified logging does not persist `.info` and `.debug`, and a user cannot
/// easily pull the log of a past session, so the events worth knowing about
/// in a bug report (a monitor coming and going, a control that fails, the
/// login item changing) are also kept here. Everything recorded must already
/// be free of serial numbers, display UUIDs and audio device UIDs.
public final class EventLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public var date: Date
        public var category: String
        public var message: String
        /// How many times this exact event happened in a row (1 for a single
        /// occurrence). `date` is that of the latest.
        public var count: Int
    }

    /// The most entries kept; older ones are dropped.
    public static let capacity = 40

    /// The log of the running app. Tests make their own instead.
    public static let shared = EventLog()

    private let storage = OSAllocatedUnfairLock(initialState: [Entry]())

    public init() {}

    /// Records an event. Repeating the previous event exactly (same category
    /// and message) raises its count instead of adding an entry, so a failure
    /// that repeats on every refresh does not push everything else out.
    public func record(_ category: String, _ message: String, at date: Date = Date()) {
        storage.withLock { entries in
            if let last = entries.last, last.category == category, last.message == message {
                entries[entries.count - 1].count += 1
                entries[entries.count - 1].date = date
                return
            }
            entries.append(Entry(date: date, category: category, message: message, count: 1))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    /// Oldest first.
    public var entries: [Entry] { storage.withLock { $0 } }

    /// One line per entry, with times relative to `now`:
    /// "12 s ago  [state] HP E27m G4 reconnected".
    public func lines(now: Date = Date()) -> [String] {
        entries.map { entry in
            let repeats = entry.count > 1 ? " (x\(entry.count))" : ""
            return "\(Self.relative(entry.date, to: now))  [\(entry.category)] \(entry.message)\(repeats)"
        }
    }

    static func relative(_ date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3600) h \(seconds % 3600 / 60) min ago"
        }
    }
}
