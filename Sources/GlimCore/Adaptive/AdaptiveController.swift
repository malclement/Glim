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

/// What evening warmth is doing for one display.
public enum WarmthStatus: Equatable, Sendable {
    case off
    /// Moving to the period's temperature (`kelvin`), not yet confirmed by
    /// the display.
    case applying(kelvin: Int)
    /// The display reads back the period's temperature.
    case applied(kelvin: Int)
    /// The active color preset (sRGB, native, custom RGB) has no
    /// temperature, so warmth leaves the display alone until one exists.
    case waitingForPreset
    /// The temperature was set by hand; it holds until the period changes.
    case heldByUser
    /// The display did not take the last attempt; trying again after a pause.
    case retrying
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
    /// Evening warmth per display. A display without an entry has it off.
    public private(set) var warmthStatuses: [String: WarmthStatus] = [:]
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
    /// Consecutive reads that came back empty while the source was wanted.
    @ObservationIgnored private var lightMisses = 0
    @ObservationIgnored private var builtInMisses = 0
    @ObservationIgnored private var nextFadeID = 0

    /// How long to wait before trying evening warmth again on a display that
    /// did not take it.
    static let warmthRetryInterval: TimeInterval = 30
    /// Empty reads in a row before a reading is dropped.
    static let missesBeforeStale = 2

    private enum FadeSlot { case brightness, warmth }

    /// A running fade; `id` tells it from the one that replaced it.
    private struct Fade {
        var id: Int
        var task: Task<Void, Never>
    }

    /// What the controller remembers about a display between ticks.
    private struct Runtime {
        // Weak, compared with ===: an address can be reused after a
        // reconnect, an identity cannot.
        weak var control: DeviceControl<Double>?
        var seenUserChanges = 0
        var seenSceneChanges = 0
        var paused: (at: Date, source: AdaptiveSettings.Source, reading: Double?, period: DaySchedule.Period)?
        var pendingLearning = false
        var candidateTicks = 0
        var applyNow = true
        var fade: Fade?
        weak var warmthControl: DeviceControl<Double>?
        var warmthSeenUserChanges = 0
        /// The period whose temperature is confirmed on the display, or was
        /// set by hand.
        var warmthDone: DaySchedule.Period?
        /// The period the attempts and a hold below belong to.
        var warmthCycle: DaySchedule.Period?
        var warmthHeld = false
        var warmthLastAttempt: Date?
        var warmthFade: Fade?
    }

    public init(manager: MonitorManager, environment: any AdaptiveEnvironment, settings: [String: AdaptiveSettings] = [:],
                timing: AdaptiveTiming = .standard, save: @escaping ([String: AdaptiveSettings]) -> Void = { _ in }) {
        self.manager = manager
        self.environment = environment
        self.settings = settings
        self.timing = timing
        self.save = save
        observeMonitors()
    }

    /// Re-evaluates the loop when displays come or go, without polling for it.
    private func observeMonitors() {
        withObservationTracking {
            _ = manager.monitors
        } onChange: { [weak self] in
            Task { @MainActor in self?.monitorsChanged() }
        }
    }

    private func monitorsChanged() {
        observeMonitors()
        prune()
        updateLoop()
    }

    private var connectedIDs: Set<String> { Set(manager.monitors.map(\.id)) }

    /// Forgets displays that are gone.
    private func prune() {
        let connected = connectedIDs
        for id in runtime.keys where !connected.contains(id) {
            cancelFades(of: id)
            runtime[id] = nil
        }
        for id in statuses.keys where !connected.contains(id) { statuses[id] = nil }
        for id in warmthStatuses.keys where !connected.contains(id) { warmthStatuses[id] = nil }
    }

