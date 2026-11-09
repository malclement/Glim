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
    @Environment(\.glimStore) private var store
    @State private var selection: SidebarItem?

    /// The selected scene, if a scene is selected and still exists.
    private var shownScene: DisplayScene? {
        guard case .scene(let id) = selection else { return nil }
        return store?.scene(id)
    }

    /// The selected monitor, or the first one while nothing is selected or the
    /// selection is gone, so the sidebar always highlights what the detail
    /// shows. nil while a scene is shown.
    private var shownMonitor: Monitor? {
        guard shownScene == nil else { return nil }
        if case .monitor(let id) = selection, let monitor = manager.monitors.first(where: { $0.id == id }) { return monitor }
        return manager.monitors.first
    }

    private var shownItem: SidebarItem? {
        shownScene.map { .scene($0.id) } ?? shownMonitor.map { .monitor($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            SidebarList(manager: manager, selection: Binding(get: { shownItem }, set: { selection = $0 }))
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .toolbar {
            if let store {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let scene = store.addScene(capturing: manager.monitors)
                        selection = .scene(scene.id)
                    } label: {
                        Label("New Scene", systemImage: "plus")
                    }
                    .help("Save what the displays show now as a scene")
                    .disabled(!manager.monitors.contains { DisplayScene.Settings(capturing: $0) != nil })
                }
            }
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
        .onChange(of: shownItem) { leaving, _ in
            guard case .monitor(let leaving) = leaving else { return }
            manager.monitors.first { $0.id == leaving }?.input?.cancel()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let scene = shownScene, let store {
            SceneDetailView(store: store, manager: manager, scene: scene)
                .id(scene.id)
        } else {
            monitorDetail
        }
    }

    @ViewBuilder
    private var monitorDetail: some View {
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

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case monitor(Monitor.ID)
    case scene(DisplayScene.ID)
}

/// The sidebar: the displays, then the scenes.
private struct SidebarList: View {
    let manager: MonitorManager
    @Binding var selection: SidebarItem?
    @Environment(\.glimStore) private var store

    var body: some View {
        List(selection: $selection) {
            if !manager.monitors.isEmpty {
                Section("Displays") {
                    ForEach(manager.monitors) { monitor in
                        MonitorListRow(monitor: monitor, title: store?.title(for: monitor, in: manager) ?? manager.title(for: monitor))
                            .tag(SidebarItem.monitor(monitor.id))
                    }
                }
            }
            if let store {
                Section("Scenes") {
                    if store.scenes.isEmpty {
                        // Not selectable: it has no tag.
                        Text("None yet: save one with +")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Save what your displays show with the + button, then apply it from here or the menu.")
                    }
                    ForEach(store.scenes) { scene in
                        SceneListRow(scene: scene, isActive: scene.isActive(on: manager.monitors))
                            .tag(SidebarItem.scene(scene.id))
                            .contextMenu {
                                Button("Apply") { scene.apply(to: manager.monitors) }
                                    .disabled(scene.connected(in: manager.monitors).isEmpty)
                                Button("Duplicate") {
                                    if let copy = store.duplicateScene(scene.id) { selection = .scene(copy.id) }
                                }
                                Divider()
                                Button("Delete Scene", role: .destructive) { store.deleteScene(scene.id) }
                            }
                    }
                    .onMove { store.moveScenes(from: $0, to: $1) }
                }
            }
        }
    }
}

struct SceneListRow: View {
    let scene: DisplayScene
    let isActive: Bool

    var body: some View {
        Label {
            HStack {
                Text(scene.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("The connected displays show this scene")
                }
            }
        } icon: {
            Image(systemName: scene.shownSymbol)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Active" : "")
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
            if monitor.status == .notResponding {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .symbolRenderingMode(.multicolor)
            } else {
                Image(systemName: "display")
            }
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
