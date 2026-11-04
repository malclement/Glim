import Observation
import ServiceManagement

/// Glim's login item, through `SMAppService`. No helper app and no
/// LaunchAgent plist: macOS launches the app itself.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    /// The user has to allow it in System Settings › General › Login Items.
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    /// Reads the current state. An XPC round trip, so it is done when the
    /// settings open, not at launch.
    func refresh() {
        update(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status == .enabled || service.status == .requiresApproval {
                // unregister() throws when there is nothing registered.
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        update(service.status)
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func update(_ status: SMAppService.Status) {
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }
}
