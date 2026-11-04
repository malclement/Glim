import Foundation

/// Why a DDC/CI operation failed.
public enum DDCError: Error, Equatable, Sendable {
    /// The private IOAVService functions are missing: this is not an Apple
    /// silicon Mac, or a macOS release removed them.
    case transportUnavailable
    /// The display's IOAVService could not be opened. It was probably
    /// disconnected after it was discovered.
    case serviceUnavailable
    /// The I2C write was rejected (IOReturn).
    case writeFailed(Int32)
    /// The I2C read was rejected (IOReturn).
    case readFailed(Int32)
    /// No valid reply arrived after every retry. The display may be asleep,
    /// switched to another input, or have DDC/CI turned off in its menu.
    case noReply
    /// The display reported that it does not support this VCP code.
    case unsupported(VCPCode)
    /// The operation did not finish in time.
    case timedOut

    /// Errors that say something about the link rather than about the
    /// request, so a later attempt may succeed.
    public var isTransient: Bool {
        switch self {
        case .writeFailed, .readFailed, .noReply, .timedOut, .serviceUnavailable: true
        case .transportUnavailable, .unsupported: false
        }
    }
}

extension DDCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            "DDC/CI isn't available on this Mac."
        case .serviceUnavailable:
            "The display is no longer connected."
        case .writeFailed, .readFailed:
            "The display didn't accept the command."
        case .noReply:
            "The display isn't responding."
        case .unsupported(let code):
            "The display doesn't support control \(code)."
        case .timedOut:
            "The display took too long to respond."
        }
    }
}
