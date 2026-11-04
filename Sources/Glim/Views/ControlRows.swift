import GlimCore
import SwiftUI

/// A level: a symbol, a slider and its value in percent.
struct LevelRow<Symbol: View>: View {
    let title: String
    let control: DeviceControl<Double>
    @ViewBuilder let symbol: () -> Symbol

    var body: some View {
        HStack(spacing: 8) {
            symbol()
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(title)
            LevelSlider(title: title, control: control)
        }
    }
}

/// The slider and value shared by every level row.
struct LevelSlider: View {
    let title: String
    let control: DeviceControl<Double>

    private var range: ClosedRange<Double> { control.range ?? 0...100 }

    private var percentText: String {
        guard let value = control.value else { return "–" }
        let span = range.upperBound - range.lowerBound
        let percent = span > 0 ? (value - range.lowerBound) / span * 100 : 0
        return "\(Int(percent.rounded()))%"
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { control.value ?? range.lowerBound }, set: { control.set($0) }),
                in: range,
                onEditingChanged: { control.setEditing($0) }
            )
            .controlSize(.small)
            .disabled(control.value == nil)
            .accessibilityLabel(title)
            .accessibilityValue(control.value == nil ? "Unknown" : percentText)

            Text(percentText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    if let failure = control.failure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.caption)
                            .offset(x: -14)
                            .help(failure.message)
                            .accessibilityLabel(failure.message)
                    }
                }
        }
    }
}

/// Volume, whose symbol doubles as the mute button when there is one.
struct VolumeRow: View {
    let volume: DeviceControl<Double>
    let mute: DeviceControl<Bool>?

    private var isMuted: Bool { mute?.value == true }

    private var symbol: String {
        if isMuted { return "speaker.slash.fill" }
        switch volume.value ?? 0 {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let mute {
                Button {
                    mute.set(!isMuted)
                } label: {
                    Image(systemName: symbol)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isMuted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .disabled(mute.value == nil)
                .help(isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("Volume")
            }
            LevelSlider(title: "Volume", control: volume)
        }
    }
}

/// The input picker. Picking an input only stages it; the switch happens
/// after an explicit confirmation, because it takes the picture away from
/// this Mac.
struct InputRow: View {
    let selector: InputSelector

    private var selection: Binding<UInt16> {
        Binding(
            get: { selector.pendingSelection?.value ?? selector.control.value ?? 0 },
            set: { value in
                if let option = selector.options.first(where: { $0.value == value }) {
                    selector.request(option)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("Input")
                Spacer(minLength: 8)
                if selector.control.value == nil {
                    Text("–")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unknown input")
                } else {
                    picker
                }
            }
            if let pending = selector.pendingSelection {
                InputConfirmation(selector: selector, target: pending)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: selector.pendingSelection)
    }

    private var picker: some View {
        Picker("Input", selection: selection) {
            ForEach(selector.options) { option in
                Text(option.name).tag(option.value)
            }
            // An active input that is not one of the options still
            // needs a row, or the picker would show nothing.
            if let value = selector.control.value, selector.current == nil {
                Text(selector.currentName ?? "Unknown").tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Input")
    }
}

private struct InputConfirmation: View {
    let selector: InputSelector
    let target: InputOption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Switch to \(target.name)?")
                .font(.callout.weight(.semibold))
            Text("This Mac's picture will leave the display. If nothing is connected to \(target.name), the screen goes dark: use the monitor's input button to come back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { selector.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Switch") { selector.confirm() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
