import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

// MARK: - Pure functions

@Suite struct BrightnessCurveTests {
    private func lux(_ lux: Double) -> Double { BrightnessCurve.lightReading(lux: lux) }

    @Test func theDefaultRunsFromDimToFullOverLogLux() {
        let curve = BrightnessCurve.lightDefault
        #expect(curve.brightness(at: lux(0)) == 0.20)
        #expect(abs(curve.brightness(at: lux(1000)) - 1) < 1e-9)
        #expect(curve.brightness(at: lux(50_000)) == 1)
        // A dim room (10 lux) is about half; an office (380 lux) most of it.
        #expect(abs(curve.brightness(at: lux(10)) - 0.477) < 0.01)
        #expect(abs(curve.brightness(at: lux(380)) - 0.886) < 0.01)
    }

    @Test func learningPassesThroughThePointAndStaysMonotonic() {
        var curve = BrightnessCurve.lightDefault
        curve.learn(x: lux(10), y: 0.3)
        #expect(abs(curve.brightness(at: lux(10)) - 0.3) < 1e-9)
        // Dimmer below it stays below 0.3; brighter above stays above.
        #expect(curve.brightness(at: lux(0)) <= 0.3)
        #expect(curve.brightness(at: lux(1000)) == 1)

        // A choice that contradicts the curve pulls its neighbours along.
        curve.learn(x: lux(500), y: 0.25)
        #expect(curve.brightness(at: lux(10)) <= 0.25)
        for (left, right) in zip(curve.points, curve.points.dropFirst()) {
            #expect(left.x < right.x && left.y <= right.y)
        }
    }

    @Test func choicesAtAboutTheSameLightReplaceEachOther() {
        var curve = BrightnessCurve.lightDefault
        curve.learn(x: 1.00, y: 0.4)
        curve.learn(x: 1.05, y: 0.6)
        #expect(curve.points.count == 3)
        #expect(curve.brightness(at: 1.05) == 0.6)
    }

    @Test func theCurveKeepsAFewPointsAndTheNewest() {
        var curve = BrightnessCurve.followDefault
        for step in 0..<40 { curve.learn(x: Double(step) * 0.025, y: Double(step) / 40) }
        #expect(curve.points.count <= BrightnessCurve.maximumPoints)
        #expect(curve.points.contains { abs($0.x - 0.975) < 1e-9 })
    }
}

@Suite struct DayScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: hour, minute: minute))!
    }

    @Test func dayAndNightWithAHalfHourRamp() {
        let schedule = DaySchedule()     // day 07:00, night 21:00
        #expect(schedule.period(at: at(12), calendar: calendar) == .day)
        #expect(schedule.period(at: at(23), calendar: calendar) == .night)
        #expect(schedule.period(at: at(3), calendar: calendar) == .night)
        #expect(schedule.brightness(at: at(12), calendar: calendar) == schedule.dayBrightness)
        #expect(schedule.brightness(at: at(23), calendar: calendar) == schedule.nightBrightness)
        let halfway = (schedule.dayBrightness + schedule.nightBrightness) / 2
        #expect(abs(schedule.brightness(at: at(21, 15), calendar: calendar) - halfway) < 1e-9)
        #expect(abs(schedule.brightness(at: at(7, 15), calendar: calendar) - halfway) < 1e-9)
    }

    @Test func aNightThatStartsAfterMidnight() {
        var schedule = DaySchedule()
        schedule.dayStarts = 9 * 60
        schedule.nightStarts = 1 * 60      // 01:00
        #expect(schedule.period(at: at(23, 30), calendar: calendar) == .day)
        #expect(schedule.period(at: at(2), calendar: calendar) == .night)
    }

    /// "Minutes after midnight" is a wall-clock time: on the day the clocks
    /// go forward, 03:30 is 03:30, not an hour later.
    @Test func aTimeOfDayIsRightOnADaylightSavingChangeDay() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let changeDay = try #require(paris.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let moment = DaySchedule.date(atMinute: 3 * 60 + 30, on: changeDay, calendar: paris)
        let parts = paris.dateComponents([.day, .hour, .minute], from: moment)
        #expect(parts.day == 29 && parts.hour == 3 && parts.minute == 30)
        // What the plain sum gives, for the record.
        let naive = paris.startOfDay(for: changeDay).addingTimeInterval(Double(3 * 60 + 30) * 60)
        #expect(paris.component(.hour, from: naive) == 4)

        let schedule = DaySchedule()
        #expect(schedule.period(at: moment, calendar: paris) == .night)
        let evening = DaySchedule.date(atMinute: 21 * 60, on: changeDay, calendar: paris)
        #expect(schedule.period(at: evening.addingTimeInterval(-60), calendar: paris) == .day)
        #expect(schedule.period(at: evening, calendar: paris) == .night)
    }

    /// With no night between them the schedule has nothing to switch to: day.
    @Test func equalDayAndNightTimesMeanAlwaysDay() {
        var schedule = DaySchedule()
        schedule.dayStarts = 8 * 60
        schedule.nightStarts = 8 * 60
        for hour in [0, 3, 8, 12, 20, 23] {
            #expect(schedule.period(at: at(hour), calendar: calendar) == .day)
            #expect(schedule.brightness(at: at(hour), calendar: calendar) == schedule.dayBrightness)
        }
    }
}

