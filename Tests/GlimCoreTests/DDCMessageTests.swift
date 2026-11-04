@testable import GlimCore
import GlimTestSupport
import Testing

/// Encoding and decoding, checked against frames captured from the HP E27m G4.
@Suite struct DDCMessageTests {
    // MARK: Requests

    @Test(arguments: [
        ([0x01, 0x10] as [UInt8], [0x82, 0x01, 0x10, 0xAC] as [UInt8]),     // get brightness
        ([0x01, 0x60], [0x82, 0x01, 0x60, 0xDC]),                           // get input
        ([0x01, 0x8D], [0x82, 0x01, 0x8D, 0x31]),                           // get mute
        ([0x07], [0x81, 0x07, 0xB9]),                                       // timing report
        ([0xF3, 0x00, 0x00], [0x83, 0xF3, 0x00, 0x00, 0x4F]),               // capabilities @0
        ([0xF3, 0x03, 0x9A], [0x83, 0xF3, 0x03, 0x9A, 0xD6]),               // capabilities @922
    ])
    func requestFramesMatchTheCapture(payload: [UInt8], frame: [UInt8]) {
        #expect(DDC.requestFrame(payload) == frame)
    }

    @Test func everyCapturedRequestIsReproducedExactly() throws {
        let captures = try Fixtures.hpFrames()
        let written = captures.flatMap(\.written)
        #expect(written.count > 40)
        for frame in written {
            let payload = Array(frame.dropFirst().dropLast())
            #expect(DDC.requestFrame(payload) == frame)
        }
    }

    @Test func setFrameCarriesTheValueBigEndian() {
        let payload = VCPRequest.set(0x10, value: 0x0150)
        #expect(payload == [0x03, 0x10, 0x01, 0x50])
        let frame = DDC.requestFrame(payload)
        #expect(frame.first == 0x84)
        #expect(frame.dropLast().reduce(0x6E ^ 0x51, ^) == frame.last)
    }

    // MARK: Replies

    @Test func brightnessReply() throws {
        let raw = Fixtures.bytes("6E 88 02 00 10 00 00 64 00 64 A4")
        guard case .message(let payload) = DDC.decodeReply(raw) else {
            Issue.record("not a message")
            return
        }
        let reply = VCPRequest.parseReply(payload, expectedCode: 0x10)
        #expect(reply == .value(VCPReading(code: 0x10, type: 0, maximum: 100, current: 100)))
    }

    @Test func inputReplyReadsHPsUSBCValue() {
        guard case .message(let payload) = DDC.decodeReply(Fixtures.bytes("6E 88 02 00 60 00 00 13 00 13 D4")) else {
            Issue.record("not a message")
            return
        }
        #expect(VCPRequest.parseReply(payload, expectedCode: 0x60) == .value(VCPReading(code: 0x60, maximum: 0x13, current: 0x13)))
    }

    @Test func unsupportedCodeReply() {
        guard case .message(let payload) = DDC.decodeReply(Fixtures.bytes("6E 88 02 01 E1 00 00 00 00 00 54")) else {
            Issue.record("not a message")
            return
        }
        #expect(VCPRequest.parseReply(payload, expectedCode: 0xE1) == .unsupported(code: 0xE1))
    }

    @Test func replyForAnotherCodeIsNotAccepted() {
        guard case .message(let payload) = DDC.decodeReply(Fixtures.bytes("6E 88 02 00 12 00 00 64 00 64 A6")) else {
            Issue.record("not a message")
            return
        }
        #expect(VCPRequest.parseReply(payload, expectedCode: 0x10) == nil)
    }

    /// 0xAC: HP firmware drops the top byte of the 24-bit value, so it reads
    /// max=0. The parser reports what was sent; it is not Glim's to fix.
    @Test func horizontalFrequencyQuirkParsesAsSent() {
        guard case .message(let payload) = DDC.decodeReply(Fixtures.bytes("6E 88 02 00 AC 00 00 00 B1 FC 55")) else {
            Issue.record("not a message")
            return
        }
        #expect(VCPRequest.parseReply(payload, expectedCode: 0xAC) == .value(VCPReading(code: 0xAC, maximum: 0, current: 0xB1FC)))
    }

