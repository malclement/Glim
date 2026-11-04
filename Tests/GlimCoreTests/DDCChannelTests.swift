@testable import GlimCore
import GlimTestSupport
import Testing

/// The channel against a byte-level simulated display.
@Suite struct DDCChannelTests {
    @Test func readsAValue() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        let reading = try await channel.read(.brightness)
        #expect(reading == VCPReading(code: 0x10, type: 0, maximum: 100, current: 100))
        #expect(display.state.withLock(\.badChecksums) == 0)
    }

    @Test func writesTheVerifiedFramesTwice() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        try await channel.write(.brightness, value: 60)
        let frames = display.state.withLock(\.frames)
        let expected = DDC.requestFrame([0x03, 0x10, 0x00, 0x3C])
        #expect(frames == [expected, expected])
        #expect(display.value(0x10) == 60)
    }

    @Test func oneDroppedWriteOfTwoStillSucceeds() async throws {
        let display = SimulatedDisplay.hp()
        display.update { $0.failNextWrites = 1 }
        let channel = DDCChannel.simulated(display)
        try await channel.write(.contrast, value: 80)
        #expect(display.value(0x12) == 80)
    }

    @Test func bothWritesDroppedIsAnError() async {
        let display = SimulatedDisplay.hp()
        display.update { $0.failNextWrites = 2 }
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.writeFailed(-1)) {
            try await channel.write(.contrast, value: 80)
        }
    }

    @Test func unsupportedCodeIsReportedWithoutRetrying() async {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.unsupported(VCPCode(0xE1))) {
            try await channel.read(VCPCode(0xE1))
        }
        // One attempt, each frame sent twice.
        #expect(display.state.withLock(\.frames).count == 2)
    }

    @Test func shiftedReadsAreRetried() async throws {
        let display = SimulatedDisplay.hp()
        display.update { $0.shiftNextReads = 3 }
        let channel = DDCChannel.simulated(display)
        let reading = try await channel.read(.audioMute)
        #expect(reading.current == 2)
        // Four attempts of two writes each.
        #expect(display.state.withLock(\.frames).count == 8)
    }

    @Test func persistentGarbageGivesNoReply() async {
        let display = SimulatedDisplay.hp()
        display.update { $0.shiftNextReads = 100 }
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.noReply) {
            try await channel.read(.brightness)
        }
    }

    @Test func silentDisplayGivesNoReply() async {
        let display = SimulatedDisplay.hp()
        display.update { $0.silent = true }
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.noReply) {
            try await channel.read(.brightness)
        }
    }

    @Test func busFailureIsReported() async {
        let display = SimulatedDisplay.hp()
        display.update { $0.readsFail = true }
        let channel = DDCChannel.simulated(display)
        await #expect(throws: DDCError.readFailed(-1)) {
            try await channel.read(.brightness)
        }
    }

    /// The HP quirk: a Get right after a Set can read 0.
    @Test func zeroReadAfterASetIsReadAgain() async throws {
        let display = SimulatedDisplay.hp()
        display.update { $0.zeroAfterSet = true }
        let channel = DDCChannel.simulated(display)
        try await channel.write(.brightness, value: 60)
        #expect(try await channel.read(.brightness).current == 60)
    }

    @Test func realZeroIsNotReadTwice() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        try await channel.write(.brightness, value: 0)
        display.update { $0.frames.removeAll() }
        #expect(try await channel.read(.brightness).current == 0)
        #expect(display.state.withLock(\.frames).count == 2)
    }

    @Test func ignoredWriteReadsBackTheOldValue() async throws {
        // The HP's 0x62 takes writes and ignores them.
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        try await channel.write(.audioVolume, value: 80)
        #expect(try await channel.read(.audioVolume).current == 30)
    }

    @Test func readsTheCapabilitiesStringDespiteShiftedReads() async throws {
        let expected = try Fixtures.hpCapabilities()
        let display = SimulatedDisplay.hp(capabilities: expected)
        let channel = DDCChannel.simulated(display)
        display.update { $0.shiftNextReads = 5 }
        let caps = try await readCapabilities(from: channel)
        #expect(caps == expected)
        #expect(display.state.withLock(\.badChecksums) == 0)
    }

    @Test func capabilitiesTrailingNULsAreStripped() async throws {
        let display = SimulatedDisplay.hp(capabilities: "(model(X))\0\0")
        let caps = try await readCapabilities(from: DDCChannel.simulated(display))
        #expect(caps == "(model(X))")
    }

    /// A service gone stale (after a sleep, say) fails every operation.
    /// Reopening it is the only way back.
    @Test func reopensTheBusAfterRepeatedFailures() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        _ = try await channel.read(.brightness)
        #expect(display.state.withLock(\.opens) == 1)
        display.update {
            $0.readsFail = true
            $0.failNextWrites = 100
        }
        _ = try? await channel.read(.brightness)
        display.update {
            $0.readsFail = false
            $0.failNextWrites = 0
        }
        #expect(try await channel.read(.brightness).current == 100)
        #expect(display.state.withLock(\.opens) > 1)
    }

    /// Writes that get through while reads fail mean the service is fine and
    /// the display is not answering; reopening would not help.
    @Test func doesNotReopenWhileWritesSucceed() async {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        display.update { $0.readsFail = true }
        _ = try? await channel.read(.brightness)
        _ = try? await channel.read(.brightness)
        #expect(display.state.withLock(\.opens) == 1)
    }

    @Test func openFailureIsReported() async {
        let channel = DDCChannel(label: "test", timing: .immediate) { () throws(DDCError) -> any DDCBus in
            throw .serviceUnavailable
        }
        await #expect(throws: DDCError.serviceUnavailable) {
            try await channel.read(.brightness)
        }
    }

    /// With real timing, a Get waits out the post-Set pause.
    @Test func getAfterSetWaitsForTheDisplay() async throws {
        var timing = DDCTiming.immediate
        timing.getAfterSetDelay = .milliseconds(120)
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display, timing: timing)
        try await channel.write(.brightness, value: 42)
        let start = ContinuousClock.now
        #expect(try await channel.read(.brightness).current == 42)
        #expect(start.duration(to: .now) >= .milliseconds(100))
    }

    @Test func transactionsFromManyTasksDoNotInterleave() async throws {
        let display = SimulatedDisplay.hp()
        let channel = DDCChannel.simulated(display)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<20 {
                group.addTask { try await channel.write(.brightness, value: UInt16(value)) }
                group.addTask { _ = try await channel.read(.contrast) }
            }
            try await group.waitForAll()
        }
        // Every frame arrived intact, so no two transactions were interleaved
        // mid-frame, and every read got its own reply.
        #expect(display.state.withLock(\.badChecksums) == 0)
        #expect(try await channel.read(.contrast).current == 100)
    }
}
