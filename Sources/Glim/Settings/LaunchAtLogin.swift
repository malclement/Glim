import Foundation
import GlimCore
import Observation
import ServiceManagement

/// Where Glim's login item stands, in the terms Glim cares about.
enum LoginItemStatus: String, Equatable, Sendable {
    case enabled
    case notRegistered
    /// The user has to allow it in System Settings › General › Login Items.
    case requiresApproval
    /// macOS can't find Glim as a login item.
    case notFound
}

/// The part of `SMAppService` Glim uses, so the toggle's behaviour is
/// testable without registering anything on the machine.
///
/// Every call is an XPC round trip to the system, and `unregister()` throws
/// when nothing is registered.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`: macOS launches the app itself, with no helper app
/// and no LaunchAgent plist.
struct SystemLoginItem: LoginItemService {
    private var service: SMAppService { .mainApp }

    var status: LoginItemStatus {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// Glim's login item, for the settings pane.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var errorMessage: String?
    /// Whether Glim runs from somewhere a login item is unreliable.
    let runsOutsideApplications: Bool

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let events: EventLog
    @ObservationIgnored private var hasReadStatus = false

    init(service: any LoginItemService = SystemLoginItem(), bundlePath: String = Bundle.main.bundlePath,
         events: EventLog = .shared) {
        self.service = service
        self.events = events
        self.runsOutsideApplications = !Self.isInApplications(bundlePath)
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var isNotFound: Bool { status == .notFound }

    /// Reads the current state. An XPC round trip, so it is done when the
    /// settings open or Glim becomes active, never at launch. Clears an error
    /// that no longer applies.
    func refresh() {
        update(service.status)
        if status == .enabled || status == .notRegistered { errorMessage = nil }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                Self.note("registering the login item", events)
                try service.register()
            } else if service.status == .enabled || service.status == .requiresApproval {
                // unregister() throws when there is nothing registered.
                Self.note("unregistering the login item", events)
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
            Self.note("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)", events)
        }
        update(service.status)
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func update(_ new: LoginItemStatus) {
        if new != status || !hasReadStatus {
            Self.note("login item status: \(new.rawValue)", events)
        }
        hasReadStatus = true
        // Observation re-renders on every assignment, even of an equal value.
        if status != new { status = new }
    }

    private static func note(_ message: String, _ events: EventLog) {
        AppLog.app.notice("\(message, privacy: .public)")
        events.record("login", message)
    }

    /// Whether `path`, the app bundle's, is where a login item works
    /// reliably: the Applications folder (or one inside it). Not a mounted
    /// disk image, another volume, or the randomised location macOS runs a
    /// quarantined app from.
    nonisolated static func isInApplications(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }
}
