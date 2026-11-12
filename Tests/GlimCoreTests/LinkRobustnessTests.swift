import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// What a flaky or odd monitor must not be able to do: write a value nobody
/// chose, hide working controls, or stay stale after a sleep.
@Suite @MainActor struct LinkRobustnessTests {
    private func level(_ device: ScriptedDevice<Double>) -> DeviceControl<Double> {
        DeviceControl(backend: device.backend,
                      timing: ControlTiming(settleDelay: .zero, operationTimeout: .seconds(5)),
                      quantize: quantizeToSteps)
    }

    private func idle(_ control: DeviceControl<Double>) async -> Bool {
        await eventually { !control.isWriting }
    }

    private func hp(_ serviceID: UInt64 = 1) -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: "dispext0", identity: Fixtures.hpIdentity)
    }

    private func ready(_ monitor: Monitor) async -> Bool {
        await eventually { monitor.status == .ready && monitor.brightness?.value != nil }
    }

    // MARK: Writes

    /// A write that failed may have reached the device all the same, so the
    /// value it held before is no longer "already written".
    @Test func aValueIsSentAgainAfterAFailedWrite() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.writeError = DDCError.timedOut; $0.readError = DDCError.noReply }
        control.set(70)
        #expect(await idle(control))
        #expect(await eventually { control.failure != nil })
        await device.configure { $0.writeError = nil; $0.readError = nil }

        control.set(50)
        #expect(await idle(control))
        #expect(await device.attempts == [70, 50])
    }

    /// After a wake the device may hold anything: a change back to the value
    /// last written is sent, not skipped.
    @Test func forgettingTheLastWriteSendsTheSameValueAgain() async {
        let device = ScriptedDevice(value: 80.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        // Two changes before the writer runs leave only the last one, which
        // equals what was read: normally nothing to send.
        control.set(60)
        control.set(80)
        #expect(await idle(control))
        #expect(await device.attempts.isEmpty)

        control.forgetLastWritten()
        control.set(60)
        control.set(80)
        #expect(await idle(control))
        #expect(await device.attempts == [80])
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func aLevelThatIsNotANumberIsIgnored(level value: Double) async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        control.set(value)
        await settle()
        #expect(control.value == 50)
        #expect(await device.attempts.isEmpty)
    }

    // MARK: Ranges

    /// A maximum of 0 would give a 0…1 slider over a 0–100 backlight, and
    /// automatic brightness would walk the display down to it.
    @Test func aLevelWithoutARangeIsNotOffered() async throws {
        let platform = FakePlatform()
        let display = SimulatedDisplay.hp()
        display.update { $0.values[0x10] = .init(current: 50, maximum: 0) }
        platform.connect(hp(), simulated: display)
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.status == .ready && monitor.contrast?.value != nil })
        // Dropped once the first pass over the controls is done.
        #expect(await eventually { monitor.brightness == nil })
        #expect(display.state.withLock(\.frames).allSatisfy { !($0.count == 6 && $0[1] == 0x03 && $0[2] == 0x10) })
        manager.stop()
    }

    @Test func aValueAboveItsMaximumIsShownAtTheMaximum() async throws {
        let platform = FakePlatform()
        let display = SimulatedDisplay.hp()
        display.update { $0.values[0x12] = .init(current: 120, maximum: 100) }
        platform.connect(hp(), simulated: display)
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.contrast?.value == 100 })
        #expect(monitor.contrast?.range == 0...100)
        manager.stop()
    }

    // MARK: Status

    /// One code that loses its read leaves the monitor ready, with the
    /// failure on that control; nothing answering at all does not.
    @Test func oneLostReadDoesNotHideTheControls() async throws {
        let platform = FakePlatform()
        let display = platform.connect(hp())
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await ready(monitor))

        display.update { $0.silentCodes = [0x60] }
        await monitor.refresh()
        #expect(monitor.status == .ready)
        #expect(monitor.input?.control.failure != nil)
        #expect(monitor.brightness?.failure == nil)
        // Again, alone this time: still one lost read at a time.
        await monitor.input?.control.refresh()
        await monitor.refresh()
        #expect(monitor.status == .ready)

        display.update { $0.silent = true }
        await monitor.refresh()
        #expect(monitor.status == .notResponding)
        display.update { $0.silent = false; $0.silentCodes = [] }
        await monitor.refresh()
        #expect(monitor.status == .ready)
        manager.stop()
    }

    // MARK: Wake

    /// A monitor that comes back from sleep with other values, on the same
    /// transport, is read again without anyone opening the menu.
    @Test func afterAWakeEveryMonitorIsReadAgain() async throws {
        let platform = FakePlatform()
        let display = platform.connect(hp())
        let manager = MonitorManager(platform: platform, wakeRescanDelay: .zero, wakeRereadDelays: [.milliseconds(30)])
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await ready(monitor))
        let before = try #require(monitor.brightness?.value)

        display.update { $0.values[0x10]?.current = before == 40 ? 60 : 40 }
        manager.displaysDidWake()
        #expect(await eventually { monitor.brightness?.value == (before == 40 ? 60 : 40) })
        manager.stop()
    }

    /// DDC/CI can take longer than the picture to come back: a monitor
    /// silent at the first read after a wake is read again later.
    @Test func aMonitorStillSilentAfterAWakeIsReadAgainLater() async throws {
        let platform = FakePlatform()
        let display = platform.connect(hp())
        let manager = MonitorManager(platform: platform, wakeRescanDelay: .zero,
                                     wakeRereadDelays: [.milliseconds(30), .seconds(1.5)])
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await ready(monitor))

        display.update { $0.silent = true }
        manager.displaysDidWake()
        #expect(await eventually(timeout: .seconds(1)) { monitor.status == .notResponding })
        display.update { $0.silent = false }
        #expect(await eventually { monitor.status == .ready })
        manager.stop()
    }

    /// A display still nameless after its three retries gets them again when
    /// something outside asks for a rescan (a wake, the toolbar button).
    @Test func askingForARescanRearmsTheIdentityRetries() async throws {
        let platform = FakePlatform()
        platform.connect(DiscoveredDisplay(serviceID: 7, framebuffer: "dispext0", identity: nil))
        let manager = MonitorManager(platform: platform, identityRetryDelay: .milliseconds(10))
        manager.start()
        // The first scan and three retries.
        #expect(await eventually { platform.state.withLock(\.discoveries) == 4 })
        await settle()
        #expect(platform.state.withLock(\.discoveries) == 4)

        manager.scheduleRescan(after: .zero)
        #expect(await eventually { platform.state.withLock(\.discoveries) == 8 })
        manager.stop()
    }
}
