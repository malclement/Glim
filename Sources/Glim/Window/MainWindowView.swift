import AppKit
import GlimCore
import SwiftUI

/// Glim's main window: the connected monitors in a sidebar, and everything
/// about the selected one beside it.
///
/// It observes the same ``MonitorManager`` as the menu, and the same
/// ``Monitor`` objects, so a change made in one shows in the other at once,
/// and every monitor still has exactly one DDC/CI channel.
struct MainWindowView: View {
    let manager: MonitorManager
    @State private var selection: Monitor.ID?

    /// The selected monitor, or the first one while nothing is selected or the
    /// selected monitor is gone, so the sidebar always highlights the monitor
    /// the detail shows.
    private var shownMonitor: Monitor? {
        manager.monitors.first { $0.id == selection } ?? manager.monitors.first
    }

    var body: some View {
        NavigationSplitView {
            MonitorList(manager: manager, selection: Binding(get: { shownMonitor?.id }, set: { selection = $0 }))
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await manager.rescan() }
                } label: {
                    Label("Look for Displays", systemImage: "arrow.clockwise")
                }
                .help("Look for displays")
                .disabled(manager.availability != .available)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        // A switch staged on the monitor that leaves the pane, picked in the
        // sidebar or replaced by another as monitors come and go, must not be
        // waiting when it comes back. Only the input: a drag in the menu on
        // that monitor carries on.
        .onChange(of: shownMonitor?.id) { leaving, _ in
            manager.monitors.first { $0.id == leaving }?.input?.cancel()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch manager.availability {
        case .unavailable(let reason):
            NoMonitorView(manager: manager, symbol: "display.trianglebadge.exclamationmark",
                          title: "DDC/CI isn't available", message: reason)
        case .available:
            if let monitor = shownMonitor {
                MonitorDetailView(manager: manager, monitor: monitor)
                    // Each monitor gets its own view state, such as "Copied".
                    .id(monitor.id)
            } else if manager.isDiscovering {
                ProgressView("Looking for displays…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoMonitorView(manager: manager, symbol: "display", title: "No external display",
                              message: "Connect a display over USB-C, DisplayPort or HDMI to control it from here.")
            }
        }
    }
}

/// The sidebar.
private struct MonitorList: View {
    let manager: MonitorManager
    @Binding var selection: Monitor.ID?

    var body: some View {
        List(selection: $selection) {
            if !manager.monitors.isEmpty {
                Section("Displays") {
                    ForEach(manager.monitors) { monitor in
                        MonitorListRow(monitor: monitor, title: manager.title(for: monitor))
                            .tag(monitor.id)
                    }
                }
            }
        }
    }
}

struct MonitorListRow: View {
    let monitor: Monitor
    let title: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(MonitorText.status(monitor.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "display")
        }
        .accessibilityElement(children: .combine)
    }
}

/// The detail pane when there is no monitor to show.
private struct NoMonitorView: View {
    let manager: MonitorManager
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            // Diagnostics help most when Glim finds nothing.
            CopyDiagnosticsButton(manager: manager)
        }
    }
}

/// Copies the diagnostics report, and says so for a moment.
struct CopyDiagnosticsButton: View {
    let manager: MonitorManager
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy Diagnostics") {
            let report = manager.diagnosticsReport(appVersion: AppInfo.versionString)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch {
                // The button went away first.
            }
        }
    }
}
