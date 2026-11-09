import GlimCore
import SwiftUI

/// Everything about one monitor: its controls, what Glim knows about it, and
/// diagnostics. The window shows every control the monitor offers; the
/// settings that hide rows apply to the menu only.
struct MonitorDetailView: View {
    let manager: MonitorManager
    let monitor: Monitor

    var body: some View {
        Form {
            Section {
                MonitorHeader(monitor: monitor, title: manager.title(for: monitor))
            }
            Section("Controls") {
                MonitorControls(monitor: monitor)
            }
            .labelStyle(IconColumnLabelStyle())
            Section("Display") {
                LabeledContent("Model", value: monitor.name)
                if let identity = monitor.identity {
                    LabeledContent("EDID", value: MonitorText.edid(identity))
                }
                LabeledContent("Profile", value: MonitorText.profile(monitor.profile))
                LabeledContent("Speakers", value: MonitorText.speakers(of: monitor))
            }
            Section {
                HStack {
                    Spacer()
                    CopyDiagnosticsButton(manager: manager)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Diagnostics list what Glim found and what each control reads, without serial numbers. Attach them to a bug report.")
                    .foregroundStyle(.secondary)
                    // A grouped form aligns wrapped lines to the trailing edge.
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// The monitor's name and status.
private struct MonitorHeader: View {
    let monitor: Monitor
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(MonitorText.status(monitor.status))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if monitor.status == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            }
            if !monitor.profile.isTested {
                Label("Untested", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Glim hasn't been tested with this display. Its controls come from the display's own description.")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The controls, as form rows. Mirrors the menu's rules: while the monitor
/// doesn't answer, its DDC/CI controls make way for a retry, and USB speakers,
/// a separate device, stay.
private struct MonitorControls: View {
    let monitor: Monitor

    var body: some View {
        switch monitor.status {
        case .notResponding:
            NotRespondingView(monitor: monitor)
            if monitor.hasUSBSpeakers, let volume = monitor.volume {
                VolumeControls(volume: volume, mute: monitor.mute)
            }
        case .connecting, .ready:
            if !monitor.hasControls {
                if monitor.status == .connecting {
                    Text("Reading the display…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("This display doesn't offer any control Glim supports.")
                        .foregroundStyle(.secondary)
                }
            }
            if let brightness = monitor.brightness {
                LevelControl(title: "Brightness", symbol: "sun.max", control: brightness)
            }
            if let contrast = monitor.contrast {
                LevelControl(title: "Contrast", symbol: "circle.lefthalf.filled", control: contrast)
            }
            if let volume = monitor.volume {
                VolumeControls(volume: volume, mute: monitor.mute)
            }
            if let input = monitor.input {
                InputControl(selector: input, isTested: monitor.profile.isTested(.input))
            }
        }
    }
}

private struct LevelControl: View {
    let title: String
    let symbol: String
    let control: DeviceControl<Double>

    var body: some View {
        LabeledContent {
            LevelSlider(title: title, control: control)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Volume, and mute as a switch of its own.
private struct VolumeControls: View {
    let volume: DeviceControl<Double>
    let mute: DeviceControl<Bool>?

    var body: some View {
        LabeledContent {
            LevelSlider(title: "Volume", control: volume)
        } label: {
            Label("Volume", systemImage: speakerSymbol(volume: volume, isMuted: mute?.value == true))
        }
        if let mute {
            // A warning sits beside the control it concerns, as on the other
            // rows.
            LabeledContent {
                HStack(spacing: 6) {
                    if let failure = mute.failure {
                        FailureBadge(failure: failure)
                    }
                    Toggle("Mute", isOn: Binding(get: { mute.value ?? false }, set: { mute.set($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(mute.value == nil)
                }
            } label: {
                Label("Mute", systemImage: "speaker.slash")
            }
        }
    }
}

/// Puts every symbol in a column of one width, as the menu's rows do, so the
/// titles line up whichever symbol is wider.
private struct IconColumnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 20)
            configuration.title
        }
    }
}

/// The input, with the same confirmation as in the menu.
private struct InputControl: View {
    let selector: InputSelector
    /// Whether switching inputs was ever tried on this model.
    let isTested: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let failure = selector.failure {
                    FailureBadge(failure: failure)
                }
                InputPicker(selector: selector)
            }
        } label: {
            Label("Input", systemImage: "cable.connector")
        }
        if let pending = selector.pendingSelection {
            InputConfirmation(selector: selector, target: pending, isTested: isTested)
        }
    }
}
