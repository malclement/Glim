/// Raw access to one display's DDC/CI channel: frames in, raw bytes out.
///
/// A bus is owned by exactly one ``DDCChannel`` and only used on that
/// channel's serial executor, so implementations need not be thread-safe and
/// are deliberately not `Sendable`.
public protocol DDCBus {
    /// Writes one request frame (from ``DDC/requestFrame(_:)``).
    func write(_ frame: [UInt8]) throws(DDCError)
    /// Reads `length` raw bytes of reply.
    func read(length: Int) throws(DDCError) -> [UInt8]
}
