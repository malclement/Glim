import Foundation

/// A display that speaks DDC/CI. ``DDCChannel`` is the real one; tests supply
/// their own.
public protocol DDCDevice: Actor {
    /// Reads one VCP code. Throws ``DDCError/unsupported(_:)`` if the display
    /// says it has no such control.
    func read(_ code: VCPCode) throws -> VCPReading
    /// Writes one VCP code. DDC/CI has no acknowledgement for a write, so
    /// success means the frame was accepted by the bus, not that the display
    /// applied it; read the code back to know.
    func write(_ code: VCPCode, value: UInt16) throws
    /// Reads one fragment of the capabilities string. An empty fragment marks
    /// its end.
    func capabilitiesFragment(at offset: UInt16) throws -> [UInt8]
}

/// Timing rules for a DDC/CI conversation. The defaults are the values
/// verified on the HP E27m G4 (docs/ddc-ci-protocol.md, "Reading reliably").
public struct DDCTiming: Sendable, Equatable {
    /// Every frame is written this many times: the display coprocessor
    /// occasionally drops a write. Repeating a request is harmless.
    public var writeRepeats = 2
    /// Pause before each of those writes.
    public var writeSpacing: Duration = .milliseconds(10)
    /// Pause between a request and reading its reply. MCCS asks for at least
    /// 40 ms.
    public var replyDelay: Duration = .milliseconds(50)
    /// Quiet time after a Set before the next message, per MCCS.
    public var postSetDelay: Duration = .milliseconds(50)
    /// A Get of a code sent right after a Set of that code can read 0, so
    /// Glim waits at least this long between the two.
    public var getAfterSetDelay: Duration = .milliseconds(200)
    /// If such a Get still reads 0 within this window after setting a
    /// non-zero value, it is read once more after `zeroReadRetryDelay`.
    public var zeroReadRetryWindow: Duration = .seconds(2)
    public var zeroReadRetryDelay: Duration = .milliseconds(150)
    /// Attempts per Get. Shifted reads are common enough (about one in six
    /// while reading the capabilities string) that one retry is not enough.
    public var readAttempts = 4
    /// Attempts per capabilities fragment.
    public var fragmentAttempts = 6
    /// After this many consecutive transport failures the IOAVService is
    /// reopened on the next operation, in case it went stale across a sleep.
    public var reopenAfterFailures = 3

    public static let standard = DDCTiming()

    /// No pauses at all, for tests against a simulated display.
    public static let immediate = DDCTiming(
        writeSpacing: .zero, replyDelay: .zero, postSetDelay: .zero,
        getAfterSetDelay: .zero, zeroReadRetryDelay: .zero
    )
}

