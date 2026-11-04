/// DDC/CI framing (VESA DDC/CI 1.1), as verified on an HP E27m G4 over USB-C.
///
/// Host to display, written with `IOAVServiceWriteI2C(service, 0x37, 0x51, frame)`:
///
///     [0x80 | n] [payload: n bytes] [checksum]     checksum = 0x6E ^ 0x51 ^ every byte before it
///
/// Display to host, read with `IOAVServiceReadI2C(service, 0x37, 0x51, buffer, 40)`:
///
///     [0x6E] [0x80 | n] [payload: n bytes] [checksum]     checksum = 0x50 ^ every byte before it
///
/// The payload starts with an op-code. See docs/protocol.md for the op-codes Glim
/// sends and the replies it accepts.
public enum DDC {
    /// 7-bit I2C address of the display's DDC/CI interface.
    public static let chipAddress: UInt32 = 0x37
    /// The host's source address, passed to the I2C API as the data address.
    public static let hostSubAddress: UInt32 = 0x51
    /// The display's 8-bit write address. Folded into the request checksum and
    /// sent as the first byte of every reply.
    static let displayAddress: UInt8 = 0x6E
    /// The virtual host address that replies are checksummed against.
    static let replyChecksumSeed: UInt8 = 0x50
    /// How many bytes Glim reads for any reply. The longest reply it requests
    /// (a 32-byte capabilities fragment) is 38 bytes on the wire.
    public static let replyReadLength = 40
    /// DDC/CI limits a message payload to 32 bytes plus the op-code and offset.
    static let maximumPayloadLength = 0x7F

    /// Builds the bytes written for one request. `payload` is the op-code and
    /// its arguments; it must be at most 127 bytes, which every op-code Glim
    /// sends is by construction.
    public static func requestFrame(_ payload: [UInt8]) -> [UInt8] {
        let length = UInt8(truncatingIfNeeded: min(payload.count, maximumPayloadLength))
        var frame: [UInt8] = [0x80 | length]
        frame.append(contentsOf: payload.prefix(maximumPayloadLength))
        let checksum = frame.reduce(displayAddress ^ UInt8(hostSubAddress), ^)
        frame.append(checksum)
        return frame
    }

    /// Validates a raw read and extracts its payload.
    ///
    /// Reads through the display coprocessor are occasionally shifted: the
    /// buffer starts with part of the request just written, or partway into the
    /// reply. They fail the address, length or checksum check here, and the
    /// caller retries.
    public static func decodeReply(_ raw: [UInt8]) -> ReplyFrame {
        guard raw.count >= 3 else { return .invalid(.truncated) }
        guard raw[0] == displayAddress else { return .invalid(.wrongSourceAddress(raw[0])) }
        let lengthByte = raw[1]
        let length = Int(lengthByte & 0x7F)
        // The timing report (op-code 0x4E) carries a bare length byte 0x06,
        // without the 0x80 bit every other reply sets. Verified on the HP.
        let isBareTimingReply = lengthByte == 0x06 && raw.count > 2 && raw[2] == TimingReport.opCode
        guard lengthByte & 0x80 != 0 || isBareTimingReply else { return .invalid(.missingLengthFlag) }
        guard raw.count >= length + 3 else { return .invalid(.truncated) }
        let checksum = raw[0..<(length + 2)].reduce(replyChecksumSeed, ^)
        guard checksum == raw[length + 2] else { return .invalid(.checksumMismatch) }
        if length == 0 { return .null }
        return .message(Array(raw[2..<(length + 2)]))
    }
}

/// What a raw read turned out to be.
public enum ReplyFrame: Equatable, Sendable {
    /// A valid message; the payload starts with its op-code.
    case message([UInt8])
    /// A valid DDC/CI null message. Displays send it when busy or when they
    /// have nothing to say, for example in answer to an op-code they ignore.
    case null
    /// Not a valid reply. Worth retrying.
    case invalid(InvalidReply)
}

public enum InvalidReply: Equatable, Sendable {
    case truncated
    case wrongSourceAddress(UInt8)
    case missingLengthFlag
    case checksumMismatch
}

