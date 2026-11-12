import GlimCore
import SwiftUI

/// One scene: its name, what it applies, what it holds for each display, and
/// the buttons to apply it, save the current settings into it, or delete it.
struct SceneDetailView: View {
    let store: GlimStore
    let manager: MonitorManager
    let scene: DisplayScene
    @State private var name: String
    /// Asks the window to confirm deleting this scene: the same question the
    /// sidebar asks.
    let requestDelete: (DisplayScene) -> Void

    init(store: GlimStore, manager: MonitorManager, scene: DisplayScene,
         requestDelete: @escaping (DisplayScene) -> Void = { _ in }) {
        self.store = store
        self.manager = manager
        self.scene = scene
        self.requestDelete = requestDelete
        _name = State(initialValue: scene.name)
    }

    private var connected: [Monitor] { scene.connected(in: manager.monitors) }

    /// The scene's displays, connected ones first, each with its current
    /// title or, while away, the name it was saved under.
    /// The scene's displays, connected ones first: what the scene sets, and,
    /// for a connected display that shows something else, what it shows now.
    private var entries: [(id: String, title: String, settings: DisplayScene.Settings, monitor: Monitor?, now: String?)] {
        scene.monitors.map { id, settings in
            let monitor = manager.monitors.first { $0.id == id }
            let differs = monitor.map { !$0.shows(settings, parts: scene.includes) } ?? false
            let now = differs ? monitor.flatMap(DisplayScene.Settings.init(capturing:)).map {
                SceneText.summary(of: $0, parts: scene.includes)
            } : nil
            return (id, monitor.map { store.title(for: $0, in: manager) } ?? settings.monitorName, settings, monitor, now)
        }
        .sorted { ($0.monitor == nil ? 1 : 0, $0.title) < ($1.monitor == nil ? 1 : 0, $1.title) }
    }

    var body: some View {
        Form {
            Section {
                SceneHeader(scene: scene, isActive: scene.isActive(on: manager.monitors))
                TextField("Name", text: $name)
                    .onChange(of: name) { _, new in store.rename(scene.id, to: new) }
                Picker("Symbol", selection: Binding(
                    get: { scene.shownSymbol },
                    set: { symbol in store.updateScene(scene.id) { $0.symbol = symbol } }
                )) {
                    ForEach(DisplayScene.symbols, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                            .accessibilityLabel(DisplayScene.name(ofSymbol: symbol))
                    }
                }
                if let digit = store.shortcutDigit(for: scene.id) {
                    LabeledContent("Shortcut", value: "⌘\(digit)")
                        .help("In Glim's menu, and in the Scenes menu while the window is in front")
                }
            }
            Section {
                ForEach(DisplayScene.Part.allCases, id: \.self) { part in
                    Toggle(SceneText.title(of: part), isOn: Binding(
                        get: { scene.includes.contains(part) },
                        set: { included in
                            store.updateScene(scene.id) { scene in
                                if included { scene.includes.insert(part) } else { scene.includes.remove(part) }
                            }
                        }
                    ))
                }
            } header: {
                Text("Applies")
            } footer: {
                footnote("Parts left out stay as they are when the scene is applied.")
            }
            Section("Displays") {
                if entries.isEmpty {
                    Text("No display settings saved yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.id) { entry in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(SceneText.summary(of: entry.settings, parts: scene.includes))
                                .foregroundStyle(.secondary)
                            if let now = entry.now {
                                Text("Now: \(now)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text(entry.title)
                        if entry.monitor == nil {
                            Text("Not connected")
                        }
                    }
                }
            }
            Section {
                // Two rows when the pane is too narrow for one.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        manageButtons
                        Spacer()
                        applyButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { manageButtons }
                        HStack { applyButtons }
                    }
                }
            } footer: {
                if connected.isEmpty {
                    footnote("None of this scene's displays is connected.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var manageButtons: some View {
        Button("Delete Scene…", role: .destructive) { requestDelete(scene) }
        Button("Duplicate") { store.duplicateScene(scene.id) }
    }

    @ViewBuilder
    private var applyButtons: some View {
        Button("Save Current Settings") {
            store.updateScene(scene.id) { $0.recapture(manager.monitors) }
        }
        .help("Replace what this scene holds for the connected displays with what they show now")
        .disabled(!manager.monitors.contains { DisplayScene.Settings(capturing: $0) != nil })
        Button("Apply") { scene.apply(to: manager.monitors) }
            .buttonStyle(.borderedProminent)
            .disabled(connected.isEmpty)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            // A grouped form aligns wrapped lines to the trailing edge.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SceneHeader: View {
    let scene: DisplayScene
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scene.shownSymbol)
                .font(.system(size: 28, weight: .light))
                .frame(width: 40)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .help(scene.name)
                    .accessibilityAddTraits(.isHeader)
                Text(isActive ? "Active: the connected displays show it" : "Scene")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// How the app puts a scene into words.
enum SceneText {
    static func title(of part: DisplayScene.Part) -> String {
        switch part {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .color: "Color"
        }
    }

    /// "Brightness 40% · Contrast 100% · 5000 K", for the parts it applies.
    static func summary(of settings: DisplayScene.Settings, parts: Set<DisplayScene.Part>) -> String {
        var items: [String] = []
        if parts.contains(.brightness), let level = settings.brightness {
            items.append("Brightness \(percent(level))")
        }
        if parts.contains(.contrast), let level = settings.contrast {
            items.append("Contrast \(percent(level))")
        }
        if parts.contains(.color), let color = settings.color {
            items.append(color.name)
        }
        return items.isEmpty ? "Nothing to apply" : items.joined(separator: " · ")
    }

    private static func percent(_ level: DisplayScene.Level) -> String {
        "\(Int((level.fraction * 100).rounded()))%"
    }
}
