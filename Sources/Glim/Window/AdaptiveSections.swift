import GlimCore
import SwiftUI

/// Automatic brightness for one display: the switch, what it follows, what
/// it is doing now, the curve it has learned, and the schedule.
struct AdaptiveBrightnessSection: View {
    let controller: AdaptiveController
    let monitor: Monitor

    private var settings: AdaptiveSettings { controller.settings(for: monitor.id) }

    private func binding<T>(_ keyPath: WritableKeyPath<AdaptiveSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in controller.update(monitor.id) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        let settings = self.settings
        let effective = controller.effectiveSource(for: monitor.id)
        Section {
            Toggle("Adjust brightness automatically", isOn: binding(\.isEnabled))
            if settings.isEnabled {
                Picker("Follow", selection: binding(\.source)) {
                    Text("The light in the room").tag(AdaptiveSettings.Source.lightSensor)
                        .disabled(!controller.environment.hasLightSensor)
                    Text("The MacBook screen").tag(AdaptiveSettings.Source.followBuiltIn)
                        .disabled(!controller.environment.hasBuiltInBrightness)
                    Text("A schedule").tag(AdaptiveSettings.Source.schedule)
                }
                LabeledContent("Now") {
                    Text(AdaptiveText.status(controller.statuses[monitor.id] ?? .off, lux: controller.lux,
                                             builtIn: controller.builtInBrightness))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let fallback = effective.fallback {
                    Label(fallback + " Using the schedule.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let curve = settings.curve(for: effective.source) {
                    CurveView(curve: curve, source: effective.source,
                              reading: effective.source == .lightSensor
                                  ? controller.lux.map(BrightnessCurve.lightReading(lux:)) : controller.builtInBrightness,
                              brightness: monitor.brightness.flatMap { control in
                                  control.value.map { $0 / (control.range?.upperBound ?? 100) }
                              })
                        .frame(height: 110)
                        .padding(.vertical, 4)
                }
                Toggle("Learn from my adjustments", isOn: binding(\.learns))
            }
        } header: {
            Text("Automatic brightness")
        } footer: {
            if settings.isEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("Moving the slider takes over until the light changes noticeably, or for half an hour.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Forget What It Learned") { controller.update(monitor.id) { $0.resetLearning() } }
                        .controlSize(.small)
                        .disabled(settings.lightCurve == .lightDefault && settings.followCurve == .followDefault
                                  && settings.schedule.dayBrightness == DaySchedule().dayBrightness
                                  && settings.schedule.nightBrightness == DaySchedule().nightBrightness)
                }
            }
        }
        if settings.isEnabled && effective.source == .schedule || settings.warmsInEvening {
            ScheduleSection(controller: controller, monitor: monitor, showsLevels: settings.isEnabled && effective.source == .schedule)
        }
    }
}

/// When day and night start, and, for the schedule source, how bright each is.
private struct ScheduleSection: View {
    let controller: AdaptiveController
    let monitor: Monitor
    let showsLevels: Bool

    private var schedule: DaySchedule { controller.settings(for: monitor.id).schedule }

    private func update(_ change: @escaping (inout DaySchedule) -> Void) {
        controller.update(monitor.id) { change(&$0.schedule) }
    }

    var body: some View {
        Section("Day and night") {
            DatePicker("Day starts", selection: minuteBinding(\.dayStarts), displayedComponents: .hourAndMinute)
            DatePicker("Night starts", selection: minuteBinding(\.nightStarts), displayedComponents: .hourAndMinute)
            if showsLevels {
                LabeledContent("Day brightness") {
                    PercentSlider(label: "Day brightness", value: schedule.dayBrightness) { value in update { $0.dayBrightness = value } }
                }
                LabeledContent("Night brightness") {
                    PercentSlider(label: "Night brightness", value: schedule.nightBrightness) { value in update { $0.nightBrightness = value } }
                }
            }
        }
    }