    private func cancelFades(of id: String) {
        runtime[id]?.fade?.task.cancel()
        runtime[id]?.fade = nil
        runtime[id]?.warmthFade?.task.cancel()
        runtime[id]?.warmthFade = nil
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
            // Fresh start: whatever the user did meanwhile is not a takeover.
            state.control = nil
            state.pendingLearning = false
            state.candidateTicks = 0
        }
        if new.warmsInEvening != old.warmsInEvening || new.nightKelvin != old.nightKelvin
            || new.dayKelvin != old.dayKelvin || new.schedule != old.schedule {
            state.warmthControl = nil
            state.warmthCycle = nil
            state.warmthDone = nil
            state.warmthHeld = false
            state.warmthLastAttempt = nil
            state.warmthFade?.task.cancel()
            state.warmthFade = nil
        }
        if !new.isEnabled {
            state.fade?.task.cancel()
            state.fade = nil
        }
        runtime[monitorID] = state
        if !new.isEnabled, statuses[monitorID] != .off { statuses[monitorID] = .off }
        if !new.warmsInEvening, let status = warmthStatuses[monitorID], status != .off { warmthStatuses[monitorID] = .off }
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
        for id in runtime.keys { cancelFades(of: id) }
    }

    /// The displays went to sleep (true) or woke (false). Nothing is read
    /// while they sleep; on wake every display catches up at once.
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            stop()
            // Nothing read before sleep says what the room is like now.
            lightReading = nil
            builtInReading = nil
            lightMisses = 0
            builtInMisses = 0
            publish(\.lux, nil)
            publish(\.builtInBrightness, nil)
        } else {
            for id in runtime.keys {
                runtime[id]?.applyNow = true
                // The display may have come back at another temperature:
                // confirm it again, unless the user chose it.
                if runtime[id]?.warmthHeld == false {
                    runtime[id]?.warmthDone = nil
                    runtime[id]?.warmthLastAttempt = nil
                }
            }
            updateLoop()
        }
    }

    public var isRunning: Bool { loop != nil }

    private var isNeeded: Bool {
        let connected = connectedIDs
        return settings.contains { connected.contains($0.key) && ($0.value.isEnabled || $0.value.warmsInEvening) }
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
        prune()
        let connected = connectedIDs
        let enabled = settings.filter { connected.contains($0.key) && $0.value.isEnabled }
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
            if settings.warmsInEvening {
                adjustWarmth(of: monitor, settings, now: now)
            } else if let status = warmthStatuses[monitor.id], status != .off {
                setWarmthStatus(.off, for: monitor.id)
            }
        }
    }

    /// Reads only the sources an enabled display uses. With none, nothing
    /// touches the sensor.
    private func readSources(for enabled: Dictionary<String, AdaptiveSettings>.Values) {
        let wantsLight = enabled.contains { $0.source == .lightSensor } && environment.hasLightSensor && !isLidClosed
        if wantsLight {
            if let lux = environment.lux() {
                let reading = BrightnessCurve.lightReading(lux: lux)
                let smoothed = lightReading.map { $0 + timing.smoothing * (reading - $0) } ?? reading
                lightReading = smoothed
                lightMisses = 0
                publish(\.lux, (pow(10, smoothed) - 1).rounded())
            } else {
                // One empty read is a glitch; a few are a sensor that stopped.
                lightMisses += 1
                if lightMisses >= Self.missesBeforeStale {
                    lightReading = nil
                    publish(\.lux, nil)
                }
            }
        } else {
            lightMisses = 0
            lightReading = nil
            publish(\.lux, nil)
        }
        let wantsBuiltIn = enabled.contains { $0.source == .followBuiltIn } && environment.hasBuiltInBrightness && !isLidClosed
        if wantsBuiltIn {
            if let brightness = environment.builtInBrightness() {
                let smoothed = builtInReading.map { $0 + timing.smoothing * (brightness - $0) } ?? brightness
                builtInReading = smoothed
                builtInMisses = 0
                publish(\.builtInBrightness, (smoothed * 100).rounded() / 100)
            } else {
                builtInMisses += 1
                if builtInMisses >= Self.missesBeforeStale {
                    builtInReading = nil
                    publish(\.builtInBrightness, nil)
                }
            }
        } else {
            builtInMisses = 0
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

    private func setWarmthStatus(_ status: WarmthStatus, for monitorID: String) {
        if warmthStatuses[monitorID] != status { warmthStatuses[monitorID] = status }
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
        // A display that isn't answering (just woke, or being set up again)
        // would only fail the write and hold its channel; catch up once ready.
        guard monitor.status == .ready else {
            state.applyNow = true
            setStatus(.waiting, for: monitor.id)
            return
        }
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
        if state.control !== control {
            state.control = control
            state.seenUserChanges = control.userChanges
            state.seenSceneChanges = control.sceneChanges
            state.applyNow = true
        } else if control.userChanges != state.seenUserChanges {
            // Applying a scene is the user taking over, but says nothing
            // about what the light calls for: pause, don't learn.
            let byHand = (control.userChanges &- state.seenUserChanges) > (control.sceneChanges &- state.seenSceneChanges)
            state.seenUserChanges = control.userChanges
            state.seenSceneChanges = control.sceneChanges
            state.fade?.task.cancel()
            state.fade = nil
            state.paused = (now, settings.source, reading, period)
            state.pendingLearning = settings.learns && byHand
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
            // The chosen source, not the effective one: closing the lid turns
            // the sensor into the schedule, and must not undo a manual level.
            let sourceChanged = paused.source != settings.source
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
            if difference >= 0.005 { startFade(&state.fade, control, to: target * maximum, slot: .brightness, monitorID: monitor.id) }
        } else if difference >= timing.threshold {
            state.candidateTicks += 1
            if state.candidateTicks >= timing.dwellTicks {
                state.candidateTicks = 0
                startFade(&state.fade, control, to: target * maximum, slot: .brightness, monitorID: monitor.id)
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
        Log.state.info("learned \(String(format: "%.2f", brightness), privacy: .public) at \(String(describing: reading), privacy: .public) for \(source.rawValue, privacy: .public)")
        settings[monitorID] = new
        save(settings)
    }

    /// Replaces whatever fade is in `slot` with a new one.
    private func startFade(_ current: inout Fade?, _ control: DeviceControl<Double>, to target: Double,
                           slot: FadeSlot, monitorID: String) {
        current?.task.cancel()
        current = fade(control, to: target, slot: slot, monitorID: monitorID)
    }

    /// Moves a level to `target` in small steps, through the control so
    /// writes stay coalesced and the slider shows what happens. Stops the
    /// moment the user takes over. A temperature never fades from 0, which
    /// is not a temperature but "this preset has none": it is written once.
    private func fade(_ control: DeviceControl<Double>, to target: Double, slot: FadeSlot, monitorID: String) -> Fade? {
        guard let start = control.value else { return nil }
        nextFadeID += 1
        let id = nextFadeID
        let jump = slot == .warmth && start <= 0
        let steps = jump ? 1 : max(1, timing.fadeSteps)
        let pause = timing.fadeDuration / steps
        let userChanges = control.userChanges
        let task = Task { [weak self, weak control] in
            for step in 1...steps {
                guard let control, !Task.isCancelled, control.userChanges == userChanges, !control.isEditing else { break }
                control.set(jump ? target : start + (target - start) * Double(step) / Double(steps), origin: .automatic)
                if step != steps, pause > .zero {
                    do { try await Task.sleep(for: pause) } catch { break }
                }
            }
            self?.finishFade(id: id, slot: slot, monitorID: monitorID)
        }
        return Fade(id: id, task: task)
    }

    /// A fade clears its own slot, and only while it is still the current one.
    private func finishFade(id: Int, slot: FadeSlot, monitorID: String) {
        switch slot {
        case .brightness:
            if runtime[monitorID]?.fade?.id == id { runtime[monitorID]?.fade = nil }
        case .warmth:
            if runtime[monitorID]?.warmthFade?.id == id { runtime[monitorID]?.warmthFade = nil }
        }
    }

    // MARK: Warmth

    /// Sets the evening or day temperature when the period changes, not on
    /// every tick, so a temperature set by hand holds until the next change.
    /// The period counts as done only once the display reads the target
    /// back; until then it is tried again, at most every
    /// ``warmthRetryInterval``.
    private func adjustWarmth(of monitor: Monitor, _ settings: AdaptiveSettings, now: Date) {
        guard monitor.status == .ready, let control = monitor.colorTemperature, let value = control.value,
              let scale = monitor.profile.colorTemperature, scale.increment > 0 else { return }
        var state = runtime[monitor.id] ?? Runtime()
        defer { runtime[monitor.id] = state }
        let period = settings.schedule.period(at: now)
        let kelvin = period == .day ? settings.dayKelvin : settings.nightKelvin
        let steps = (Double(kelvin - ColorTemperatureScale.base) / Double(scale.increment)).rounded()
        let target = max(1, steps)

        if state.warmthControl !== control {
            // First sight, or a reconnect: the display may be anywhere.
            state.warmthControl = control
            state.warmthSeenUserChanges = control.userChanges
            state.warmthDone = nil
            state.warmthHeld = false
            state.warmthLastAttempt = nil
            state.warmthFade?.task.cancel()
            state.warmthFade = nil
        } else if control.userChanges != state.warmthSeenUserChanges {
            state.warmthSeenUserChanges = control.userChanges
            state.warmthFade?.task.cancel()
            state.warmthFade = nil
            state.warmthHeld = true
            state.warmthDone = period
            state.warmthCycle = period
        }
        if state.warmthCycle != period {
            // A new period ends a hold and starts counting attempts afresh.
            state.warmthCycle = period
            state.warmthHeld = false
            state.warmthLastAttempt = nil
        }

        // No temperature in the active preset: leave the preset alone.
        guard value > 0 else {
            setWarmthStatus(.waitingForPreset, for: monitor.id)
            return
        }
        if state.warmthHeld {
            setWarmthStatus(.heldByUser, for: monitor.id)
            return
        }
        if state.warmthDone == period {
            setWarmthStatus(.applied(kelvin: kelvin), for: monitor.id)
            return
        }
        guard state.warmthFade == nil else { return }

        let reads = control.deviceValue.map { abs($0 - target) <= 1 } ?? false
        if reads, abs(value - target) <= 1, !control.isWriting, control.failure == nil {
            state.warmthDone = period
            setWarmthStatus(.applied(kelvin: kelvin), for: monitor.id)
            return
        }
        if let last = state.warmthLastAttempt {
            guard now.timeIntervalSince(last) >= Self.warmthRetryInterval else { return }
            setWarmthStatus(.retrying, for: monitor.id)
        } else {
            setWarmthStatus(.applying(kelvin: kelvin), for: monitor.id)
        }
        state.warmthLastAttempt = now
        startFade(&state.warmthFade, control, to: target, slot: .warmth, monitorID: monitor.id)
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
