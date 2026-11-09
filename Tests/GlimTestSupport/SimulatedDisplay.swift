import Dispatch
import os
import GlimCore

/// A DDC/CI display simulated at the byte level. It checks every frame's
/// checksum and answers the way the HP E27m G4 does, and it can misbehave on
/// demand the way the real transport does (shifted reads, dropped writes).
package final class SimulatedDisplay: Sendable {
    package struct Value {
        package var current: UInt16
        package var maximum: UInt16

        package init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }
    }

    package struct State {
        package var values: [UInt8: Value] = [:]
        package var capabilities: [UInt8] = []
        /// Codes that accept writes and ignore them, like the HP's 0x62.
        package var ignoresWrites: Set<UInt8> = []
        /// 0x0C and 0x14 move together as on the HP E27m G4, which reads
        /// 0x14 back in its own numbering (``hpColorPresets``).
        package var hpColorCoupling = false
        package var reply: [UInt8]?
        /// Every frame written, including repeats.
        package var frames: [[UInt8]] = []
        package var badChecksums = 0
        package var opens = 0
        /// The next N reads come back shifted, starting partway into the
        /// request, as the display coprocessor sometimes does.
        package var shiftNextReads = 0
        /// The next N writes fail at the bus.
        package var failNextWrites = 0
        /// Every read fails at the bus, like a display that went away.
        package var readsFail = false
        /// Nothing is answered: replies are null messages, like a display
        /// with DDC/CI turned off.
        package var silent = false
        /// Gets of these codes get no answer, while the rest work: a read
        /// lost on a busy bus.
        package var silentCodes: Set<UInt8> = []
        /// The first Get of a code after a Set of it reads 0 (an HP quirk).
        package var zeroAfterSet = false
        package var zeroPending: Set<UInt8> = []
        /// Capabilities requests get no answer, while Gets still work.
        package var capabilitiesSilent = false
        /// Capabilities fragments at or past this offset get no answer.
        package var capabilitiesFailFrom: Int?
        /// Frames that arrived between another request and the read of its
        /// reply: two transactions overlapping on the bus.
        package var interleaved = 0
        package var awaitingReplyTo: [UInt8]?
    }

    package let state: OSAllocatedUnfairLock<State>

    package init(_ configure: (inout State) -> Void = { _ in }) {
        var initial = State()
        configure(&initial)
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// A display shaped like the HP E27m G4.
    package static func hp(capabilities: String = "") -> SimulatedDisplay {
        SimulatedDisplay { state in
            state.values = [
                0x0B: Value(current: 50, maximum: 50),
                0x0C: Value(current: 70, maximum: 126),
                0x10: Value(current: 100, maximum: 100),
                0x12: Value(current: 100, maximum: 100),
                0x14: Value(current: 8, maximum: 12),
                0x60: Value(current: 0x13, maximum: 0x13),
                0x62: Value(current: 30, maximum: 100),
                0x8D: Value(current: 2, maximum: 2),
            ]
            state.ignoresWrites = [0x62]
            state.hpColorCoupling = true
            state.capabilities = Array(capabilities.utf8)
        }
    }

    package func value(_ code: UInt8) -> UInt16? {
        state.withLock { $0.values[code]?.current }
    }

    package func update(_ change: @Sendable (inout State) -> Void) {
        state.withLock(change)
    }

    /// Opens a bus onto this display, as ``DDCChannel`` does on first use.
    package func openBus() -> SimulatedBus {
        state.withLock { $0.opens += 1 }
        return SimulatedBus(display: self)
    }

    // MARK: Wire behaviour

    fileprivate func receive(_ frame: [UInt8]) throws(DDCError) {
        try state.withLock { state -> Result<Void, DDCError> in
            state.frames.append(frame)
            if state.failNextWrites > 0 {
                state.failNextWrites -= 1
                return .failure(.writeFailed(-1))
            }
            guard frame.count >= 2, frame[0] & 0x80 != 0, Int(frame[0] & 0x7F) == frame.count - 2,
                  frame.dropLast().reduce(0x6E ^ 0x51, ^) == frame.last else {
                state.badChecksums += 1
                return .success(())
            }
            // The repeat of the same request is part of one transaction;
            // anything else before the reply is read is another transaction.
            if let pending = state.awaitingReplyTo, pending != frame { state.interleaved += 1 }
            Self.handle(frame, in: &state)
            state.awaitingReplyTo = state.reply == nil ? nil : frame
            return .success(())
        }.get()
    }

    private static func handle(_ frame: [UInt8], in state: inout State) {
        let payload = Array(frame.dropFirst().dropLast())
        switch payload.first {
        case 0x01 where payload.count == 2:
            let code = payload[1]
            if state.silentCodes.contains(code) {
                state.reply = nil
            } else if let value = state.values[code] {
                let current = state.zeroPending.remove(code) != nil ? 0 : value.current
                state.reply = Self.reply([0x02, 0x00, code, 0x00,
                                          UInt8(value.maximum >> 8), UInt8(value.maximum & 0xFF),
                                          UInt8(current >> 8), UInt8(current & 0xFF)])
            } else {
                state.reply = Self.reply([0x02, 0x01, code, 0, 0, 0, 0, 0])
            }
        case 0x03 where payload.count == 4:
            let code = payload[1]
            state.reply = nil
            guard !state.ignoresWrites.contains(code), state.values[code] != nil else { break }
            let value = UInt16(payload[2]) << 8 | UInt16(payload[3])
            state.values[code]?.current = value
            if state.zeroAfterSet { state.zeroPending.insert(code) }
            if state.hpColorCoupling { coupleColor(code: code, value: value, in: &state) }
        case 0xF3 where payload.count == 3:
            let offset = Int(payload[1]) << 8 | Int(payload[2])
            if state.capabilitiesSilent || state.capabilitiesFailFrom.map({ offset >= $0 }) == true {
                state.reply = nil
                break
            }
            let fragment = state.capabilities.dropFirst(offset).prefix(32)
            state.reply = Self.reply([0xE3, payload[1], payload[2]] + fragment)
        default:
            state.reply = nil
        }
    }

    /// What the HP E27m G4 reads back after a 0x14 write: (0x14, 0x0C).
    /// Measured on the hardware (docs/controls.md, "0x14 color-preset
    /// mapping"); the tests check it against the fixture.
    package static let hpColorPresets: [UInt16: (preset: UInt16, temperature: UInt16)] = [
        0x01: (1, 0), 0x02: (10, 0), 0x03: (3, 0), 0x04: (5, 40), 0x05: (8, 70),
        0x06: (6, 0), 0x07: (6, 0), 0x08: (2, 126), 0x09: (2, 126), 0x0A: (11, 0),
        0x0B: (15, 0), 0x0C: (2, 0), 0x0D: (4, 0),
    ]

    /// What 0x14 reads after 0x0C is set to each measured value. Between
    /// them the simulator takes the nearest one, which is a guess: the
    /// bucket edges were never measured.
    package static let hpTemperatureBuckets: [(temperature: UInt16, preset: UInt16)] = [
        (0, 15), (40, 5), (55, 8), (70, 8), (100, 2), (126, 2),
    ]

    private static func coupleColor(code: UInt8, value: UInt16, in state: inout State) {
        switch code {
        case 0x14:
            guard let reading = hpColorPresets[value] else { return }
            state.values[0x14]?.current = reading.preset
            state.values[0x0C]?.current = reading.temperature
        case 0x0C:
            let candidates = hpTemperatureBuckets.filter { ($0.temperature == 0) == (value == 0) }
            let nearest = candidates.min { abs(Int($0.temperature) - Int(value)) < abs(Int($1.temperature) - Int(value)) }
            if let nearest { state.values[0x14]?.current = nearest.preset }
        default:
            break
        }
    }

    fileprivate func send(length: Int) throws(DDCError) -> [UInt8] {
        try state.withLock { state -> Result<[UInt8], DDCError> in
            state.awaitingReplyTo = nil
            if state.readsFail { return .failure(.readFailed(-1)) }
            let reply = state.silent ? Self.reply([]) : (state.reply ?? Self.reply([]))
            var bytes = reply
            if state.shiftNextReads > 0, !state.silent {
                state.shiftNextReads -= 1
                // What the hardware does: part of the request, then the tail
                // of the reply, with no source address in front.
                bytes = [0x01] + reply.dropFirst(4)
            }
            return .success(Array((bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count))).prefix(length)))
        }.get()
    }

    package static func reply(_ payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x6E, 0x80 | UInt8(payload.count)] + payload
        frame.append(frame.reduce(0x50, ^))
        return frame
    }
}