// MARK: - The controller

@Suite @MainActor struct AdaptiveControllerTests {
    private func timing() -> AdaptiveTiming {
        var timing = AdaptiveTiming()
        timing.interval = nil
        timing.fadeDuration = .zero
        timing.smoothing = 1          // no averaging unless a test asks
        return timing
    }

    private func setUp(timing: AdaptiveTiming? = nil, hour: Int = 12)
        async throws -> (AdaptiveController, ScriptedEnvironment, Monitor, SimulatedDisplay, MonitorManager) {
        let (controller, environment, monitor, display, manager, _) = try await setUpWithPlatform(timing: timing, hour: hour)
        return (controller, environment, monitor, display, manager)
    }

    private func setUpWithPlatform(timing: AdaptiveTiming? = nil, hour: Int = 12)
        async throws -> (AdaptiveController, ScriptedEnvironment, Monitor, SimulatedDisplay, MonitorManager, FakePlatform) {
        let platform = FakePlatform()
        let display = platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first?.brightness?.value != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.colorTemperature?.value != nil && monitor.colorPreset?.value != nil })
        let environment = ScriptedEnvironment(hour: hour)
        let controller = AdaptiveController(manager: manager, environment: environment, timing: timing ?? self.timing())
        return (controller, environment, monitor, display, manager, platform)
    }

    private func settled(_ monitor: Monitor) async -> Bool {
        await eventually { monitor.brightness?.isWriting == false && monitor.colorTemperature?.isWriting == false }
    }

    @Test func turningItOnFollowsTheRoomAtOnce() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })
        let target = (BrightnessCurve.lightDefault.brightness(at: BrightnessCurve.lightReading(lux: 10)) * 100).rounded() / 100
        #expect(controller.statuses[monitor.id] == .following(source: .lightSensor, target: target, fallback: nil))
        // Automatic changes aren't the user's.
        #expect(monitor.brightness?.userChanges == 0)
        manager.stop()
    }

    @Test func aDarkerRoomDimsTheDisplayAfterItLasts() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 1000
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 100 })
        #expect(await settled(monitor))

        // A flicker of shade: one tick, then back. Nothing is sent.
        let frames = display.state.withLock(\.frames).count
        environment.currentLux = 5
        controller.tick()
        environment.currentLux = 1000
        controller.tick()
        controller.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(display.state.withLock { $0.frames.filter { $0.count == 6 && $0[1] == 0x03 } }.count
            == display.state.withLock { Array($0.frames.prefix(frames)).filter { $0.count == 6 && $0[1] == 0x03 } }.count)

        // A small change (under 10%) is ignored.
        environment.currentLux = 700
        controller.tick()
        controller.tick()
        controller.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(display.value(0x10) == 100)

        // The room goes dark and stays dark: after the dwell, it follows.
        environment.currentLux = 1
        controller.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(display.value(0x10) == 100, "one tick is not enough")
        controller.tick()
        let dark = Int((BrightnessCurve.lightDefault.brightness(at: BrightnessCurve.lightReading(lux: 1)) * 100).rounded())
        #expect(dark == 28)
        #expect(await eventually { display.value(0x10).map(Int.init) == dark })
        manager.stop()
    }

    /// The light is averaged in log space: one sharp reading moves it only
    /// part of the way.
    @Test func readingsAreSmoothed() async throws {
        var timing = timing()
        timing.smoothing = 0.5
        let (controller, environment, monitor, _, manager) = try await setUp(timing: timing)
        environment.currentLux = 999
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(abs((controller.lux ?? 0) - 999) < 0.5)
        environment.currentLux = 9
        controller.tick()
        // Halfway between log10(1000) = 3 and log10(10) = 1, so 2: 99 lux.
        #expect(abs((controller.lux ?? 0) - 99) < 0.5)
        manager.stop()
    }

    /// The user wins: a change by hand pauses, is learned, and holds until
    /// the light changes noticeably.
    @Test func aChangeByHandPausesAndIsLearned() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(await settled(monitor))

        monitor.brightness?.set(30)
        #expect(await settled(monitor))
        controller.tick()
        #expect(controller.statuses[monitor.id] == .paused)
        let curve = controller.settings(for: monitor.id).lightCurve
        #expect(abs(curve.brightness(at: BrightnessCurve.lightReading(lux: 10)) - 0.30) < 1e-9)

        // A little more light: still the user's choice.
        environment.currentLux = 15
        for _ in 0..<3 { controller.tick() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(display.value(0x10) == 30)
        #expect(controller.statuses[monitor.id] == .paused)

        // Much more light: it resumes, along the learned curve.
        environment.currentLux = 400
        controller.tick()
        guard case .following = controller.statuses[monitor.id] else {
            Issue.record("still \(String(describing: controller.statuses[monitor.id]))")
            return
        }
        let expected = Int((curve.brightness(at: BrightnessCurve.lightReading(lux: 400)) * 100).rounded())
        #expect(await eventually { display.value(0x10).map(Int.init) == expected })
        manager.stop()
    }

    /// A steady light changes nothing a view observes, so an open window
    /// isn't redrawn every tick. (Observation notifies on every assignment,
    /// equal or not; measured at 1.5% CPU before this.)
    @Test func aSteadyLightRedrawsNothing() async throws {
        var timing = timing()
        timing.smoothing = 0.35
        let (controller, environment, monitor, _, manager) = try await setUp(timing: timing)
        environment.currentLux = 18
        controller.update(monitor.id) { $0.isEnabled = true }
        for _ in 0..<60 { controller.tick() }   // let the average settle
        #expect(await eventually { monitor.brightness?.isWriting == false })
        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking {
            _ = controller.statuses
            _ = controller.lux
            _ = controller.builtInBrightness
            _ = controller.isLidClosed
        } onChange: {
            flag.changed = true
        }
        for _ in 0..<5 { controller.tick() }
        #expect(!flag.changed)
        #expect(controller.lux == 18)
        manager.stop()
    }

    @Test func aPauseEndsAfterItsTimeout() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        controller.update(monitor.id) {
            $0.isEnabled = true
            $0.learns = false
        }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(await settled(monitor))
        monitor.brightness?.set(90)
        #expect(await settled(monitor))
        controller.tick()
        #expect(controller.statuses[monitor.id] == .paused)
        #expect(controller.settings(for: monitor.id).lightCurve == .lightDefault, "learning is off")
        environment.date.addTimeInterval(31 * 60)
        controller.tick()
        #expect(await eventually { display.value(0x10) == 48 })
        manager.stop()
    }

    @Test func withTheLidClosedTheScheduleTakesOver() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp(hour: 23)
        environment.lidClosed = true
        controller.update(monitor.id) { $0.isEnabled = true }
        let night = DaySchedule().nightBrightness
        #expect(controller.statuses[monitor.id] == .following(source: .schedule, target: night,
                                                              fallback: "The lid is closed, so the light sensor is covered."))
        #expect(await eventually { display.value(0x10) == 35 })
        #expect(environment.luxReads == 0, "a covered sensor isn't read")
        manager.stop()
    }

    @Test func withoutTheSensorInterfaceTheScheduleTakesOver() async throws {
        let (controller, environment, monitor, _, manager) = try await setUp()
        environment.hasLightSensor = false
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(controller.effectiveSource(for: monitor.id).fallback == "This Mac's light sensor can't be read.")
        #expect(environment.luxReads == 0)
        manager.stop()
    }

    @Test func followingTheMacBookScreen() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentBuiltIn = 0.5
        controller.update(monitor.id) {
            $0.isEnabled = true
            $0.source = .followBuiltIn
        }
        #expect(await eventually { display.value(0x10) == 55 })
        #expect(environment.luxReads == 0, "only the source in use is read")
        manager.stop()
    }

    /// Off means off: no timer, no sensor reads, no writes.
    @Test func turnedOffNothingIsRead() async throws {
        var timing = timing()
        timing.interval = .milliseconds(10)
        let (controller, environment, monitor, _, manager) = try await setUp(timing: timing)
        controller.start()
        #expect(!controller.isRunning)
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(controller.isRunning)
        #expect(await eventually { environment.luxReads >= 3 })
        controller.update(monitor.id) { $0.isEnabled = false }
        #expect(!controller.isRunning)
        let reads = environment.luxReads
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.luxReads == reads)
        #expect(controller.statuses[monitor.id] == .off)

        // Display sleep stops it too, and waking resumes.
        controller.update(monitor.id) { $0.isEnabled = true }
        controller.setSuspended(true)
        #expect(!controller.isRunning)
        controller.setSuspended(false)
        #expect(controller.isRunning)
        controller.stop()
        manager.stop()
    }

    /// Evening warmth changes the temperature when the period changes, and
    /// a temperature set by hand holds until the next change.
    @Test func eveningWarmthFollowsTheSchedule() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp(hour: 22)
        controller.update(monitor.id) { $0.warmsInEvening = true }     // 4500 K at night
        #expect(await eventually { display.value(0x0C) == 30 })
        #expect(await settled(monitor))
        monitor.colorTemperature?.set(20)
        #expect(await eventually { display.value(0x0C) == 20 })
        controller.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(display.value(0x0C) == 20)

        environment.date.addTimeInterval(10 * 3600)    // 08:00
        controller.tick()
        #expect(await eventually { display.value(0x0C) == 70 })
        #expect(display.value(0x14) == 8, "6500 K reads as the factory preset")
        manager.stop()
    }

    /// A fade goes in steps, and the user grabbing the slider stops it.
    @Test func aFadeStopsWhenTheUserTakesOver() async throws {
        var timing = timing()
        timing.fadeSteps = 6
        timing.fadeDuration = .milliseconds(600)
        let (controller, environment, monitor, display, manager) = try await setUp(timing: timing)
        environment.currentLux = 1000
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 100 })
        environment.currentLux = 0
        controller.update(monitor.id) { $0.source = .schedule }       // applies at once
        controller.update(monitor.id) { $0.source = .lightSensor }
        #expect(await eventually { (display.value(0x10) ?? 100) < 100 })
        monitor.brightness?.setEditing(true)
        let held = monitor.brightness?.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(monitor.brightness?.value == held)
        monitor.brightness?.setEditing(false)
        manager.stop()
    }

    // MARK: - Correctness

    private func writes(_ display: SimulatedDisplay, code: UInt8) -> [UInt16] {
        display.state.withLock { state in
            state.frames.filter { $0.count == 6 && $0[1] == 0x03 && $0[2] == code }.map { UInt16($0[3]) << 8 | UInt16($0[4]) }
        }
    }

    /// Slider moves made while it was off are not a takeover when it is
    /// turned back on.
    @Test func turningItBackOnAfterAManualChangeFollowsAgain() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(await settled(monitor))
        controller.update(monitor.id) { $0.isEnabled = false }

        monitor.brightness?.set(30)
        #expect(await settled(monitor))
        #expect(await eventually { display.value(0x10) == 30 })

        controller.update(monitor.id) { $0.isEnabled = true }
        controller.tick()
        guard case .following = controller.statuses[monitor.id] else {
            Issue.record("still \(String(describing: controller.statuses[monitor.id]))")
            return
        }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(controller.settings(for: monitor.id).lightCurve == .lightDefault)
        manager.stop()
    }

    /// A display that ignores the writes keeps the period unconfirmed: it is
    /// tried again after a pause, not on every tick, and once it takes it,
    /// the status says so.
    @Test func warmthIsRetriedUntilTheDisplayTakesIt() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp(hour: 22)
        display.update { $0.ignoresWrites.insert(0x0C) }
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(controller.warmthStatuses[monitor.id] == .applying(kelvin: 4500))
        #expect(await eventually { !writes(display, code: 0x0C).isEmpty })
        #expect(await settled(monitor))
        #expect(await eventually { monitor.colorTemperature?.deviceValue == 70 && monitor.colorTemperature?.value == 70 })
        let attempts = writes(display, code: 0x0C).count
        for _ in 0..<5 { controller.tick() }
        await settle()
        #expect(writes(display, code: 0x0C).count == attempts, "no retry within the pause")
        #expect(controller.warmthStatuses[monitor.id] == .applying(kelvin: 4500))

        display.update { $0.ignoresWrites.remove(0x0C) }
        environment.date.addTimeInterval(31)
        controller.tick()
        #expect(controller.warmthStatuses[monitor.id] == .retrying)
        #expect(await eventually { display.value(0x0C) == 30 })
        #expect(await eventually {
            controller.tick()
            return controller.warmthStatuses[monitor.id] == .applied(kelvin: 4500)
        })
        manager.stop()
    }

    /// A hand-set temperature stops the retries and holds until the period
    /// changes.
    @Test func aHandSetTemperatureEndsTheRetries() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp(hour: 22)
        display.update { $0.ignoresWrites.insert(0x0C) }
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(await settled(monitor))
        #expect(await eventually { monitor.colorTemperature?.value == 70 })

        display.update { $0.ignoresWrites.remove(0x0C) }
        monitor.colorTemperature?.set(55)
        #expect(await eventually { display.value(0x0C) == 55 })
        environment.date.addTimeInterval(60)
        controller.tick()
        #expect(controller.warmthStatuses[monitor.id] == .heldByUser)
        await settle()
        #expect(display.value(0x0C) == 55)

        environment.date.addTimeInterval(10 * 3600)
        controller.tick()
        #expect(await eventually { display.value(0x0C) == 70 })
        manager.stop()
    }

    /// A monitor that comes back from a replug is probably at another
    /// temperature: the period is applied again.
    @Test func aReplugAppliesWarmthAgain() async throws {
        let (controller, _, monitor, display, manager, platform) = try await setUpWithPlatform(hour: 22)
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(await eventually {
            controller.tick()
            return controller.warmthStatuses[monitor.id] == .applied(kelvin: 4500)
        })
        #expect(display.value(0x0C) == 30)
        let old = try #require(monitor.colorTemperature)

        platform.disconnectAll()
        let replacement = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        platform.fireChange()
        #expect(await eventually { monitor.colorTemperature != nil && monitor.colorTemperature !== old && monitor.colorTemperature?.value == 70 })
        #expect(await eventually {
            controller.tick()
            return replacement.value(0x0C) == 30
        })
        manager.stop()
    }

    /// Waking up confirms the temperature again.
    @Test func wakingConfirmsWarmthAgain() async throws {
        let (controller, _, monitor, display, manager) = try await setUp(hour: 22)
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(await eventually {
            controller.tick()
            return controller.warmthStatuses[monitor.id] == .applied(kelvin: 4500)
        })
        controller.setSuspended(true)
        display.update { $0.values[0x0C]?.current = 70 }      // the display forgot
        await monitor.colorTemperature?.refresh()
        controller.setSuspended(false)
        controller.tick()
        #expect(await eventually { display.value(0x0C) == 30 })
        manager.stop()
    }

    /// While the preset has no temperature (sRGB, native), warmth does not
    /// take the display out of it, and does not fade up from 0 when one
    /// returns.
    @Test func warmthLeavesAPresetWithoutATemperatureAlone() async throws {
        let (controller, _, monitor, display, manager) = try await setUp(hour: 22)
        display.update {
            $0.values[0x0C]?.current = 0
            $0.values[0x14]?.current = 1
        }
        await monitor.colorTemperature?.refresh()
        #expect(monitor.colorTemperature?.value == 0)
        let frames = display.state.withLock(\.frames).count

        controller.update(monitor.id) { $0.warmsInEvening = true }
        for _ in 0..<3 { controller.tick() }
        await settle()
        #expect(controller.warmthStatuses[monitor.id] == .waitingForPreset)
        #expect(display.state.withLock(\.frames).count == frames, "nothing was sent")
        #expect(display.value(0x14) == 1)

        // A preset with a temperature again: applied, straight from there.
        display.update {
            $0.values[0x0C]?.current = 70
            $0.values[0x14]?.current = 8
        }
        await monitor.colorTemperature?.refresh()
        controller.tick()
        #expect(await eventually { display.value(0x0C) == 30 })
        #expect(writes(display, code: 0x0C).allSatisfy { $0 >= 30 }, "no pass through the low steps")
        manager.stop()
    }

    @Test func aTemperatureSetByHandWhileThePresetHasNoneHolds() async throws {
        let (controller, _, monitor, display, manager) = try await setUp(hour: 22)
        display.update {
            $0.values[0x0C]?.current = 0
            $0.values[0x14]?.current = 1
        }
        await monitor.colorTemperature?.refresh()
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(controller.warmthStatuses[monitor.id] == .waitingForPreset)

        monitor.colorTemperature?.set(60)
        #expect(await eventually { display.value(0x0C) == 60 })
        #expect(await settled(monitor))
        controller.tick()
        #expect(controller.warmthStatuses[monitor.id] == .heldByUser)
        await settle()
        #expect(display.value(0x0C) == 60)
        manager.stop()
    }

    /// Applying a scene pauses automatic brightness but is not a lesson
    /// about the light.
    @Test func applyingASceneIsNotLearned() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(await settled(monitor))

        var scene = DisplayScene(name: "Movie", includes: [.brightness])
        scene.monitors[monitor.id] = DisplayScene.Settings(monitorName: monitor.name,
                                                           brightness: DisplayScene.Level(value: 15, maximum: 100))
        scene.apply(to: [monitor])
        #expect(await settled(monitor))
        #expect(await eventually { display.value(0x10) == 15 })
        controller.tick()
        #expect(controller.statuses[monitor.id] == .paused)
        #expect(controller.settings(for: monitor.id).lightCurve == .lightDefault)
        #expect(monitor.brightness?.sceneChanges == 1)

        // A change by hand afterwards is still learned.
        monitor.brightness?.set(60)
        #expect(await settled(monitor))
        controller.tick()
        #expect(controller.settings(for: monitor.id).lightCurve != .lightDefault)
        manager.stop()
    }

    @Test func aChangeSaysWhereItComesFrom() async throws {
        let (_, _, monitor, _, manager) = try await setUp()
        let brightness = try #require(monitor.brightness)
        brightness.set(40)
        brightness.set(41, origin: .scene)
        brightness.set(42, origin: .automatic)
        brightness.set(43, automatic: true)
        brightness.set(44, automatic: false)
        #expect(brightness.userChanges == 3)
        #expect(brightness.sceneChanges == 1)
        manager.stop()
    }

    /// With the display gone, nothing is polled; back, it catches up.
    @Test func aDisconnectedDisplayStopsTheLoop() async throws {
        var timing = timing()
        timing.interval = .milliseconds(10)
        let (controller, environment, monitor, _, manager, platform) = try await setUpWithPlatform(timing: timing)
        let id = monitor.id
        controller.update(id) { $0.isEnabled = true }
        #expect(controller.isRunning)
        #expect(await eventually { environment.luxReads >= 3 })

        platform.disconnectAll()
        platform.fireChange()
        #expect(await eventually { manager.monitors.isEmpty })
        #expect(await eventually { !controller.isRunning })
        #expect(controller.statuses[id] == nil)
        let reads = environment.luxReads
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.luxReads == reads)

        let replacement = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        platform.fireChange()
        #expect(await eventually { controller.isRunning })
        #expect(await eventually { replacement.value(0x10) == 48 })
        #expect(environment.luxReads > reads)
        controller.stop()
        manager.stop()
    }

    /// A display that doesn't answer is left alone and caught up when it does.
    @Test func aDisplayThatIsNotReadyIsNotWrittenTo() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        display.update { $0.readsFail = true }
        await monitor.refresh()
        #expect(monitor.status == .notResponding)
        let frames = display.state.withLock(\.frames).count

        controller.update(monitor.id) { $0.isEnabled = true }
        controller.tick()
        #expect(controller.statuses[monitor.id] == .waiting)
        await settle()
        #expect(display.state.withLock(\.frames).count == frames)

        display.update { $0.readsFail = false }
        await monitor.refresh()
        #expect(monitor.status == .ready)
        controller.tick()
        #expect(await eventually { display.value(0x10) == 48 })
        manager.stop()
    }

    /// A reconnect gives a new control whose change count starts over; that
    /// is not the user moving the slider.
    @Test func aReconnectIsNotATakeover() async throws {
        let (controller, environment, monitor, _, manager, platform) = try await setUpWithPlatform()
        environment.currentLux = 10
        controller.update(monitor.id) {
            $0.isEnabled = true
            $0.learns = false
        }
        #expect(await settled(monitor))
        monitor.brightness?.set(30)
        monitor.brightness?.set(31)
        #expect(await settled(monitor))
        controller.tick()
        environment.date.addTimeInterval(31 * 60)       // the pause is over
        controller.tick()
        #expect(await eventually { monitor.brightness?.value == 48 })
        #expect(await settled(monitor))
        let curve = controller.settings(for: monitor.id).lightCurve

        platform.disconnectAll()
        let replacement = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        platform.fireChange()
        #expect(await eventually { monitor.brightness?.value == 100 && monitor.status == .ready })
        controller.tick()
        guard case .following = controller.statuses[monitor.id] else {
            Issue.record("still \(String(describing: controller.statuses[monitor.id]))")
            return
        }
        #expect(await eventually { replacement.value(0x10) == 48 })
        #expect(controller.settings(for: monitor.id).lightCurve == curve)
        manager.stop()
    }

    /// Fading toward a new level replaces the fade under way instead of
    /// running beside it.
    @Test func aNewFadeReplacesTheOneUnderWay() async throws {
        var timing = timing()
        timing.fadeSteps = 6
        timing.fadeDuration = .milliseconds(300)
        let (controller, environment, monitor, display, manager) = try await setUp(timing: timing)
        environment.currentLux = 1000
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 100 })
        environment.currentLux = 0
        controller.update(monitor.id) { $0.source = .schedule }       // fades toward 90
        controller.update(monitor.id) { $0.source = .lightSensor }    // and then toward 20
        #expect(await eventually { display.value(0x10) == 20 })
        try await Task.sleep(for: .milliseconds(400))
        let levels = writes(display, code: 0x10).filter { $0 != 100 }
        #expect(levels == levels.sorted(by: >), "one fade, going one way: \(levels)")
        #expect(display.value(0x10) == 20)
        manager.stop()
    }

    /// A sensor that stops answering is dropped after two misses, and the
    /// schedule takes over.
    @Test func aSensorThatStopsAnsweringFallsBackToTheSchedule() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })

        environment.currentLux = nil
        controller.tick()
        #expect(controller.lux == 10, "one miss is a glitch")
        controller.tick()
        #expect(controller.lux == nil)
        #expect(controller.effectiveSource(for: monitor.id).fallback == "The light sensor isn't answering.")

        // Likewise the MacBook screen.
        environment.currentBuiltIn = 0.5
        controller.update(monitor.id) { $0.source = .followBuiltIn }
        #expect(controller.builtInBrightness == 0.5)
        environment.currentBuiltIn = nil
        controller.tick()
        controller.tick()
        #expect(controller.builtInBrightness == nil)
        #expect(controller.effectiveSource(for: monitor.id).fallback == "The MacBook screen is off.")
        manager.stop()
    }

    @Test func sleepForgetsWhatWasRead() async throws {
        let (controller, environment, monitor, _, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(controller.lux == 10)
        controller.setSuspended(true)
        #expect(controller.lux == nil)
        environment.currentLux = nil
        controller.setSuspended(false)
        controller.tick()
        #expect(controller.effectiveSource(for: monitor.id).source == .schedule, "no stale light after waking")
        manager.stop()
    }

    /// Docking the laptop turns the sensor into the schedule; a level the
    /// user just set by hand stays.
    @Test func closingTheLidKeepsAManualLevel() async throws {
        let (controller, environment, monitor, display, manager) = try await setUp()
        environment.currentLux = 10
        controller.update(monitor.id) { $0.isEnabled = true }
        #expect(await eventually { display.value(0x10) == 48 })
        #expect(await settled(monitor))
        monitor.brightness?.set(30)
        #expect(await settled(monitor))
        controller.tick()
        #expect(controller.statuses[monitor.id] == .paused)

        environment.lidClosed = true
        controller.tick()
        #expect(controller.statuses[monitor.id] == .paused)
        await settle()
        #expect(display.value(0x10) == 30)

        // Choosing another source still ends it.
        controller.update(monitor.id) { $0.source = .schedule }
        #expect(await eventually { display.value(0x10) == 90 })
        manager.stop()
    }

    /// The window shows warmth too, and a steady state redraws nothing.
    @Test func aSteadyWarmthRedrawsNothing() async throws {
        let (controller, _, monitor, _, manager) = try await setUp(hour: 22)
        controller.update(monitor.id) { $0.warmsInEvening = true }
        #expect(await eventually {
            controller.tick()
            return controller.warmthStatuses[monitor.id] == .applied(kelvin: 4500)
        })
        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking {
            _ = controller.warmthStatuses
            _ = controller.statuses
        } onChange: {
            flag.changed = true
        }
        for _ in 0..<5 { controller.tick() }
        #expect(!flag.changed)
        manager.stop()
    }
}
