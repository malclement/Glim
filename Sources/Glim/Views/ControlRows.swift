import GlimCore
import SwiftUI

/// A level: a symbol, a slider and its value in percent.
struct LevelRow<Symbol: View>: View {
    let title: String
    let control: DeviceControl<Double>
    /// Appended to the slider's spoken value.
    var spokenSuffix = ""
    @ViewBuilder let symbol: () -> Symbol

    var body: some View {
        HStack(spacing: 8) {
            symbol()
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(title)
                .accessibilityHidden(true)
            LevelSlider(title: title, control: control, spokenSuffix: spokenSuffix)
        }
    }
}

/// The brightness slider, which also says whether automatic brightness is
/// driving it.
struct BrightnessSlider: View {
    let monitor: Monitor
    let control: DeviceControl<Double>
    @Environment(\.adaptive) private var adaptive

    var body: some View {
        LevelSlider(title: "Brightness", control: control,
                    spokenSuffix: AccessibilityText.automaticBrightnessSuffix(adaptive?.statuses[monitor.id]))
    }
}

/// The slider and value shared by every level row.
struct LevelSlider: View {
    let title: String
    let control: DeviceControl<Double>
    /// The value as shown, once read. Percent of the range unless given.
    var valueText: ((Double) -> String)?
    /// Appended to the spoken value, such as ", adjusting automatically".
    var spokenSuffix = ""
    /// Wide enough for the badge and the longest value ("6500 K"). The same
    /// for every level, so the sliders line up.
    static let valueWidth: CGFloat = 66

    private var range: ClosedRange<Double> { control.range ?? 0...100 }

    private var shownValue: String {
        guard let value = control.value else { return "–" }
        if let valueText { return valueText(value) }
        return "\(Int((fraction(of: value, in: range) * 100).rounded()))%"
    }

    private var accessibilityValue: String {
        let value = control.value == nil ? "Unknown" : AccessibilityText.spokenTemperature(shownValue)
        return AccessibilityText.value(value + spokenSuffix, failure: control.failure?.message)
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
                Text(shownValue)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: Self.valueWidth, alignment: .trailing)
            // The slider's accessibility value already says all of this.
            .accessibilityHidden(true)
        }
        // SwiftUI never ends a drag on a slider it removes, for instance when
        // the monitor stops answering mid-drag, and reads stay held off until
        // the drag ends. The menu also ends drags as it opens and closes, but
        // the window can stay open for hours, so a slider ends its own.
        .onDisappear { control.endInteraction() }
    }
}

/// Volume, whose symbol doubles as the mute button when there is one.
struct VolumeRow: View {
    let volume: DeviceControl<Double>
    let mute: DeviceControl<Bool>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMuted: Bool { mute?.value == true }

    private var symbol: String { speakerSymbol(volume: volume, isMuted: isMuted) }

