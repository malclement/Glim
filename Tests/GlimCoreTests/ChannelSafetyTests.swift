import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// What the channel must never do, whoever calls it: write a code Glim does
/// not support, send an operation its caller gave up on, or let two
/// transactions overlap on the bus.
@Suite struct ChannelSafetyTests {
    private func setFrames(_ display: SimulatedDisplay, code: UInt8) -> [[UInt8]] {
        display.state.withLock { $0.frames.filter { $0.count == 6 && $0[1] == 0x03 && $0[2] == code } }
    }

    @Test(arguments: [0x04, 0x05, 0xCA, 0xD6, 0xDC, 0xE1, 0xE8, 0xFF] as [UInt8])
    func codesOutsideTheAllowListAreNeverWritten(code: UInt8) async {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.refused(VCPCode(code))) {
            try await channel.write(VCPCode(code), value: 0)
        }
        #expect(display.state.withLock(\.frames).isEmpty)
    }

    @Test func theAllowListIsWhatGlimWrites() {
        #expect(DDCChannel.writableCodes == [.brightness, .contrast, .colorTemperature, .colorPreset,
                                             .inputSource, .audioVolume, .audioMute])
        // 0x0B is the read-only temperature increment.
        #expect(!DDCChannel.writableCodes.contains(.colorTemperatureIncrement))
    }

    /// The reviewers' scenario: the channel is stuck, the user confirms an
    /// input switch, the UI gives up after the timeout. When the channel frees
    /// up, the switch must not happen behind the user's back.
    @Test func aWriteThatTimedOutIsNeverSentLater() async throws {
        let display = SimulatedDisplay.hp()
        let gate = BusGate()
        let channel = DDCChannel(label: "test", timing: .immediate) { () throws(DDCError) -> any DDCBus in
            BlockingBus(display: display, gate: gate)
        }
        gate.arm()
        let stuck = Task { try await channel.read(.brightness) }
        #expect(await eventually { gate.blocked == 1 })

        await #expect(throws: DDCError.timedOut) {
            try await withDeadline(.milliseconds(50)) { try await channel.write(.inputSource, value: 0x11) }
        }
        gate.release()
        _ = try await stuck.value
        // Runs after the queued write's job, so the queue has drained.
        _ = try await channel.read(.contrast)

        #expect(setFrames(display, code: 0x60).isEmpty)
        #expect(display.value(0x60) == 0x13)
    }

    @Test func anOperationWhoseCallerWasCancelledSendsNothing() async throws {
        let display = SimulatedDisplay.hp()
        let gate = BusGate()
        let channel = DDCChannel(label: "test", timing: .immediate) { () throws(DDCError) -> any DDCBus in
            BlockingBus(display: display, gate: gate)
        }
        gate.arm()
        let stuck = Task { try await channel.read(.brightness) }
        #expect(await eventually { gate.blocked == 1 })
        let queued = Task { try await channel.write(.brightness, value: 5) }
        queued.cancel()
        gate.release()
        _ = try await stuck.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(setFrames(display, code: 0x10).isEmpty)
    }

    /// Cancelling the caller (a monitor going away) stops a capabilities
    /// read between fragments, through `withDeadline`.
    @Test func cancellationReachesACapabilitiesReadInsideADeadline() async throws {
        let caps = try Fixtures.hpCapabilities()
        let display = SimulatedDisplay.hp(capabilities: caps)
        var timing = DDCTiming.immediate
        timing.replyDelay = .milliseconds(5)
        let channel = DDCChannel.simulated(display, timing: timing)
        func fragmentRequests() -> Int {
            display.state.withLock { $0.frames.filter { $0.count > 1 && $0[1] == 0xF3 }.count }
        }
        let read = Task { try await withDeadline(.seconds(20)) { try await readCapabilities(from: channel) } }
        #expect(await eventually { fragmentRequests() >= 4 })
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        try await Task.sleep(for: .milliseconds(30))
        let afterCancel = fragmentRequests()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fragmentRequests() == afterCancel)
        // A whole read is about 60 requests; it stopped well short.
        #expect(afterCancel < 40)
    }

    /// The simulator flags any frame that arrives between a request and the
    /// read of its reply. One channel never produces one, however many tasks
    /// hammer it, and every transaction sends exactly its own frames.
    @Test func transactionsOnOneChannelNeverOverlap() async throws {
        let display = SimulatedDisplay.hp()
        var timing = DDCTiming.immediate
        timing.replyDelay = .milliseconds(1)
        let channel = DDCChannel.simulated(display, timing: timing)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<20 {
                group.addTask { try await channel.write(.brightness, value: UInt16(value)) }
                group.addTask { _ = try await channel.read(.contrast) }
            }
            try await group.waitForAll()
        }
        #expect(display.state.withLock(\.interleaved) == 0)
        // 40 transactions, each frame written twice, no retries needed.
        #expect(display.state.withLock(\.frames).count == 80)
    }

    /// The detector works: two channels on one bus do overlap, which is why
    /// the manager keeps one channel per transport.
    @Test func twoChannelsOnOneBusDoOverlap() async throws {
        let display = SimulatedDisplay.hp()
        var timing = DDCTiming.immediate
        timing.replyDelay = .milliseconds(3)
        let first = DDCChannel.simulated(display, timing: timing)
        let second = DDCChannel.simulated(display, timing: timing)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<15 {
                group.addTask { _ = try? await first.read(.brightness) }
                group.addTask { _ = try? await second.read(.contrast) }
            }
        }
        #expect(display.state.withLock(\.interleaved) > 0)
    }

    /// A Get waits out the pause after a Set of *any* code, not only its own.
    @Test(arguments: [VCPCode.brightness, .contrast])
    func aGetWaitsAfterAnySet(read code: VCPCode) async throws {
        var timing = DDCTiming.immediate
        timing.getAfterSetDelay = .milliseconds(120)
        let channel = DDCChannel.simulated(.hp(), timing: timing)
        // Timed from before the write: the read cannot finish sooner than
        // the delay after the write's own timestamp, whatever the scheduler does.
        let start = ContinuousClock.now
        try await channel.write(.brightness, value: 42)
        _ = try await channel.read(code)
        #expect(start.duration(to: .now) >= .milliseconds(120))
    }

    @Test func theStandardTimingIsTheVerifiedRecipe() {
        let timing = DDCTiming.standard
        #expect(timing.writeRepeats == 2)
        #expect(timing.writeSpacing == .milliseconds(10))
        #expect(timing.replyDelay == .milliseconds(50))
        #expect(timing.postSetDelay == .milliseconds(50))
        #expect(timing.getAfterSetDelay == .milliseconds(200))
        #expect(timing.zeroReadRetryDelay == .milliseconds(150))
        #expect(timing.readAttempts == 4)
        #expect(timing.fragmentAttempts == 6)
    }

    @Test func reopensAfterRepeatedUnansweredReads() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        display.update { $0.readsFail = true }
        _ = try? await channel.read(.brightness)
        _ = try? await channel.read(.brightness)
        display.update { $0.readsFail = false }
        let reading = try await channel.read(.brightness)
        #expect(reading.current == 100)
        #expect(display.state.withLock(\.opens) == 2)
    }

    @Test func aPartialCapabilitiesStringIsKept() async throws {
        let caps = try Fixtures.hpCapabilities()
        let display = SimulatedDisplay.hp(capabilities: caps)
        display.update { $0.capabilitiesFailFrom = 64 }
        let partial = try await readCapabilities(from: DDCChannel.simulated(display))
        #expect(partial == String(caps.prefix(64)))
        #expect(MonitorCapabilities(parsing: partial).model == "HP E27m G4")
    }

    @Test func noCapabilitiesAtAllIsAnError() async {
        let display = SimulatedDisplay.hp(capabilities: "(model(X))")
        display.update { $0.capabilitiesSilent = true }
        await #expect(throws: DDCError.noReply) {
            _ = try await readCapabilities(from: DDCChannel.simulated(display))
        }
    }

    /// MCCS keeps a non-continuous value in the low byte.
    @Test func choicesAndMuteAreReadFromTheLowByte() async throws {
        let display = SimulatedDisplay.hp()
        display.update {
            $0.values[0x60]?.current = 0x0213
            $0.values[0x8D]?.current = 0x0201
        }
        let channel = DDCChannel.simulated(display)
        let input = try await ControlBackend<UInt16>.vcpChoice(.inputSource, on: channel).read()
        #expect(input.value == 0x13)
        let mute = try await ControlBackend<Bool>.vcpMute(on: channel).read()
        #expect(mute.value == true)
    }
}