// MARK: - VCP feature (op-codes 01 / 02 / 03)

/// The value of one VCP code, from a Get VCP Feature reply.
public struct VCPReading: Equatable, Sendable {
    public let code: UInt8
    /// 0 = set parameter, 1 = momentary (MCCS).
    public let type: UInt8
    public let maximum: UInt16
    public let current: UInt16

    public init(code: UInt8, type: UInt8 = 0, maximum: UInt16, current: UInt16) {
        self.code = code
        self.type = type
        self.maximum = maximum
        self.current = current
    }
}

public enum VCPReply: Equatable, Sendable {
    case value(VCPReading)
    /// The display answered with result code 01: it does not support the code.
    case unsupported(code: UInt8)
}

public enum VCPRequest {
    public static let getOpCode: UInt8 = 0x01
    public static let replyOpCode: UInt8 = 0x02
    public static let setOpCode: UInt8 = 0x03

    public static func get(_ code: UInt8) -> [UInt8] { [getOpCode, code] }

    public static func set(_ code: UInt8, value: UInt16) -> [UInt8] {
        [setOpCode, code, UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// Parses `02 rc code type maxH maxL curH curL`. Returns nil unless the
    /// payload is a reply about `expectedCode`, so a stale or shifted reply for
    /// another code is never mistaken for this one.
    public static func parseReply(_ payload: [UInt8], expectedCode: UInt8) -> VCPReply? {
        guard payload.count >= 8, payload[0] == replyOpCode, payload[2] == expectedCode else { return nil }
        switch payload[1] {
        case 0x00:
            return .value(VCPReading(
                code: expectedCode,
                type: payload[3],
                maximum: UInt16(payload[4]) << 8 | UInt16(payload[5]),
                current: UInt16(payload[6]) << 8 | UInt16(payload[7])
            ))
        case 0x01:
            return .unsupported(code: expectedCode)
        default:
            return nil
        }
    }
}

// MARK: - Capabilities (op-codes F3 / E3)

public enum CapabilitiesRequest {
    public static let requestOpCode: UInt8 = 0xF3
    public static let replyOpCode: UInt8 = 0xE3

    public static func fragment(at offset: UInt16) -> [UInt8] {
        [requestOpCode, UInt8(offset >> 8), UInt8(offset & 0xFF)]
    }

    /// Parses `E3 offH offL data…`. Returns the fragment's bytes (empty at the
    /// end of the string), or nil if the reply is not the fragment requested.
    public static func parseFragment(_ payload: [UInt8], expectedOffset: UInt16) -> [UInt8]? {
        guard payload.count >= 3, payload[0] == replyOpCode else { return nil }
        let offset = UInt16(payload[1]) << 8 | UInt16(payload[2])
        guard offset == expectedOffset else { return nil }
        return Array(payload.dropFirst(3))
    }
}

// MARK: - Timing report (op-codes 07 / 4E)

/// The display's measurement of the incoming video timing.
public struct TimingReport: Equatable, Sendable {
    static let requestOpCode: UInt8 = 0x07
    static let opCode: UInt8 = 0x4E

    public let status: UInt8
    /// Horizontal frequency in Hz.
    public let horizontalHz: Int
    /// Vertical frequency in hundredths of a hertz.
    public let verticalCentiHz: Int

    public var verticalHz: Double { Double(verticalCentiHz) / 100 }
    public var horizontalPositive: Bool { status & 0x02 != 0 }
    public var verticalPositive: Bool { status & 0x01 != 0 }
    public var outOfRange: Bool { status & 0x80 != 0 }

    public static let request: [UInt8] = [requestOpCode]

    /// Parses `4E status hH hL vH vL`. H is in 10 Hz units, V in 0.01 Hz units.
    public static func parse(_ payload: [UInt8]) -> TimingReport? {
        guard payload.count >= 6, payload[0] == opCode else { return nil }
        let h = Int(payload[2]) << 8 | Int(payload[3])
        let v = Int(payload[4]) << 8 | Int(payload[5])
        return TimingReport(status: payload[1], horizontalHz: h * 10, verticalCentiHz: v)
    }
}