    var body: some View {
        HStack(spacing: 8) {
            if let mute {
                Button {
                    mute.set(!isMuted)
                } label: {
                    Image(systemName: symbol)
                        .contentTransition(Motion.symbolTransition(reduceMotion: reduceMotion))
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

/// The color temperature, from warm on the left to cool on the right, in
/// kelvin. While the monitor is in a preset without a temperature (sRGB,
/// native, custom RGB), the value names that preset instead, and moving the
/// slider brings back a temperature.
struct ColorTemperatureSlider: View {
    let monitor: Monitor
    let control: DeviceControl<Double>

    /// sRGB, native or custom RGB: the thumb's position means nothing until
    /// the slider is moved.
    private var hasNoTemperature: Bool { control.value == 0 }

    var body: some View {
        LevelSlider(title: "Color temperature", control: control,
                    valueText: { _ in MonitorText.colorTemperature(of: monitor) })
            .opacity(hasNoTemperature ? 0.6 : 1)
            .help(hasNoTemperature ? "This preset has no temperature. Move the slider to set one." : "Warmer to the left, cooler to the right")
    }
}

/// The color temperature as a menu row.
struct ColorTemperatureRow: View {
    let monitor: Monitor
    let control: DeviceControl<Double>

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help("Color temperature: warmer to the left")
                .accessibilityHidden(true)
            ColorTemperatureSlider(monitor: monitor, control: control)
        }
    }
}

/// The color preset as a menu row.
struct ColorPresetRow: View {
    let selector: ColorPresetSelector

    var body: some View {
        // The same three columns as a slider row: the symbol, the control
        // from the slider's leading edge to its trailing one, then the slot
        // the sliders keep for their value.
        HStack(spacing: 8) {
            Image(systemName: "paintpalette")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help("Color preset")
                .accessibilityHidden(true)
            ColorPresetPicker(selector: selector, fillsWidth: true)
            HStack(spacing: 3) {
                if let failure = selector.failure {
                    FailureBadge(failure: failure)
                }
                FactoryColorButton(selector: selector)
            }
            .frame(width: LevelSlider.valueWidth, alignment: .trailing)
        }
    }
}

/// Puts the factory preset back in one click. Takes its place, without
/// moving the picker, while the factory preset is active, or there is none.
struct FactoryColorButton: View {
    let selector: ColorPresetSelector

    var body: some View {
        let factory = selector.factory
        let isAtFactory = factory == nil || selector.current == factory
        Button {
            if let factory { selector.select(factory) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(factory.map { "Back to \($0.name)" } ?? "")
        .accessibilityLabel(factory.map { "Back to \($0.name)" } ?? "Factory color")
        .disabled(isAtFactory || selector.value == nil)
        .opacity(isAtFactory ? 0 : 1)
        .accessibilityHidden(isAtFactory)
    }
}

/// The presets to pick from, or a dash until the active one has been read.
/// A pick is written at once: presets are harmless, and the factory one is
/// always in the list to come back to.
struct ColorPresetPicker: View {
    let selector: ColorPresetSelector
    /// Takes the width it is given, as a slider does, instead of the width
    /// of its longest name.
    var fillsWidth = false

    private var selection: Binding<ColorPresetValue> {
        Binding(
            get: { selector.value ?? .other(reading: 0, temperature: nil) },
            set: { value in
                if let option = selector.presets.option(for: value) { selector.select(option) }
            }
        )
    }

    var body: some View {
        if let value = selector.value {
            Picker("Color preset", selection: selection) {
                ForEach(selector.options) { option in
                    Text(option.name).tag(ColorPresetValue.preset(option.value))
                }
                // Whatever else is active still needs a row, or the picker
                // would show nothing.
                if selector.current == nil {
                    Divider()
                    Text(selector.currentName ?? "Other").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .popUpWidth(fills: fillsWidth)
            .accessibilityLabel("Color preset")
        } else {
            Text("–")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unknown color preset")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("Input")
                    .accessibilityHidden(true)
                InputPicker(selector: selector, fillsWidth: true)
                HStack(spacing: 3) {
                    if let failure = selector.failure {
                        FailureBadge(failure: failure)
                    }
                }
                .frame(width: LevelSlider.valueWidth, alignment: .trailing)
            }
            if let pending = selector.pendingSelection {
                InputConfirmation(selector: selector, target: pending, isTested: isTested)
                    .transition(Motion.transition(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.animation(reduceMotion: reduceMotion), value: selector.pendingSelection)
    }
}

/// The inputs to pick from, or a dash until the active one has been read.
/// Picking only stages the switch: see ``InputConfirmation``.
struct InputPicker: View {
    let selector: InputSelector
    /// Takes the width it is given, as a slider does.
    var fillsWidth = false

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
        if selector.value == nil {
            Text("–")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unknown input")
        } else {
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
            .popUpWidth(fills: fillsWidth)
            .accessibilityLabel("Input")
        }
    }
}

/// Asks before switching inputs, in the menu and in the window alike.
struct InputConfirmation: View {
    let selector: InputSelector
    let target: InputOption
    let isTested: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var cancelHasFocus: Bool
    @AccessibilityFocusState private var cancelHasVoiceOverFocus: Bool

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
                    .focused($cancelHasFocus)
                    .accessibilityFocused($cancelHasVoiceOverFocus)
                // Deliberately not the default action: a stray Return must not
                // take the picture away. Tab to it, or click.
                Button("Switch") { selector.confirm() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(ContrastStyle.cardFillOpacity(contrast)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.secondary.opacity(ContrastStyle.cardStrokeOpacity(contrast)), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccessibilityText.inputConfirmationLabel)
        .onAppear(perform: announceAndFocus)
        .onChange(of: target) { announceAndFocus() }
    }

    /// Nothing else tells a VoiceOver user the card appeared: say so, and put
    /// focus on the safe choice.
    private func announceAndFocus() {
        AccessibilityNotification.Announcement(AccessibilityText.inputConfirmation(target: target.name)).post()
        cancelHasFocus = true
        cancelHasVoiceOverFocus = true
    }
}

/// A warning symbol that opens its message in a popover: keyboard reachable,
/// where a tooltip is not, and spoken in full by VoiceOver.
struct FailureBadge: View {
    let failure: ControlFailure
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(failure.message)
        .accessibilityLabel(AccessibilityText.warningLabel(failure.message))
        .accessibilityHint("Shows the explanation")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(failure.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(10)
        }
    }
}

/// A failure's message in words under the control it concerns, for the
/// window, where there is room.
struct FailureCaption: View {
    let failure: ControlFailure?

    var body: some View {
        if let failure {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(failure.message)
        }
    }
}

/// A symbol with an explanation in a popover, for notes the menu would
/// otherwise carry in a tooltip.
struct InfoBadge: View {
    let symbol: String
    let label: String
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .accessibilityLabel(label)
        .accessibilityHint(text)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(10)
        }
    }
}

/// The speaker symbol for a volume: slashed when muted, else one to three
/// waves.
@MainActor
func speakerSymbol(volume: DeviceControl<Double>, isMuted: Bool) -> String {
    if isMuted { return "speaker.slash.fill" }
    // Relative to the range: USB volume runs 0–1, DDC volume 0–100.
    switch fraction(of: volume.value ?? 0, in: volume.range ?? 0...1) {
    case ..<0.01: return "speaker.fill"
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

/// Where `value` sits in `range`, from 0 to 1.
func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(max((value - range.lowerBound) / span, 0), 1)
}

extension View {
    /// At its natural width while that fits, as a fixed-size control is; when
    /// it doesn't (a long preset or input name in the 300 pt menu), it takes
    /// what room there is and truncates, rather than overflow the row.
    func shrinksBeforeOverflowing() -> some View {
        ViewThatFits(in: .horizontal) {
            fixedSize()
            fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A pop-up button's width: the room it is given, or its natural width
    /// while that fits.
    @ViewBuilder
    func popUpWidth(fills: Bool) -> some View {
        if fills {
            fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        } else {
            shrinksBeforeOverflowing()
        }
    }
}
