import GlimCore
import SwiftUI

/// The menu bar window.
struct MenuContentView: View {
    let manager: MonitorManager
    @Environment(\.glimStore) private var store
    @AppStorage(Preferences.showScenes) private var showScenes = true

    /// The displays the menu shows: all of them, less those hidden in the
    /// window.
    private var shownMonitors: [Monitor] {
        manager.monitors.filter { store?.showsInMenu($0.id) ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
                .padding(.horizontal, 8)
            MenuFooter()
                .padding(6)
        }
        .frame(width: 300)
        // The window is reused between openings; reading the monitors each
        // time it opens is what keeps it current without polling.
        .onWindowKeyChange { isKey in
            // No drag can be in progress as the menu opens or closes, and a
            // switch left unconfirmed must not survive it closing.
            for monitor in manager.monitors { monitor.endInteractions() }
            if isKey {
                Task { await manager.refresh() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.availability {
        case .unavailable(let reason):
            MessageView(symbol: "display.trianglebadge.exclamationmark", title: "DDC/CI isn't available", message: reason)
        case .available:
            if manager.monitors.isEmpty {
                if manager.isDiscovering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for displays…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    MessageView(
                        symbol: "display",
                        title: "No external display",
                        message: "Connect a display over USB-C, DisplayPort or HDMI to control it from here."
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if shownMonitors.isEmpty {
                        Text("Every display is hidden from the menu. Show them again in Glim's window.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(shownMonitors) { monitor in
                        MonitorSectionView(monitor: monitor, title: store?.title(for: monitor, in: manager) ?? manager.title(for: monitor))
                        if monitor.id != shownMonitors.last?.id {
                            Divider()
                        }
                    }
                    if showScenes, let store, !store.scenes.isEmpty {
                        Divider()
                        SceneMenuSection(store: store, manager: manager)
                    }
                }
            }
        }
    }
}

/// The scenes, each applied in one click. The active one is ticked.
private struct SceneMenuSection: View {
    let store: GlimStore
    let manager: MonitorManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scenes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(store.scenes) { scene in
                let isActive = scene.isActive(on: manager.monitors)
                let digit = store.shortcutDigit(for: scene.id)
                MenuRowButton(title: scene.name, shortcut: digit.map { "⌘\($0)" }, isChecked: isActive,
                              symbol: scene.shownSymbol) {
                    scene.apply(to: manager.monitors)
                }
                .modifier(SceneShortcut(digit: digit))
                .disabled(scene.connected(in: manager.monitors).isEmpty)
                .accessibilityValue(isActive ? "Active" : "")
            }
        }
        // The rows' own padding lines their text up with the controls above.
        .padding(.horizontal, -8)
    }
}

/// ⌘1 to ⌘9 for the first nine scenes; nothing for the rest.
struct SceneShortcut: ViewModifier {
    let digit: Int?

    func body(content: Content) -> some View {
        if let digit, let key = String(digit).first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

/// A centred symbol, title and explanation, for states with no controls.
struct MessageView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The window, Settings and Quit, styled like menu items.
private struct MenuFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openMainWindow) private var openMainWindow

    var body: some View {
        VStack(spacing: 0) {
            // The window activates the app, and the menu closes as it does.
            MenuRowButton(title: "Open Glim…") {
                openMainWindow()
            }
            MenuRowButton(title: "Settings…", shortcut: "⌘,") {
                // A menu bar app is not active by default, and its Settings
                // window would open behind whatever is.
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            MenuRowButton(title: "Quit Glim", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// A full-width button that highlights on hover the way a menu item does.
struct MenuRowButton: View {
    let title: String
    var shortcut: String?
    /// nil for a row that is never ticked; otherwise a column is kept for
    /// the tick, so ticked and unticked titles line up.
    var isChecked: Bool?
    /// A symbol before the title, in a column of its own.
    var symbol: String?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let isChecked {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .opacity(isChecked ? 1 : 0)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(isEnabled ? .primary : .tertiary))
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var isHighlighted: Bool { isHovered && isEnabled }
}
