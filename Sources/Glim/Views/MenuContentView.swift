import GlimCore
import SwiftUI

/// The menu bar window.
struct MenuContentView: View {
    let manager: MonitorManager

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
                    ForEach(manager.monitors) { monitor in
                        MonitorSectionView(monitor: monitor, title: manager.title(for: monitor))
                        if monitor.id != manager.monitors.last?.id {
                            Divider()
                        }
                    }
                }
            }
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
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHovered ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
