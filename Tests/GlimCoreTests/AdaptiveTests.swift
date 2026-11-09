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
        let platform = FakePlatform()
        let display = platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first?.brightness?.value != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.colorTemperature?.value != nil && monitor.colorPreset?.value != nil })
        let environment = ScriptedEnvironment(hour: hour)
        let controller = AdaptiveController(manager: manager, environment: environment, timing: timing ?? self.timing())
        return (controller, environment, monitor, display, manager)
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
}
