import Foundation
import os
@testable import GlimCore
import GlimTestSupport
import Testing

/// How controls and monitors recover from failures without losing the
/// user's work or getting stuck.
@Suite @MainActor struct ControlRecoveryTests {
    private func level(_ device: ScriptedDevice<Double>, settle: Duration = .zero) -> DeviceControl<Double> {
        DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: settle, operationTimeout: .seconds(5)),
                      quantize: quantizeToSteps)
    }

    @Test func aFailedWriteDoesNotSpeakForTheMonitor() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device, settle: .seconds(60))
        var outcomes = 0
        control.onLinkOutcome = { _ in outcomes += 1 }
        await control.refresh()
        #expect(outcomes == 1)
        await device.configure { $0.writeError = DDCError.writeFailed(-1) }
        control.set(70)
        #expect(await eventually { !control.isWriting })
        #expect(control.failure != nil)
        #expect(outcomes == 1)
    }

    /// The read-back shows the old value, and the warning stays, so the
    /// user can see the change did not take.
    @Test func aDroppedWriteKeepsItsWarningAfterTheReadBack() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.writeError = DDCError.writeFailed(-1) }
        control.set(70)
        #expect(await eventually { control.value == 50 && !control.isWriting })
        #expect(control.failure?.message == DDCError.writeFailed(-1).errorDescription)
        await device.configure { $0.writeError = nil }
        control.set(71)
        #expect(await eventually { control.deviceValue == 71 })
        #expect(control.failure == nil)
    }

    @Test func aFailedReadDuringADragIsNotApplied() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device, settle: .seconds(60))
        await control.refresh()
        await device.configure {
            $0.readGate = gate
            $0.readError = DDCError.noReply
        }
        let read = Task { await control.refresh() }
        #expect(await eventually { await gate.waiting == 1 })
        control.setEditing(true)
        await gate.open()
        await read.value
        #expect(control.failure == nil)
        #expect(control.value == 50)
    }

    /// SwiftUI never ends a drag whose slider it removed. Without a way out,
    /// reads would stay held off for good.
    @Test func endingAnAbandonedDragLetsReadsResume() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        control.setEditing(true)
        await device.configure { $0.value = 64 }
        await control.refresh()
        #expect(control.value == 50)
        control.endInteraction()
        #expect(await eventually { control.value == 64 })
    }

    /// Going 60 → 61 → 60 while 60 is being written sends 60 once.
    @Test func aChangeUndoneDuringAWriteIsNotSentAgain() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device, settle: .seconds(60))
        await control.refresh()
        await device.configure { $0.writeGate = gate }
        control.set(60)
        #expect(await eventually { await device.attempts == [60] })
        control.set(61)
        control.set(60)
        await gate.open()
        #expect(await eventually { !control.isWriting })
        #expect(await device.attempts == [60])
    }

    @Test func aTimedOutOperationIsCancelled() async {
        let gate = Gate()
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: DDCError.timedOut) {
            try await withDeadline(.milliseconds(30)) {
                await gate.wait()
                sawCancellation.withLock { $0 = Task.isCancelled }
            }
        }
        await gate.open()
        #expect(await eventually { sawCancellation.withLock { $0 } })
    }

    @Test func cancellingTheCallerReturnsAtOnceAndCancelsTheOperation() async {
        let gate = Gate()
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        let call = Task {
            try await withDeadline(.seconds(60)) {
                await gate.wait()
                sawCancellation.withLock { $0 = Task.isCancelled }
                return 1
            }
        }
        #expect(await eventually { await gate.waiting == 1 })
        let start = ContinuousClock.now
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(start.duration(to: .now) < .seconds(5))
        await gate.open()
        #expect(await eventually { sawCancellation.withLock { $0 } })
    }

    @Test func aFailedSwitchCanBeAskedForAgain() async {
        let device = ScriptedDevice<UInt16>(value: 0x13)
        let control = DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: .seconds(60)))
        let selector = InputSelector(options: MonitorProfile.hpE27mG4.inputs ?? [], control: control)
        await control.refresh()
        await device.configure { $0.writeError = DDCError.writeFailed(-1) }
        let hdmi = InputOption(value: 0x11, name: "HDMI")
        selector.request(hdmi)
        selector.confirm()
        #expect(await eventually { !selector.isWriting })
        #expect(selector.failure != nil)
        selector.request(hdmi)
        #expect(selector.pendingSelection == hdmi)
    }
}

