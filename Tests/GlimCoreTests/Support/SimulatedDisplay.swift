import os
@testable import GlimCore

/// A DDC/CI display simulated at the byte level. It checks every frame's
/// checksum and answers the way the HP E27m G4 does, and it can misbehave on
/// demand the way the real transport does (shifted reads, dropped writes).
final class SimulatedDisplay: Sendable {
    struct Value {
        var current: UInt16
        var maximum: UInt16
    }

    struct State {
        var values: [UInt8: Value] = [:]
        var capabilities: [UInt8] = []
        /// Codes that accept writes and ignore them, like the HP's 0x62.
        var ignoresWrites: Set<UInt8> = []
        var reply: [UInt8]?
        /// Every frame written, including repeats.
        var frames: [[UInt8]] = []
        var badChecksums = 0
        var opens = 0
        /// The next N reads come back shifted, starting partway into the
        /// request, as the display coprocessor sometimes does.
        var shiftNextReads = 0
        /// The next N writes fail at the bus.
        var failNextWrites = 0
        /// Every read fails at the bus, like a display that went away.
        var readsFail = false
        /// Nothing is answered: replies are null messages, like a display
        /// with DDC/CI turned off.
        var silent = false
        /// The first Get of a code after a Set of it reads 0 (an HP quirk).
        var zeroAfterSet = false
        var zeroPending: Set<UInt8> = []
    }

    let state: OSAllocatedUnfairLock<State>

    init(_ configure: (inout State) -> Void = { _ in }) {
        var initial = State()
        configure(&initial)
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// A display shaped like the HP E27m G4.
    static func hp(capabilities: String = "") -> SimulatedDisplay {
        SimulatedDisplay { state in
            state.values = [
                0x10: Value(current: 100, maximum: 100),
                0x12: Value(current: 100, maximum: 100),
                0x60: Value(current: 0x13, maximum: 0x13),
                0x62: Value(current: 30, maximum: 100),
                0x8D: Value(current: 2, maximum: 2),
            ]
            state.ignoresWrites = [0x62]
            state.capabilities = Array(capabilities.utf8)
        }
    }

    func value(_ code: UInt8) -> UInt16? {
        state.withLock { $0.values[code]?.current }
    }

    func update(_ change: @Sendable (inout State) -> Void) {
        state.withLock(change)
    }

    /// Opens a bus onto this display, as ``DDCChannel`` does on first use.
    func openBus() -> SimulatedBus {
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
            Self.handle(frame, in: &state)
            return .success(())
        }.get()
    }

    private static func handle(_ frame: [UInt8], in state: inout State) {
        let payload = Array(frame.dropFirst().dropLast())
        switch payload.first {
        case 0x01 where payload.count == 2:
            let code = payload[1]
            if let value = state.values[code] {
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
            state.values[code]?.current = UInt16(payload[2]) << 8 | UInt16(payload[3])
            if state.zeroAfterSet { state.zeroPending.insert(code) }
        case 0xF3 where payload.count == 3:
            let offset = Int(payload[1]) << 8 | Int(payload[2])
            let fragment = state.capabilities.dropFirst(offset).prefix(32)
            state.reply = Self.reply([0xE3, payload[1], payload[2]] + fragment)
        default:
            state.reply = nil
        }
    }

    fileprivate func send(length: Int) throws(DDCError) -> [UInt8] {
        try state.withLock { state -> Result<[UInt8], DDCError> in
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

    static func reply(_ payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x6E, 0x80 | UInt8(payload.count)] + payload
        frame.append(frame.reduce(0x50, ^))
        return frame
    }
}

final class SimulatedBus: DDCBus {
    let display: SimulatedDisplay

    init(display: SimulatedDisplay) {
        self.display = display
    }

    func write(_ frame: [UInt8]) throws(DDCError) {
        try display.receive(frame)
    }

    func read(length: Int) throws(DDCError) -> [UInt8] {
        try display.send(length: length)
    }
}

extension DDCChannel {
    /// A channel onto a simulated display, with no pauses.
    static func simulated(_ display: SimulatedDisplay, timing: DDCTiming = .immediate) -> DDCChannel {
        DDCChannel(label: "test", timing: timing) { () throws(DDCError) -> any DDCBus in
            display.openBus()
        }
    }
}