    /// Minutes after midnight, as a time today.
    private func minuteBinding(_ keyPath: WritableKeyPath<DaySchedule, Int>) -> Binding<Date> {
        Binding(
            // By the wall clock: seconds added to midnight are an hour off on
            // the day the clocks change.
            get: { DaySchedule.date(atMinute: schedule[keyPath: keyPath], on: Date()) },
            set: { date in
                let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                update { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            }
        )
    }
}

/// A 0–1 setting as a slider and a percentage.
private struct PercentSlider: View {
    let label: String
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { value }, set: { set(($0 * 100).rounded() / 100) }), in: 0.05...1)
                .controlSize(.small)
                .frame(minWidth: 140)
                .accessibilityLabel(label)
                .accessibilityValue(AccessibilityText.percent(value))
            Text("\(Int((value * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: LevelSlider.valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// A warmer picture in the evening, by the day and night times.
struct EveningWarmthSection: View {
    let controller: AdaptiveController
    let monitor: Monitor
    let scale: ColorTemperatureScale
    /// The highest temperature, in 0x0C steps.
    let maximumSteps: Double

    private var settings: AdaptiveSettings { controller.settings(for: monitor.id) }

    private var kelvinRange: ClosedRange<Double> {
        Double(ColorTemperatureScale.base + Int(scale.increment))...Double(ColorTemperatureScale.base + Int(maximumSteps) * Int(scale.increment))
    }

    var body: some View {
        Section {
            Toggle("Warmer in the evening", isOn: Binding(
                get: { settings.warmsInEvening },
                set: { on in controller.update(monitor.id) { $0.warmsInEvening = on } }
            ))
            if settings.warmsInEvening {
                LabeledContent("Evening") {
                    KelvinSlider(label: "Evening temperature", kelvin: settings.nightKelvin, range: kelvinRange, step: Double(scale.increment)) { kelvin in
                        controller.update(monitor.id) { $0.nightKelvin = kelvin }
                    }
                }
                LabeledContent("Day") {
                    KelvinSlider(label: "Day temperature", kelvin: settings.dayKelvin, range: kelvinRange, step: Double(scale.increment)) { kelvin in
                        controller.update(monitor.id) { $0.dayKelvin = kelvin }
                    }
                }
            }
        } header: {
            Text("Evening warmth")
        } footer: {
            if settings.warmsInEvening {
                VStack(alignment: .leading, spacing: 4) {
                    // What warmth is doing right now, when it is not simply done.
                    if let note = AdaptiveText.warmthNote(controller.warmthStatuses[monitor.id]) {
                        Label(note, systemImage: "info.circle")
                    }
                    Text("Set when the night or the day begins. A temperature you pick in between holds until the next change.")
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct KelvinSlider: View {
    let label: String
    let kelvin: Int
    let range: ClosedRange<Double>
    let step: Double
    let set: (Int) -> Void
    @State private var dragging: Double?

    private func snapped(_ value: Double) -> Double {
        guard step > 0 else { return value.rounded() }
        let steps = ((value - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Kept while dragging, saved when the drag ends. Snapped to the
            // monitor's steps by hand: a stepped Slider draws a tick for
            // every one of them.
            Slider(value: Binding(get: { dragging ?? Double(kelvin) }, set: { dragging = snapped($0) }), in: range,
                   onEditingChanged: { editing in
                       if !editing, let dragging {
                           set(Int(dragging))
                           self.dragging = nil
                       }
                   })
                .controlSize(.small)
                .frame(minWidth: 140)
                .accessibilityLabel(label)
                .accessibilityValue(AccessibilityText.kelvin(Int(dragging ?? Double(kelvin))))
            Text("\(Int(dragging ?? Double(kelvin))) K")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: LevelSlider.valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// The learned curve: brightness against the light (log scale) or the
/// MacBook screen, its points, and where the display is now.
struct CurveView: View {
    let curve: BrightnessCurve
    let source: AdaptiveSettings.Source
    /// Where the light is now, on the curve's axis.
    let reading: Double?
    /// The display's brightness now, 0 to 1.
    let brightness: Double?
    @Environment(\.colorSchemeContrast) private var contrast

    private var xRange: ClosedRange<Double> {
        source == .lightSensor ? 0...BrightnessCurve.lightReading(lux: 10_000) : 0...1
    }

    private var ticks: [(x: Double, label: String)] {
        if source == .lightSensor {
            return [(0, "Dark"), (BrightnessCurve.lightReading(lux: 10), "10 lux"),
                    (BrightnessCurve.lightReading(lux: 100), "100"), (BrightnessCurve.lightReading(lux: 1000), "1000"),
                    (BrightnessCurve.lightReading(lux: 10_000), "10 000")]
        }
        return [(0, "MacBook 0%"), (0.5, "50%"), (1, "100%")]
    }

    var body: some View {
        // The drawing closure isn't on the main actor: give it constants.
        let xRange = self.xRange
        let ticks = self.ticks
        let curve = self.curve
        let reading = self.reading
        let brightness = self.brightness
        let gridOpacity = ContrastStyle.gridOpacity(contrast)
        let spoken = [AdaptiveText.curveDescription(curve, source: source),
                      AccessibilityText.curveReading(source: source, reading: reading, brightness: brightness)]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        return VStack(spacing: 4) {
            Canvas { context, size in
                let span = xRange.upperBound - xRange.lowerBound
                func point(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: (x - xRange.lowerBound) / span * size.width, y: (1 - y) * size.height)
                }
                // The grid.
                var grid = Path()
                for tick in ticks {
                    grid.move(to: point(tick.x, 0))
                    grid.addLine(to: point(tick.x, 1))
                }
                for level in [0.0, 0.5, 1.0] {
                    grid.move(to: point(xRange.lowerBound, level))
                    grid.addLine(to: point(xRange.upperBound, level))
                }
                context.stroke(grid, with: .color(.secondary.opacity(gridOpacity)), lineWidth: 0.5)
                // The curve.
                var line = Path()
                let samples = 80
                for index in 0...samples {
                    let x = xRange.lowerBound + span * Double(index) / Double(samples)
                    let at = point(x, curve.brightness(at: x))
                    if index == 0 { line.move(to: at) } else { line.addLine(to: at) }
                }
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // Its points, and where the display is now.
                for curvePoint in curve.points {
                    let at = point(min(max(curvePoint.x, xRange.lowerBound), xRange.upperBound), curvePoint.y)
                    context.fill(Path(ellipseIn: CGRect(x: at.x - 2.5, y: at.y - 2.5, width: 5, height: 5)), with: .color(.accentColor))
                }
                if let reading, let brightness {
                    let at = point(min(max(reading, xRange.lowerBound), xRange.upperBound), brightness)
                    context.stroke(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(.primary), lineWidth: 1.5)
                }
            }
            GeometryReader { proxy in
                ForEach(ticks, id: \.label) { tick in
                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max((tick.x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * proxy.size.width, 18),
                                         proxy.size.width - 18),
                                  y: proxy.size.height / 2)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Brightness curve")
        .accessibilityValue(spoken)
    }
}

/// How the app puts automatic brightness into words.
enum AdaptiveText {
    /// Why evening warmth is not showing its temperature, or nil when there
    /// is nothing to explain.
    static func warmthNote(_ status: WarmthStatus?) -> String? {
        switch status {
        case .waitingForPreset:
            "Waiting: the current color preset has no temperature. Pick a Kelvin preset to let warmth apply."
        case .heldByUser:
            "Keeping the temperature you set until the next change."
        case .retrying:
            "The display hasn't taken the temperature yet. Glim will try again."
        case .off, .applying, .applied, nil:
            nil
        }
    }

    static func status(_ status: AdaptiveStatus, lux: Double?, builtIn: Double?) -> String {
        switch status {
        case .off:
            return "Off"
        case .waiting:
            return "Waiting for the display"
        case .paused:
            return "Paused: you set it by hand"
        case .following(let source, let target, _):
            let percent = "\(Int((target * 100).rounded()))%"
            switch source {
            case .lightSensor:
                return lux.map { "\(Int($0.rounded())) lux → \(percent)" } ?? percent
            case .followBuiltIn:
                return builtIn.map { "MacBook \(Int(($0 * 100).rounded()))% → \(percent)" } ?? percent
            case .schedule:
                return "Schedule → \(percent)"
            }
        }
    }

    static func curveDescription(_ curve: BrightnessCurve, source: AdaptiveSettings.Source) -> String {
        let first = curve.points.first?.y ?? 0
        let last = curve.points.last?.y ?? 1
        let from = source == .lightSensor ? "in the dark" : "with the MacBook screen off"
        return "\(Int((first * 100).rounded()))% \(from), up to \(Int((last * 100).rounded()))%, \(curve.points.count) points"
    }
}