    /// The timing reply's length byte is a bare 0x06 with no 0x80 bit.
    @Test func timingReplyWithBareLengthByteIsAccepted() {
        #expect(DDC.decodeReply(Fixtures.bytes("6E 06 4E 02 2B 66 1D 4C 68")) == .message([0x4E, 0x02, 0x2B, 0x66, 0x1D, 0x4C]))
    }

    @Test func bareLengthIsOnlyAcceptedForTheTimingReply() {
        #expect(DDC.decodeReply(Fixtures.bytes("6E 08 02 00 10 00 00 64 00 64 2C")) == .invalid(.missingLengthFlag))
    }

    @Test func nullMessage() {
        #expect(DDC.decodeReply([0x6E, 0x80, 0xBE] + [UInt8](repeating: 0, count: 37)) == .null)
    }

    @Test func trailingBytesOfA40ByteReadAreIgnored() {
        let raw = Fixtures.bytes("6E 88 02 00 10 00 00 64 00 64 A4") + [UInt8](repeating: 0xFF, count: 29)
        #expect(raw.count == DDC.replyReadLength)
        #expect(DDC.decodeReply(raw) == .message([0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64]))
    }

    @Test func checksumMismatchIsRejected() {
        #expect(DDC.decodeReply(Fixtures.bytes("6E 88 02 00 10 00 00 64 00 63 A4")) == .invalid(.checksumMismatch))
    }

    @Test func truncatedReplyIsRejected() {
        #expect(DDC.decodeReply(Fixtures.bytes("6E 88 02 00 10")) == .invalid(.truncated))
        #expect(DDC.decodeReply([0x6E]) == .invalid(.truncated))
        #expect(DDC.decodeReply([]) == .invalid(.truncated))
    }

    /// Every shifted read in the capture is rejected, and every well-formed
    /// one is accepted.
    @Test func capturedShiftedReadsAreRejected() throws {
        let reads = try Fixtures.hpFrames().flatMap(\.read)
        let shifted = reads.filter { $0.first != 0x6E }
        #expect(shifted.count == 7)
        for raw in shifted {
            guard case .invalid = DDC.decodeReply(raw) else {
                Issue.record("accepted a shifted read: \(raw.hexString)")
                continue
            }
        }
        for raw in reads where raw.first == 0x6E {
            if case .invalid(let why) = DDC.decodeReply(raw) {
                Issue.record("rejected a good read (\(why)): \(raw.hexString)")
            }
        }
    }

    /// Reassembling the captured capabilities fragments, skipping the shifted
    /// reads exactly as the channel does, gives the string on file.
    @Test func capturedFragmentsReassembleIntoTheCapabilitiesString() throws {
        guard let section = try Fixtures.hpFrames().first(where: { $0.section == "caps" }) else {
            Issue.record("no caps section")
            return
        }
        var assembled: [UInt8] = []
        for raw in section.read {
            guard case .message(let payload) = DDC.decodeReply(raw),
                  let fragment = CapabilitiesRequest.parseFragment(payload, expectedOffset: UInt16(assembled.count)) else { continue }
            assembled += fragment
        }
        #expect(String(decoding: assembled, as: UTF8.self) == (try Fixtures.hpCapabilities()))
    }

    @Test func fragmentAtTheWrongOffsetIsRejected() {
        #expect(CapabilitiesRequest.parseFragment([0xE3, 0x00, 0x1A, 0x41], expectedOffset: 0) == nil)
        #expect(CapabilitiesRequest.parseFragment([0xE3, 0x00, 0x1A, 0x41], expectedOffset: 0x1A) == [0x41])
        #expect(CapabilitiesRequest.parseFragment([0xE3, 0x03, 0x9A], expectedOffset: 0x39A) == [])
    }

    @Test func vcpCodeDescription() {
        #expect(VCPCode.brightness.description == "0x10")
        #expect(VCPCode(0x0C).description == "0x0C")
    }

    @Test func inputNames() {
        #expect(InputSourceNames.name(for: 0x0F) == "DisplayPort 1")
        #expect(InputSourceNames.name(for: 0x11) == "HDMI 1")
        #expect(InputSourceNames.name(for: 0x13) == "Input 0x13")
    }
}