/// Monitors and the manager across reconnects, failures and odd hardware.
@Suite @MainActor struct LifecycleTests {
    private let hpAudio = AudioDeviceInfo(id: 97, name: "HP E27m G4 USB Audio", isUSB: true)

    private func hp(_ serviceID: UInt64 = 1, pipe: String = "dispext0",
                    identity: DisplayIdentity? = TestIdentity.hp) -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: pipe, identity: identity)
    }

    private func started(_ platform: FakePlatform) async -> MonitorManager {
        let manager = MonitorManager(platform: platform)
        manager.start()
        _ = await eventually { !manager.isDiscovering }
        return manager
    }

    private func setFrames(_ display: SimulatedDisplay) -> Int {
        display.state.withLock { $0.frames.filter { $0.count == 6 && $0[1] == 0x03 }.count }
    }

    @Test func aDisconnectedMonitorSendsNothingMore() async throws {
        let platform = FakePlatform()
        let simulated = platform.connect(hp())
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.brightness?.value == 100 })
        let brightness = try #require(monitor.brightness)

        platform.disconnectAll()
        platform.fireChange()
        #expect(await eventually { manager.monitors.isEmpty })
        #expect(monitor.brightness == nil)
        brightness.set(10)
        await settle()
        #expect(setFrames(simulated) == 0)
        #expect(simulated.value(0x10) == 100)
    }

    @Test func aReconnectStopsTheOldControls() async throws {
        let platform = FakePlatform()
        let old = platform.connect(hp(1))
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.brightness?.value == 100 })
        let stale = try #require(monitor.brightness)

        platform.disconnectAll()
        let replacement = platform.connect(hp(2))
        platform.fireChange()
        #expect(await eventually { monitor.brightness !== stale && monitor.brightness?.value == 100 })
        stale.set(10)
        await settle()
        #expect(setFrames(old) == 0)
        #expect(setFrames(replacement) == 0)
    }

    /// An EDID published after its transport changes the monitor's key, so
    /// a new monitor object replaces the old one, on the same bus. They must
    /// share one channel.
    @Test func monitorsOnOneTransportShareOneChannel() async throws {
        let platform = FakePlatform()
        platform.connect(hp(5, identity: nil))
        let manager = await started(platform)
        #expect(manager.monitors.first?.id == "unidentified-5")
        platform.state.withLock { $0.displays = [DiscoveredDisplay(serviceID: 5, framebuffer: "dispext0", identity: TestIdentity.hp)] }
        platform.fireChange()
        #expect(await eventually { manager.monitors.first?.id == TestIdentity.hp.stableKey })
        #expect(platform.state.withLock(\.devicesMade) == 1)
    }

    @Test func oneSpeakerTwoIdenticalMonitorsMeansNoVolume() async {
        let platform = FakePlatform()
        let anonymous = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, serialNumber: 0x0101_0101, productName: "HP E27m G4")
        platform.connect(hp(1, pipe: "dispext0", identity: anonymous))
        platform.connect(hp(2, pipe: "dispext1", identity: anonymous))
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        #expect(await eventually { manager.monitors.allSatisfy { $0.status == .ready } })
        #expect(manager.monitors.allSatisfy { $0.volume == nil })
    }

    /// A display whose EDID is not known yet could be a second HP, whose
    /// speaker this one is.
    @Test func anUnidentifiedDisplayStopsTheSpeakerGuess() async throws {
        let platform = FakePlatform()
        platform.connect(hp(1))
        platform.connect(hp(2, pipe: "dispext1", identity: nil))
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first { $0.id == TestIdentity.hp.stableKey })
        #expect(await eventually { monitor.status == .ready })
        #expect(monitor.volume == nil)

        // It turns out to be another make.
        let other = DisplayIdentity(vendorID: 0x10AC, productID: 0x4242, alphanumericSerial: "OTHER")
        platform.state.withLock { $0.displays[1].identity = other }
        platform.fireChange()
        #expect(await eventually { monitor.volume?.value == 0.5 })
    }

    @Test func theSpeakersKeepWorkingWhileDDCIsSilent() async throws {
        let platform = FakePlatform()
        let simulated = platform.connect(hp())
        simulated.update { $0.silent = true }
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.status == .notResponding && monitor.volume?.value == 0.5 })
        #expect(monitor.hasUSBSpeakers)
        let output = try #require(platform.output(hpAudio.id))
        try await output.setVolume(0.9)
        try await Task.sleep(for: .seconds(2.1))   // past the refresh throttle
        await manager.refresh()
        #expect(await eventually { monitor.volume?.value == 0.9 })
    }

    /// A monitor without a profile reconnects while its capabilities are not
    /// coming through: what they described goes away rather than staying as
    /// dead controls, and comes back once they do come through.
    @Test func aGenericReconnectWithoutCapabilitiesLeavesNoDeadControls() async throws {
        let caps = "(prot(monitor)type(LCD)model(Example 27)cmds(01 02 03 F3)vcp(10 12 60(0F 11) 62 8D(01 02)))"
        let values: [UInt8: SimulatedDisplay.Value] = [
            0x10: .init(current: 40, maximum: 100), 0x12: .init(current: 70, maximum: 100),
            0x60: .init(current: 0x0F, maximum: 0), 0x62: .init(current: 25, maximum: 100), 0x8D: .init(current: 2, maximum: 2),
        ]
        let identity = DisplayIdentity(vendorID: 0x10AC, productID: 0x4242, alphanumericSerial: "G1")
        let platform = FakePlatform()
        platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: identity),
                         simulated: SimulatedDisplay { $0.capabilities = Array(caps.utf8); $0.values = values })
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.input?.current != nil && monitor.volume?.value == 25 })

        let waking = SimulatedDisplay {
            $0.capabilities = Array(caps.utf8)
            $0.values = values
            $0.capabilitiesSilent = true
        }
        let before = monitor.brightness
        platform.disconnectAll()
        platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext0", identity: identity), simulated: waking)
        platform.fireChange()
        // The rescan is debounced: wait for the rebuilt controls, not the old ones.
        #expect(await eventually { monitor.brightness !== before && monitor.status == .ready && monitor.brightness?.value == 40 })
        #expect(monitor.input == nil)
        #expect(monitor.volume == nil)
        #expect(monitor.mute == nil)

        waking.update { $0.capabilitiesSilent = false }
        try await Task.sleep(for: .seconds(2.1))   // past the refresh throttle
        await manager.refresh()
        #expect(await eventually { monitor.input?.current != nil && monitor.volume?.value == 25 })
    }

    @Test func rescansAreDebounced() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        let manager = await started(platform)
        let before = platform.state.withLock(\.discoveries)
        for _ in 0..<5 { platform.fireChange() }
        #expect(await eventually { platform.state.withLock(\.discoveries) > before })
        try await Task.sleep(for: .seconds(1))
        #expect(platform.state.withLock(\.discoveries) == before + 1)
        _ = manager
    }

    @Test func stopThenStartFindsTheMonitorsAgain() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        let manager = await started(platform)
        #expect(manager.monitors.count == 1)
        manager.stop()
        #expect(manager.monitors.isEmpty)
        manager.start()
        #expect(manager.isDiscovering)
        #expect(await eventually { !manager.isDiscovering && manager.monitors.first?.brightness?.value == 100 })
    }

    @Test func aMonitorWithNoUsableControlSaysSoInsteadOfConnectingForever() async throws {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { $0.capabilities = Array("(vcp(02 D6))".utf8) }
        platform.connect(DiscoveredDisplay(serviceID: 3, framebuffer: "dispext0",
                                           identity: DisplayIdentity(vendorID: 0x10AC, productID: 1)), simulated: simulated)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        // "Ready" arrives with the first unsupported reply, a moment before
        // the controls are dropped: wait for the end state.
        #expect(await eventually { monitor.status == .ready && !monitor.hasControls })
    }

    @Test func duplicateIdentitiesOnOnePipeGetDistinctKeys() {
        let keys = MonitorManager.monitorKeys(for: [hp(1), hp(2)])
        #expect(keys == ["\(TestIdentity.hp.stableKey)@dispext0#1", "\(TestIdentity.hp.stableKey)@dispext0#2"])
    }
}
