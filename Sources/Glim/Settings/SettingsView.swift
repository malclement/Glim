import AppKit
import GlimCore
import SwiftUI

/// App settings. What Glim knows about each monitor, and Copy Diagnostics,
/// are in the main window.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

struct GeneralSettingsView: View {
    @State private var login = LaunchAtLogin()
    @AppStorage(Preferences.showMenuBarIcon) private var showsMenuBarIcon = true
    @AppStorage(Preferences.alwaysShowDockIcon) private var alwaysShowsDockIcon = false
    @AppStorage(Preferences.showContrast) private var showContrast = true
    @AppStorage(Preferences.showColor) private var showColor = true
    @AppStorage(Preferences.showVolume) private var showVolume = true
    @AppStorage(Preferences.showInput) private var showInput = true
    @AppStorage(Preferences.showScenes) private var showScenes = true

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
                Toggle("Show in the menu bar", isOn: $showsMenuBarIcon)
                // Without the menu bar icon, the Dock is the way back to Glim,
                // so it stays there. The switch shows AppPresence's own rule
                // with the window closed.
                Toggle("Always show in the Dock", isOn: Binding(
                    get: {
                        AppPresence.showsDockIcon(isWindowOpen: false, alwaysShowDockIcon: alwaysShowsDockIcon,
                                                  showsMenuBarIcon: showsMenuBarIcon)
                    },
                    set: { alwaysShowsDockIcon = $0 }
                ))
                .disabled(!showsMenuBarIcon)
            } footer: {
                Text(showsMenuBarIcon
                     ? "Otherwise Glim is in the Dock only while its window is open."
                     : "Glim stays in the Dock while it isn't in the menu bar.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Contrast", isOn: $showContrast)
                Toggle("Color", isOn: $showColor)
                Toggle("Volume", isOn: $showVolume)
                Toggle("Input", isOn: $showInput)
                Toggle("Scenes", isOn: $showScenes)
            } header: {
                Text("Show in the menu")
            } footer: {
                Text("Brightness is always shown. Each display can change these in Glim's window.")
                    .foregroundStyle(.secondary)
                    // A grouped form aligns wrapped lines to the trailing edge.
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
        .onAppear { login.refresh() }
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
            Text("Brightness, contrast, volume and input for your external display, from the menu bar or Glim's window.")
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
        .frame(height: 440)
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
