import Foundation
import Observation

public struct AdaptiveTiming: Sendable {
    /// How often the light is read while some display adjusts by itself, or
    /// nil for no timer at all: tests call ``AdaptiveController/tick()``.
    public var interval: Duration? = .seconds(2)
    /// Weight of a new reading in the running average, in log space.
    public var smoothing = 0.35
    /// A change smaller than this, as a fraction of the range, is ignored.
    public var threshold = 0.10
    /// Ticks a change must last before it is followed.
    public var dwellTicks = 2
    /// A fade to a new level, and how many steps it takes.
    public var fadeDuration: Duration = .milliseconds(1800)
    public var fadeSteps = 12
    /// After a manual change, automatic adjustment waits this long at most…
    public var pauseTimeout: Duration = .seconds(30 * 60)
    /// …or until the reading moves this far from where it was (log10 lux:
    /// 0.3 is twice or half the light).
    public var resumeLightDistance = 0.3
    public var resumeFollowDistance = 0.15

    public init() {}

    public static let standard = AdaptiveTiming()
}

/// What automatic brightness is doing for one display.
public enum AdaptiveStatus: Equatable, Sendable {
    case off
    /// Following `source`. `fallback` says why it isn't the chosen one.
    case following(source: AdaptiveSettings.Source, target: Double, fallback: String?)
    /// The user set the brightness by hand; it resumes when the light
    /// changes noticeably, or after a while.
    case paused
    /// The display has no brightness Glim can set, or hasn't been read yet.
    case waiting
}

/// Sets each display's brightness from the light in the room, the MacBook
/// screen or the clock, and warms it in the evening.
///
/// **Cost.** Nothing runs unless a display has automatic brightness or
/// evening warmth on. Then a reading every ``AdaptiveTiming/interval``, and
/// the sensor is read only for displays that use it. A level that holds
/// sends no DDC traffic at all.
///
/// **The user wins.** Any change from the slider, the menu or a scene pauses
/// the display, and, with learning on, bends its curve through what was
/// chosen. It resumes when the light changes noticeably, or after a while.
@MainActor
@Observable
public final class AdaptiveController {
    public private(set) var settings: [String: AdaptiveSettings]
    public private(set) var statuses: [String: AdaptiveStatus] = [:]
    // What views show. Each is assigned only when it changes, and rounded to
    // what is shown: Observation notifies on every assignment, equal or not,
    // and a steady light must not redraw the window every tick.

    /// The smoothed light, in whole lux, while something reads it.
    public private(set) var lux: Double?
    /// The smoothed built-in brightness, in hundredths, while something
    /// follows it.
    public private(set) var builtInBrightness: Double?
    public private(set) var isLidClosed = false

    @ObservationIgnored private let manager: MonitorManager
    @ObservationIgnored public let environment: any AdaptiveEnvironment
    @ObservationIgnored private let timing: AdaptiveTiming
    @ObservationIgnored private let save: ([String: AdaptiveSettings]) -> Void
    @ObservationIgnored private var runtime: [String: Runtime] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var lightReading: Double?
    @ObservationIgnored private var builtInReading: Double?

    /// What the controller remembers about a display between ticks.
    private struct Runtime {
        var control: ObjectIdentifier?
        var seenUserChanges = 0
        var paused: (at: Date, source: AdaptiveSettings.Source, reading: Double?, period: DaySchedule.Period)?
        var pendingLearning = false
        var candidateTicks = 0
        var applyNow = true
        var fade: Task<Void, Never>?
        var warmthPeriod: DaySchedule.Period?
        var warmthFade: Task<Void, Never>?
    }

    public init(manager: MonitorManager, environment: any AdaptiveEnvironment, settings: [String: AdaptiveSettings] = [:],
                timing: AdaptiveTiming = .standard, save: @escaping ([String: AdaptiveSettings]) -> Void = { _ in }) {
        self.manager = manager
        self.environment = environment
        self.settings = settings
        self.timing = timing
        self.save = save
    }

