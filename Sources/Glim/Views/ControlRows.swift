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
                .accessibilityHidden(true)
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
        return "\(Int((fraction(of: value, in: range) * 100).rounded()))%"
    }

    private var accessibilityValue: String {
        let value = control.value == nil ? "Unknown" : percentText
        return control.failure.map { "\(value). \($0.message)" } ?? value
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
            .accessibilityValue(accessibilityValue)

            // A slot wide enough for the badge and the value, so the badge
            // never covers the slider and nothing moves when it appears.
            HStack(spacing: 3) {
                if let failure = control.failure {
                    FailureBadge(failure: failure)
                }
                Text(percentText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54, alignment: .trailing)
            // The slider's accessibility value already says all of this.
            .accessibilityHidden(true)
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
        // Relative to the range: USB volume runs 0–1, DDC volume 0–100.
        switch fraction(of: volume.value ?? 0, in: volume.range ?? 0...1) {
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
                    .accessibilityHidden(true)
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
    /// Whether switching inputs was ever tried on this model.
    let isTested: Bool

    private var selection: Binding<UInt16> {
        Binding(
            get: { selector.pendingSelection?.value ?? selector.value ?? 0 },
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
                    .accessibilityHidden(true)
                Text("Input")
                if let failure = selector.failure {
                    FailureBadge(failure: failure)
                }
                Spacer(minLength: 8)
                if selector.value == nil {
                    Text("–")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unknown input")
                } else {
                    picker
                }
            }
            if let pending = selector.pendingSelection {
                InputConfirmation(selector: selector, target: pending, isTested: isTested)
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
            if let value = selector.value, selector.current == nil {
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
    let isTested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Switch to \(target.name)?")
                .font(.callout.weight(.semibold))
            Text("This Mac's picture will leave the display. If nothing is connected to \(target.name), the screen goes dark: use the monitor's input button to come back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isTested {
                Label("Glim hasn't tested input switching on this monitor yet.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { selector.cancel() }
                    .keyboardShortcut(.cancelAction)
                // Deliberately not the default action: a stray Return must not
                // take the picture away. Tab to it, or click.
                Button("Switch") { selector.confirm() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A warning symbol whose tooltip and accessibility label carry a control's
/// failure.
struct FailureBadge: View {
    let failure: ControlFailure

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .font(.caption)
            .help(failure.message)
            .accessibilityLabel(failure.message)
    }
}

/// Where `value` sits in `range`, from 0 to 1.
func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(max((value - range.lowerBound) / span, 0), 1)
}
