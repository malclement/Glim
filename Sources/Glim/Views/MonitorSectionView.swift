import GlimCore
import SwiftUI

/// One monitor: its name and status, then its controls.
struct MonitorSectionView: View {
    let monitor: Monitor
    let title: String
    @Environment(\.glimStore) private var store
    @AppStorage(Preferences.showContrast) private var showContrastByDefault = true
    @AppStorage(Preferences.showColor) private var showColorByDefault = true
    @AppStorage(Preferences.showVolume) private var showVolumeByDefault = true
    @AppStorage(Preferences.showInput) private var showInputByDefault = true
    @Environment(\.adaptive) private var adaptive

    // The display's own choice, else the Settings default.
    private var showContrast: Bool { shows(.contrast, default: showContrastByDefault) }
    private var showColor: Bool { shows(.color, default: showColorByDefault) }
    private var showVolume: Bool { shows(.volume, default: showVolumeByDefault) }
    private var showInput: Bool { shows(.input, default: showInputByDefault) }

    private func shows(_ row: MenuRow, default fallback: Bool) -> Bool {
        store?.shows(row, for: monitor.id, default: fallback) ?? fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch monitor.status {
            case .notResponding:
                NotRespondingView(monitor: monitor)
                // The USB speakers are their own device and keep working.
                if showVolume, monitor.hasUSBSpeakers, let volume = monitor.volume {
                    VolumeRow(volume: volume, mute: monitor.mute)
                }
            case .connecting, .ready:
                controls
            }
        }
        // Several monitors each have a "Brightness" slider: group them under
        // the monitor's name.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .help(title)
                .accessibilityAddTraits(.isHeader)
            if monitor.status == .connecting {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Connecting")
            }
            Spacer(minLength: 0)
            if !monitor.profile.isTested {
                InfoBadge(symbol: "info.circle", label: "Untested display",
                          text: "Glim hasn't been tested with this display. Its controls come from the display's own description.")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if !monitor.hasControls {
            Text(monitor.status == .connecting ? "Reading the display…" : "This display doesn't offer any control Glim supports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let brightness = monitor.brightness {
            LevelRow(title: "Brightness", control: brightness,
                     spokenSuffix: AccessibilityText.automaticBrightnessSuffix(adaptive?.statuses[monitor.id])) {
                BrightnessSymbol(monitor: monitor)
            }
        }
        if showContrast, let contrast = monitor.contrast {
            LevelRow(title: "Contrast", control: contrast) {
                Image(systemName: "circle.lefthalf.filled")
            }
        }
        if showColor, let temperature = monitor.colorTemperature {
            ColorTemperatureRow(monitor: monitor, control: temperature)
        }
        if showColor, let preset = monitor.colorPreset {
            ColorPresetRow(selector: preset)
        }
        if showVolume, let volume = monitor.volume {
            VolumeRow(volume: volume, mute: monitor.mute)
        }
        if showInput, let input = monitor.input {
            InputRow(selector: input, isTested: monitor.profile.isTested(.input))
        }
    }
}

/// Shown instead of the controls while the monitor does not answer, in the
/// menu and in the window.
struct NotRespondingView: View {
    let monitor: Monitor
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not responding", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout.weight(.medium))
            Text("The display may be asleep or showing another input. \(monitor.profile.ddcHelp)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(isRetrying ? "Trying…" : "Try Again") {
                isRetrying = true
                Task {
                    await monitor.refresh()
                    isRetrying = false
                }
            }
            .controlSize(.small)
            .disabled(isRetrying)
        }
    }
}

/// The brightness row's sun: filled, in the accent color, while automatic
/// brightness drives it; plain otherwise, or while the user has taken over.
struct BrightnessSymbol: View {
    /// An SF Symbol since macOS 12.
    nonisolated static let pausedSymbol = "sun.max.circle"
    let monitor: Monitor
    @Environment(\.adaptive) private var adaptive

    var body: some View {
        switch adaptive?.statuses[monitor.id] {
        case .following?:
            Image(systemName: "sun.max.fill")
                .foregroundStyle(Color.accentColor)
                .help("Brightness: adjusting automatically")
        case .paused?:
            // An outlined sun, apart from the plain one of "off".
            Image(systemName: BrightnessSymbol.pausedSymbol)
                .help("Brightness: automatic, paused because you set it by hand")
        default:
            Image(systemName: "sun.max")
        }
    }
}