    // MARK: Settings

    public func settings(for monitorID: String) -> AdaptiveSettings {
        monitorValue(in: settings, for: monitorID) ?? AdaptiveSettings()
    }

    /// Changes a display's settings, applies them at once and keeps them.
    public func update(_ monitorID: String, _ change: (inout AdaptiveSettings) -> Void) {
        var new = settings(for: monitorID)
        let old = new
        change(&new)
        guard new != old else { return }
        settings[monitorID] = new
        save(settings)
        var state = runtime[monitorID] ?? Runtime()
        if new.isEnabled != old.isEnabled || new.source != old.source {
            state.paused = nil
            state.applyNow = true
        }
        if new.warmsInEvening != old.warmsInEvening || new.nightKelvin != old.nightKelvin
            || new.dayKelvin != old.dayKelvin || new.schedule != old.schedule {
            state.warmthPeriod = nil
        }
        if !new.isEnabled { state.fade?.cancel() }
        runtime[monitorID] = state
        if !new.isEnabled { statuses[monitorID] = .off }
        updateLoop()
        tick()
    }

    /// Which source a display really uses now, and why, if not its own.
    public func effectiveSource(for monitorID: String) -> (source: AdaptiveSettings.Source, fallback: String?) {
        effectiveSource(settings(for: monitorID).source)
    }

    private func effectiveSource(_ chosen: AdaptiveSettings.Source) -> (source: AdaptiveSettings.Source, fallback: String?) {
        switch chosen {
        case .lightSensor:
            if !environment.hasLightSensor { return (.schedule, "This Mac's light sensor can't be read.") }
            if isLidClosed { return (.schedule, "The lid is closed, so the light sensor is covered.") }
            if lightReading == nil { return (.schedule, "The light sensor isn't answering.") }
        case .followBuiltIn:
            if !environment.hasBuiltInBrightness { return (.schedule, "The MacBook screen's brightness can't be read.") }
            if isLidClosed { return (.schedule, "The lid is closed, so the MacBook screen is off.") }
            if builtInReading == nil { return (.schedule, "The MacBook screen is off.") }
        case .schedule:
            break
        }
        return (chosen, nil)
    }

    // MARK: Running

    /// Starts reading if some display needs it.
    public func start() {
        isSuspended = false
        updateLoop()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        for state in runtime.values {
            state.fade?.cancel()
            state.warmthFade?.cancel()
        }
    }