package final class SimulatedBus: DDCBus {
    package let display: SimulatedDisplay

    package init(display: SimulatedDisplay) {
        self.display = display
    }

    package func write(_ frame: [UInt8]) throws(DDCError) {
        try display.receive(frame)
    }

    package func read(length: Int) throws(DDCError) -> [UInt8] {
        try display.send(length: length)
    }
}

extension DDCChannel {
    /// A channel onto a simulated display, with no pauses.
    package static func simulated(_ display: SimulatedDisplay, timing: DDCTiming = .immediate) -> DDCChannel {
        DDCChannel(label: "test", timing: timing) { () throws(DDCError) -> any DDCBus in
            display.openBus()
        }
    }
}

/// Freezes a channel's queue inside a bus read, the way a stuck I2C call
/// would, until released.
package final class BusGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (armed: false, blocked: 0))
    private let semaphore = DispatchSemaphore(value: 0)

    package init() {}

    /// The next read blocks.
    package func arm() {
        state.withLock { $0.armed = true }
    }

    /// How many reads have blocked so far.
    package var blocked: Int {
        state.withLock { $0.blocked }
    }

    package func release() {
        semaphore.signal()
    }

    fileprivate func pass() {
        let wait = state.withLock { state -> Bool in
            guard state.armed else { return false }
            state.armed = false
            state.blocked += 1
            return true
        }
        if wait { semaphore.wait() }
    }
}

/// A simulated display's bus whose reads can be frozen by a ``BusGate``.
package final class BlockingBus: DDCBus {
    private let inner: SimulatedBus
    private let gate: BusGate

    package init(display: SimulatedDisplay, gate: BusGate) {
        inner = display.openBus()
        self.gate = gate
    }

    package func write(_ frame: [UInt8]) throws(DDCError) {
        try inner.write(frame)
    }

    package func read(length: Int) throws(DDCError) -> [UInt8] {
        gate.pass()
        return try inner.read(length: length)
    }
}
