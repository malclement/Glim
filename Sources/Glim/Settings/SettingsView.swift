import AppKit
import GlimCore
import SwiftUI

struct SettingsView: View {
    let manager: MonitorManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaysSettingsView(manager: manager)
                .tabItem { Label("Displays", systemImage: "display") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

struct GeneralSettingsView: View {
    @State private var login = LaunchAtLogin()
    @AppStorage(Preferences.showContrast) private var showContrast = true
    @AppStorage(Preferences.showVolume) private var showVolume = true
    @AppStorage(Preferences.showInput) private var showInput = true

    var body: some View {
        Form {
            Section {
                Toggle("Open Glim at login", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
                if login.requiresApproval {
                    HStack {
                        Text("Allow Glim in Login Items to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { login.openSystemSettings() }
                    }
                }
                if let error = login.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            Section {
                Toggle("Contrast", isOn: $showContrast)
                Toggle("Volume", isOn: $showVolume)
                Toggle("Input", isOn: $showInput)
            } header: {
                Text("Show in the menu")
            } footer: {
                Text("Brightness is always shown. Controls a display doesn't offer are never shown.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(height: 290)
        .onAppear { login.refresh() }
    }
}

struct DisplaysSettingsView: View {
    let manager: MonitorManager
    @State private var copied = false

    var body: some View {
        Form {
            if manager.monitors.isEmpty {
                Section {
                    Text(manager.availability == .available ? "No external display is connected." : "DDC/CI isn't available on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(manager.monitors) { monitor in
                Section(manager.title(for: monitor)) {
                    LabeledContent("Status", value: statusText(monitor.status))
                    LabeledContent("Profile", value: monitor.profile.isVerified
                        ? "Tested with Glim"
                        : "Untested: controls from the display's own description")
                    if let identity = monitor.identity {
                        LabeledContent("EDID", value: "\(identity.manufacturerCode) \(String(identity.productID, radix: 16, uppercase: true))")
                    }
                    LabeledContent("Speakers", value: monitor.audioDeviceName ?? (monitor.volume == nil ? "Not controlled" : "Over DDC/CI"))
                }
            }
            Section {
                HStack {
                    Button("Look for Displays") {
                        Task { await manager.rescan() }
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") { copyDiagnostics() }
                }
            } footer: {
                Text("Diagnostics list what Glim found and what each control reads, without serial numbers. Attach them to a bug report.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(height: 290)
    }

    private func statusText(_ status: Monitor.Status) -> String {
        switch status {
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .notResponding: "Not responding"
        }
    }

    private func copyDiagnostics() {
        let report = manager.diagnosticsReport(appVersion: AppInfo.versionString)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Glim")
                .font(.title2.weight(.semibold))
            Text("Version \(AppInfo.versionString)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Brightness, contrast, volume and input for your external display, from the menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
                .padding(.top, 4)
            Link("github.com/malclement/Glim", destination: AppInfo.repositoryURL)
                .padding(.top, 4)
            Text(AppInfo.copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 290)
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "MIT License"
    }

    // URL(string:) returns nil only for an empty string, so the fallback is
    // unreachable; it exists to avoid a force unwrap.
    static let repositoryURL = URL(string: "https://github.com/malclement/Glim") ?? URL(fileURLWithPath: "/")
}
