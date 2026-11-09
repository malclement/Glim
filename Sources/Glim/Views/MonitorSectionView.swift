import GlimCore
import SwiftUI

/// One monitor: its name and status, then its controls.
struct MonitorSectionView: View {
    let monitor: Monitor
    let title: String
    @AppStorage(Preferences.showContrast) private var showContrast = true
    @AppStorage(Preferences.showVolume) private var showVolume = true
    @AppStorage(Preferences.showInput) private var showInput = true

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
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if monitor.status == .connecting {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Connecting")
            }
            Spacer(minLength: 0)
            if !monitor.profile.isTested {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Glim hasn't been tested with this display. Its controls come from the display's own description.")
                    .accessibilityLabel("Untested display")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if monitor.status == .ready, !monitor.hasControls {
            Text("This display doesn't offer any control Glim supports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let brightness = monitor.brightness {
            LevelRow(title: "Brightness", control: brightness) {
                Image(systemName: "sun.max")
            }
        }
        if showContrast, let contrast = monitor.contrast {
            LevelRow(title: "Contrast", control: contrast) {
                Image(systemName: "circle.lefthalf.filled")
            }
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