/// One display's DDC/CI channel.
///
/// Each channel runs on its own serial dispatch queue. The I2C calls are
/// synchronous and the protocol needs pauses between them, so a transaction
/// (request, pause, reply) runs to completion with blocking sleeps and no
/// suspension point. That makes every transaction atomic, even though actors
/// are reentrant, and keeps the blocking work off the Swift concurrency
/// thread pool and off the main thread.
public actor DDCChannel: DDCDevice {
    public nonisolated let label: String
    private let queue: DispatchSerialQueue
    private let timing: DDCTiming
    private let openBus: @Sendable () throws(DDCError) -> any DDCBus
    private var bus: (any DDCBus)?
    private let clock = ContinuousClock()
    private var quietUntil: ContinuousClock.Instant?
    private var lastSets: [VCPCode: (value: UInt16, at: ContinuousClock.Instant)] = [:]
    private var consecutiveFailures = 0

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// - Parameter openBus: opens the bus. Called on first use, and again
    ///   after repeated transport failures.
    public init(
        label: String,
        timing: DDCTiming = .standard,
        openBus: @escaping @Sendable () throws(DDCError) -> any DDCBus
    ) {
        self.label = label
        self.timing = timing
        self.openBus = openBus
        self.queue = DispatchSerialQueue(label: "glim.ddc.\(label)", qos: .userInitiated)
    }

    // MARK: DDCDevice

    public func read(_ code: VCPCode) throws -> VCPReading {
        if let last = lastSets[code] {
            wait(until: last.at.advanced(by: timing.getAfterSetDelay))
        }
        var reading = try get(code)
        if reading.current == 0, let last = lastSets[code], last.value != 0,
           last.at.duration(to: clock.now) < timing.zeroReadRetryWindow {
            Log.ddc.debug("\(self.label, privacy: .public) \(code, privacy: .public) read 0 after a set; reading again")
            pause(timing.zeroReadRetryDelay)
            reading = try get(code)
        }
        return reading
    }

    public func write(_ code: VCPCode, value: UInt16) throws {
        try send(DDC.requestFrame(VCPRequest.set(code.rawValue, value: value)))
        let now = clock.now
        lastSets[code] = (value, now)
        quietUntil = now.advanced(by: timing.postSetDelay)
        Log.ddc.debug("\(self.label, privacy: .public) set \(code, privacy: .public) = \(value)")
    }

    public func capabilitiesFragment(at offset: UInt16) throws -> [UInt8] {
        let frame = DDC.requestFrame(CapabilitiesRequest.fragment(at: offset))
        var failure = DDCError.noReply
        for _ in 0..<max(1, timing.fragmentAttempts) {
            do {
                if let payload = try exchange(frame),
                   let fragment = CapabilitiesRequest.parseFragment(payload, expectedOffset: offset) {
                    return fragment
                }
            } catch {
                failure = error
            }
        }
        throw failure
    }

    // MARK: Transactions

    private func get(_ code: VCPCode) throws -> VCPReading {
        let frame = DDC.requestFrame(VCPRequest.get(code.rawValue))
        var failure = DDCError.noReply
        for attempt in 1...max(1, timing.readAttempts) {
            let payload: [UInt8]?
            do {
                payload = try exchange(frame)
            } catch {
                failure = error
                continue
            }
            guard let payload else { continue }
            switch VCPRequest.parseReply(payload, expectedCode: code.rawValue) {
            case .value(let reading):
                return reading
            case .unsupported:
                throw DDCError.unsupported(code)
            case nil:
                Log.ddc.debug("\(self.label, privacy: .public) get \(code, privacy: .public) attempt \(attempt): unexpected payload \(payload.hexString, privacy: .public)")
            }
        }
        Log.ddc.error("\(self.label, privacy: .public) get \(code, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        throw failure
    }

    /// Sends a request and reads its reply. Returns nil for a null message or
    /// an invalid read, both of which the caller retries.
    private func exchange(_ frame: [UInt8]) throws(DDCError) -> [UInt8]? {
        try send(frame)
        pause(timing.replyDelay)
        let raw = try withBus { (bus: any DDCBus) throws(DDCError) -> [UInt8] in
            try bus.read(length: DDC.replyReadLength)
        }
        switch DDC.decodeReply(raw) {
        case .message(let payload):
            return payload
        case .null:
            Log.ddc.debug("\(self.label, privacy: .public) <- null message")
            return nil
        case .invalid(let reason):
            Log.ddc.debug("\(self.label, privacy: .public) <- invalid (\(String(describing: reason), privacy: .public)): \(raw.hexString, privacy: .public)")
            return nil
        }
    }

    /// Writes a frame `writeRepeats` times. Succeeds if any write did.
    private func send(_ frame: [UInt8]) throws(DDCError) {
        if let quietUntil { wait(until: quietUntil) }
        Log.ddc.debug("\(self.label, privacy: .public) -> \(frame.hexString, privacy: .public)")
        var delivered = false
        var failure = DDCError.noReply
        for _ in 0..<max(1, timing.writeRepeats) {
            pause(timing.writeSpacing)
            do {
                try withBus { (bus: any DDCBus) throws(DDCError) in try bus.write(frame) }
                delivered = true
            } catch {
                failure = error
            }
        }
        if !delivered { throw failure }
    }

    /// Runs one bus operation, opening the bus if needed and dropping it after
    /// repeated failures so the next operation reopens it.
    private func withBus<T>(_ body: (any DDCBus) throws(DDCError) -> T) throws(DDCError) -> T {
        let bus: any DDCBus
        if let open = self.bus {
            bus = open
        } else {
            bus = try openBus()
            self.bus = bus
        }
        do {
            let result = try body(bus)
            consecutiveFailures = 0
            return result
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= timing.reopenAfterFailures {
                Log.ddc.info("\(self.label, privacy: .public) reopening after \(self.consecutiveFailures) failures")
                self.bus = nil
                consecutiveFailures = 0
            }
            throw error
        }
    }

    // MARK: Pauses
    //
    // Blocking on purpose: see the type's documentation. They run on this
    // channel's own queue, never on the main thread or the shared pool.

    private func pause(_ duration: Duration) {
        guard duration > .zero else { return }
        Thread.sleep(forTimeInterval: duration.seconds)
    }

    private func wait(until instant: ContinuousClock.Instant) {
        let now = clock.now
        if instant > now { pause(now.duration(to: instant)) }
    }
}

/// Reads the whole capabilities string, one fragment per transaction, so that
/// other commands can run between fragments instead of waiting seconds.
public func readCapabilities(from device: any DDCDevice, maximumLength: Int = 4096) async throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < maximumLength {
        try Task.checkCancellation()
        let fragment = try await device.capabilitiesFragment(at: UInt16(bytes.count))
        if fragment.isEmpty { break }
        bytes.append(contentsOf: fragment)
    }
    // Some displays pad the end with NULs.
    while bytes.last == 0 { bytes.removeLast() }
    return String(decoding: bytes.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

extension Array where Element == UInt8 {
    var hexString: String {
        map { String($0, radix: 16, uppercase: true).leftPadded(to: 2) }.joined(separator: " ")
    }
}
