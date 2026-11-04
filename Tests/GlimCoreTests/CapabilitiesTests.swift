@testable import GlimCore
import Testing

@Suite struct CapabilitiesTests {
    @Test func parsesTheHPString() throws {
        let caps = MonitorCapabilities(parsing: try Fixtures.hpCapabilities())
        #expect(caps.model == "HP E27m G4")
        #expect(caps.displayType == "LCD")
        #expect(caps.mccsVersion == "2.2")
        #expect(caps.commands == [0x01, 0x02, 0x03, 0x07, 0x0C, 0xE3, 0xF3])
        #expect(caps.lists(.brightness))
        #expect(caps.lists(.contrast))
        #expect(caps.lists(.audioVolume))
        #expect(caps.values(for: .inputSource) == [0x0F, 0x11, 0x13])
        #expect(caps.values(for: .audioMute) == [0x01, 0x02])
        // 0x14 answers a Get on this monitor but is not listed.
        #expect(!caps.lists(VCPCode(0x14)))
        #expect(caps.vcp.count == 46)
    }

    @Test func parsesHPNestedSubCodes() throws {
        let caps = MonitorCapabilities(parsing: try Fixtures.hpCapabilities())
        let e1 = try #require(caps.entry(for: VCPCode(0xE1)))
        let ddcci = try #require(e1.values.first { $0.code == 0x04 })
        #expect(ddcci.values.map(\.code) == [0x00, 0x01, 0x03, 0x04, 0x06, 0x08, 0x09, 0x0A])
        let usbC = try #require(e1.values.first { $0.code == 0x39 })
        #expect(usbC.values.map(\.code) == [0x08, 0x09])
        // Sub-codes with no value list.
        #expect(e1.values.first { $0.code == 0x3B }?.values == [])
        let preset = try #require(caps.entry(for: VCPCode(0xDC))?.values.first)
        #expect(preset.code == 0x00)
        #expect(preset.values.map(\.code) == [0x00, 0x12, 0x13, 0x14, 0x15, 0x1D, 0x1E])
    }

    @Test func toleratesMissingOuterParentheses() {
        let caps = MonitorCapabilities(parsing: "prot(monitor)type(lcd)model(X1)cmds(01 02)vcp(10 12 60(11 12))mccs_ver(2.1)")
        #expect(caps.model == "X1")
        #expect(caps.values(for: .inputSource) == [0x11, 0x12])
        #expect(caps.mccsVersion == "2.1")
    }

    @Test func toleratesRunTogetherHexAndOddSpacing() {
        let caps = MonitorCapabilities(parsing: "(vcp(021012 14( 05 08 0B ) 60 ( 0f 11 )))")
        #expect(caps.vcp.map(\.code) == [0x02, 0x10, 0x12, 0x14, 0x60])
        #expect(caps.values(for: VCPCode(0x14)) == [0x05, 0x08, 0x0B])
        #expect(caps.values(for: .inputSource) == [0x0F, 0x11])
    }

    @Test func survivesUnbalancedAndGarbage() {
        let unbalanced = MonitorCapabilities(parsing: "(model(Broken)vcp(10 12 60(0F 11")
        #expect(unbalanced.model == "Broken")
        #expect(unbalanced.lists(.brightness))
        #expect(unbalanced.values(for: .inputSource) == [0x0F, 0x11])

        let garbage = MonitorCapabilities(parsing: "\u{1}\u{2}))((zz")
        #expect(garbage.vcp.isEmpty)
        #expect(MonitorCapabilities(parsing: "").vcp.isEmpty)
    }

    @Test func oddTrailingDigitIsDropped() {
        #expect(MonitorCapabilities.parseEntries("10 1").map(\.code) == [0x10])
    }
}
