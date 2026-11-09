import Foundation

/// A display that speaks DDC/CI. ``DDCChannel`` is the real one; tests supply
/// their own.
///
/// The requirements are `async` so a test double can suspend; ``DDCChannel``
/// satisfies them with blocking implementations on its own queue.
public protocol DDCDevice: Actor {
    /// Reads one VCP code. Throws ``DDCError/unsupported(_:)`` if the display
    /// says it has no such control.
    func read(_ code: VCPCode) async throws -> VCPReading
    /// Writes one VCP code. DDC/CI has no acknowledgement for a write, so
    /// success means the frame was accepted by the bus, not that the display
    /// applied it; read the code back to know.
    func write(_ code: VCPCode, value: UInt16) async throws
    /// Reads one fragment of the capabilities string. An empty fragment marks
    /// its end.
    func capabilitiesFragment(at offset: UInt16) async throws -> [UInt8]
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
    /// A Get sent right after a Set can read 0, so no Get goes out sooner
    /// than this after any Set. The research saw it for the code just set; it
    /// is applied to every code because nobody checked the others.
    public var getAfterSetDelay: Duration = .milliseconds(200)
    /// If a Get of a code still reads 0 within this window after setting it
    /// to non-zero, it is read again, up to `zeroReadRetries` times, after
    /// `zeroReadRetryDelay` each (as `glim set` does).
    public var zeroReadRetryWindow: Duration = .seconds(2)
    public var zeroReadRetryDelay: Duration = .milliseconds(150)
    public var zeroReadRetries = 2
    /// Attempts per Get. Shifted reads are common enough (about one in six
    /// while reading the capabilities string) that one retry is not enough.
    public var readAttempts = 4
    /// Attempts per capabilities fragment.
    public var fragmentAttempts = 6
    /// After this many consecutive transport failures the IOAVService is
    /// reopened on the next operation, in case it went stale across a sleep.
    public var reopenAfterFailures = 3
    /// Likewise after this many consecutive Gets that got no valid reply,
    /// even if their writes went through.
    public var reopenAfterFailedReads = 2

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
    private var lastSetAt: ContinuousClock.Instant?
    private var consecutiveFailures = 0
    private var consecutiveFailedReads = 0

    /// The only codes Glim ever writes. Anything else is refused here, below
    /// the UI, whatever the caller: some codes blank the screen, turn DDC/CI
    /// off or wipe settings (docs/protocol.md). Extending this is a deliberate
    /// change.
    public static let writableCodes: Set<VCPCode> = [
        .brightness, .contrast, .colorTemperature, .colorPreset, .inputSource, .audioVolume, .audioMute,
    ]

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

    // Every operation checks for cancellation before it touches the bus. An
    // operation whose caller gave up (a timeout, a monitor going away) may
    // still be queued on this actor; it must not run late.

    public func read(_ code: VCPCode) throws -> VCPReading {
        try Task.checkCancellation()
        if let lastSetAt {
            wait(until: lastSetAt.advanced(by: timing.getAfterSetDelay))
        }
        var reading = try get(code)
        var retries = 0
        while reading.current == 0, retries < timing.zeroReadRetries, let last = lastSets[code], last.value != 0,
              last.at.duration(to: clock.now) < timing.zeroReadRetryWindow {
            Log.ddc.debug("\(self.label, privacy: .public) \(code, privacy: .public) read 0 after a set; reading again")
            retries += 1
            pause(timing.zeroReadRetryDelay)
            try Task.checkCancellation()
            reading = try get(code)
        }
        return reading
    }

    public func write(_ code: VCPCode, value: UInt16) throws {
        guard Self.writableCodes.contains(code) else {
            Log.ddc.fault("\(self.label, privacy: .public) refused a write to \(code, privacy: .public)")
            throw DDCError.refused(code)
        }
        try Task.checkCancellation()
        try send(DDC.requestFrame(VCPRequest.set(code.rawValue, value: value)))
        let now = clock.now
        lastSets[code] = (value, now)
        lastSetAt = now
        quietUntil = now.advanced(by: timing.postSetDelay)
        Log.ddc.debug("\(self.label, privacy: .public) set \(code, privacy: .public) = \(value)")
    }

    public func capabilitiesFragment(at offset: UInt16) throws -> [UInt8] {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
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
                consecutiveFailedReads = 0
                return reading
            case .unsupported:
                consecutiveFailedReads = 0
                throw DDCError.unsupported(code)
            case nil:
                Log.ddc.debug("\(self.label, privacy: .public) get \(code, privacy: .public) attempt \(attempt): unexpected payload \(payload.hexString, privacy: .public)")
            }
        }
        Log.ddc.error("\(self.label, privacy: .public) get \(code, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        consecutiveFailedReads += 1
        if consecutiveFailedReads >= timing.reopenAfterFailedReads {
            Log.ddc.info("\(self.label, privacy: .public) reopening after \(self.consecutiveFailedReads) unanswered reads")
            bus = nil
            consecutiveFailedReads = 0
        }
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
///
/// If a fragment fails after others arrived, what arrived is returned, as
/// `glim caps` does: the parser copes with a truncated string, and part of a
/// display's self-description beats none.
public func readCapabilities(from device: any DDCDevice, maximumLength: Int = 4096) async throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < maximumLength {
        try Task.checkCancellation()
        let fragment: [UInt8]
        do {
            fragment = try await device.capabilitiesFragment(at: UInt16(bytes.count))
        } catch let error as DDCError where !bytes.isEmpty {
            Log.ddc.notice("capabilities stopped at \(bytes.count) bytes: \(String(describing: error), privacy: .public)")
            break
        }
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