    /// The displays went to sleep (true) or woke (false). Nothing is read
    /// while they sleep; on wake every display catches up at once.
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            stop()
        } else {
            for id in runtime.keys { runtime[id]?.applyNow = true }
            updateLoop()
        }
    }

    public var isRunning: Bool { loop != nil }

    private var isNeeded: Bool {
        settings.values.contains { $0.isEnabled || $0.warmsInEvening }
    }

    private func updateLoop() {
        guard isNeeded, !isSuspended else {
            loop?.cancel()
            loop = nil
            return
        }
        guard loop == nil, let interval = timing.interval else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    // MARK: One evaluation

    /// Reads what is needed and moves every display that should move. The
    /// loop calls it; tests call it directly.
    public func tick() {
        guard !isSuspended else { return }
        let enabled = settings.filter { $0.value.isEnabled }
        let lidClosed = environment.isLidClosed()
        if lidClosed != isLidClosed { isLidClosed = lidClosed }
        readSources(for: enabled.values)
        let now = environment.now()
        for monitor in manager.monitors {
            let settings = self.settings(for: monitor.id)
            if settings.isEnabled {
                adjustBrightness(of: monitor, settings, now: now)
            } else if statuses[monitor.id] != nil, statuses[monitor.id] != .off {
                setStatus(.off, for: monitor.id)
            }
            if settings.warmsInEvening { adjustWarmth(of: monitor, settings, now: now) }
        }
    }

    /// Reads only the sources an enabled display uses. With none, nothing
    /// touches the sensor.
    private func readSources(for enabled: Dictionary<String, AdaptiveSettings>.Values) {
        let wantsLight = enabled.contains { $0.source == .lightSensor } && environment.hasLightSensor && !isLidClosed
        if wantsLight, let lux = environment.lux() {
            let reading = BrightnessCurve.lightReading(lux: lux)
            let smoothed = lightReading.map { $0 + timing.smoothing * (reading - $0) } ?? reading
            lightReading = smoothed
            publish(\.lux, (pow(10, smoothed) - 1).rounded())
        } else if !wantsLight {
            lightReading = nil
            publish(\.lux, nil)
        }
        let wantsBuiltIn = enabled.contains { $0.source == .followBuiltIn } && environment.hasBuiltInBrightness && !isLidClosed
        if wantsBuiltIn, let brightness = environment.builtInBrightness() {
            let smoothed = builtInReading.map { $0 + timing.smoothing * (brightness - $0) } ?? brightness
            builtInReading = smoothed
            publish(\.builtInBrightness, (smoothed * 100).rounded() / 100)
        } else if !wantsBuiltIn {
            builtInReading = nil
            publish(\.builtInBrightness, nil)
        }
    }

    private func publish(_ keyPath: ReferenceWritableKeyPath<AdaptiveController, Double?>, _ value: Double?) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Statuses carry the target in hundredths, as shown.
    private func setStatus(_ status: AdaptiveStatus, for monitorID: String) {
        var status = status
        if case .following(let source, let target, let fallback) = status {
            status = .following(source: source, target: (target * 100).rounded() / 100, fallback: fallback)
        }
        if statuses[monitorID] != status { statuses[monitorID] = status }
    }

    /// The reading a source's curve takes, nil for the schedule.
    private func reading(for source: AdaptiveSettings.Source) -> Double? {
        switch source {
        case .lightSensor: lightReading
        case .followBuiltIn: builtInReading
        case .schedule: nil
        }
    }

    private func adjustBrightness(of monitor: Monitor, _ settings: AdaptiveSettings, now: Date) {
        var state = runtime[monitor.id] ?? Runtime()
        defer { runtime[monitor.id] = state }
        guard let control = monitor.brightness, let value = control.value, let maximum = control.range?.upperBound,
              maximum > 0 else {
            setStatus(.waiting, for: monitor.id)
            return
        }
        let (source, fallback) = effectiveSource(settings.source)
        let reading = reading(for: source)
        let period = settings.schedule.period(at: now)

        // A new control (a reconnect) starts afresh; a change by the user
        // pauses, and is learned once the drag is over.
        if state.control != ObjectIdentifier(control) {
            state.control = ObjectIdentifier(control)
            state.seenUserChanges = control.userChanges
            state.applyNow = true
        } else if control.userChanges != state.seenUserChanges {
            state.seenUserChanges = control.userChanges
            state.fade?.cancel()
            state.paused = (now, source, reading, period)
            state.pendingLearning = settings.learns
            state.candidateTicks = 0
        }
        if state.pendingLearning, !control.isEditing, !control.isWriting {
            state.pendingLearning = false
            learn(monitor.id, source: source, reading: reading, period: period, brightness: value / maximum)
        }

        if let paused = state.paused {
            let distance = timing.resumeDistance(for: source)
            let lightMoved = zip2(paused.reading, reading).map { abs($0 - $1) >= distance } ?? false
            let expired = paused.at.distance(to: now) >= timing.pauseTimeout.seconds
            let sourceChanged = paused.source != source
            let periodChanged = source == .schedule && paused.period != period
            guard lightMoved || expired || sourceChanged || periodChanged else {
                setStatus(.paused, for: monitor.id)
                return
            }
            state.paused = nil
            state.applyNow = true
        }

        let curveSettings = self.settings(for: monitor.id)
        let target: Double = if let reading, let curve = curveSettings.curve(for: source) {
            curve.brightness(at: reading)
        } else {
            curveSettings.schedule.brightness(at: now)
        }
        setStatus(.following(source: source, target: target, fallback: fallback), for: monitor.id)
        guard !control.isEditing, state.fade == nil || state.applyNow else { return }

        let difference = abs(target - value / maximum)
        if state.applyNow {
            state.applyNow = false
            state.candidateTicks = 0
            if difference >= 0.005 { state.fade = fade(control, to: target * maximum, monitorID: monitor.id) }
        } else if difference >= timing.threshold {
            state.candidateTicks += 1
            if state.candidateTicks >= timing.dwellTicks {
                state.candidateTicks = 0
                state.fade = fade(control, to: target * maximum, monitorID: monitor.id)
            }
        } else {
            state.candidateTicks = 0
        }
    }

    private func learn(_ monitorID: String, source: AdaptiveSettings.Source, reading: Double?, period: DaySchedule.Period,
                       brightness: Double) {
        var new = settings(for: monitorID)
        switch source {
        case .lightSensor:
            guard let reading else { return }
            new.lightCurve.learn(x: reading, y: brightness)
        case .followBuiltIn:
            guard let reading else { return }
            new.followCurve.learn(x: reading, y: brightness)
        case .schedule:
            if period == .day { new.schedule.dayBrightness = brightness } else { new.schedule.nightBrightness = brightness }
        }
        Log.state.info("learned \(String(format: "%.2f", brightness)) at \(String(describing: reading)) for \(source.rawValue, privacy: .public)")
        settings[monitorID] = new
        save(settings)
    }

    /// Moves a level to `target` in small steps, through the control so
    /// writes stay coalesced and the slider shows what happens. Stops the
    /// moment the user takes over.
    private func fade(_ control: DeviceControl<Double>, to target: Double, monitorID: String) -> Task<Void, Never>? {
        guard let start = control.value else { return nil }
        let steps = max(1, timing.fadeSteps)
        let pause = timing.fadeDuration / steps
        let userChanges = control.userChanges
        return Task { [weak self, weak control] in
            for step in 1...steps {
                guard let control, !Task.isCancelled, control.userChanges == userChanges, !control.isEditing else { break }
                control.set(start + (target - start) * Double(step) / Double(steps), automatic: true)
                if step != steps, pause > .zero {
                    do { try await Task.sleep(for: pause) } catch { break }
                }
            }
            self?.runtime[monitorID]?.fade = nil
        }
    }

    // MARK: Warmth

    /// Sets the evening or day temperature when the period changes, not on
    /// every tick, so a temperature set by hand holds until the next change.
    private func adjustWarmth(of monitor: Monitor, _ settings: AdaptiveSettings, now: Date) {
        guard let control = monitor.colorTemperature, control.value != nil,
              let scale = monitor.profile.colorTemperature, scale.increment > 0 else { return }
        let period = settings.schedule.period(at: now)
        guard runtime[monitor.id]?.warmthPeriod != period else { return }
        var state = runtime[monitor.id] ?? Runtime()
        state.warmthPeriod = period
        let kelvin = period == .day ? settings.dayKelvin : settings.nightKelvin
        let steps = (Double(kelvin - ColorTemperatureScale.base) / Double(scale.increment)).rounded()
        state.warmthFade?.cancel()
        state.warmthFade = fade(control, to: max(1, steps), monitorID: monitor.id)
        runtime[monitor.id] = state
        Log.state.info("\(monitor.name, privacy: .public): \(period == .day ? "day" : "evening", privacy: .public) temperature \(kelvin) K")
    }
}

extension AdaptiveTiming {
    func resumeDistance(for source: AdaptiveSettings.Source) -> Double {
        source == .followBuiltIn ? resumeFollowDistance : resumeLightDistance
    }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
