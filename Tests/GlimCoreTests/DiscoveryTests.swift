@testable import GlimCore
import GlimTestSupport
import Testing

/// Joining DDC transports to framebuffer EDIDs, with the registry's shape on
/// an M4 MacBook Air (macOS 26.5): proxy parent `dispextN:dcpav-service-epic:0`,
/// framebuffer parent `dispextN`, the built-in panel on `disp0`.
@Suite struct DiscoveryTests {
    private typealias Proxy = DisplayRegistry.Proxy
    private let other = DisplayIdentity(vendorID: 0x10AC, productID: 0x4242, alphanumericSerial: "OTHER")

    @Test func proxiesJoinTheirFramebufferByPipe() {
        let displays = DisplayRegistry.pair(
            [Proxy(serviceID: 2, pipe: "dispext1"), Proxy(serviceID: 1, pipe: "dispext0")],
            with: ["dispext0": TestIdentity.hp, "dispext1": other]
        )
        #expect(displays.map(\.serviceID) == [1, 2])
        #expect(displays.map(\.identity) == [TestIdentity.hp, other])
        #expect(displays.map(\.framebuffer) == ["dispext0", "dispext1"])
    }

    /// A pipe whose EDID is not published yet keeps its own pipe and waits:
    /// it must not borrow a spare framebuffer's identity.
    @Test func aPipeWithoutItsEDIDYetIsNotPairedByElimination() {
        let framebuffers: [String: DisplayIdentity?] = ["dispext0": nil, "dispext1": other]
        #expect(framebuffers.count == 2)
        let displays = DisplayRegistry.pair([Proxy(serviceID: 1, pipe: "dispext0")], with: framebuffers)
        #expect(displays.first?.framebuffer == "dispext0")
        #expect(displays.first?.identity == nil)
    }

    /// If the naming convention ever breaks, one orphan proxy and one spare
    /// framebuffer can only belong together.
    @Test func aBrokenNameIsPairedByElimination() {
        let displays = DisplayRegistry.pair([Proxy(serviceID: 1, pipe: "renamed-pipe")], with: ["dispext0": TestIdentity.hp])
        #expect(displays.first?.identity == TestIdentity.hp)
        #expect(displays.first?.framebuffer == "dispext0")
    }

    @Test func eliminationNeedsExactlyOneOfEach() {
        let twoOrphans = DisplayRegistry.pair([Proxy(serviceID: 1, pipe: nil), Proxy(serviceID: 2, pipe: nil)],
                                              with: ["dispext0": TestIdentity.hp])
        #expect(twoOrphans.allSatisfy { $0.identity == nil })
        let twoSpares = DisplayRegistry.pair([Proxy(serviceID: 1, pipe: nil)],
                                             with: ["dispext0": TestIdentity.hp, "dispext1": other])
        #expect(twoSpares.first?.identity == nil)
    }

    /// The built-in panel's attributes as this machine's registry has them.
    /// They are rejected because the product ID does not fit 32 bits; the
    /// panel's pipe is also never considered external.
    @Test func theBuiltInPanelIsNotAnIdentity() {
        let builtIn: [String: Any] = [
            "ManufacturerID": "00-10-fa",
            "LegacyManufacturerID": NSNumber(value: 1552),
            "ProductID": NSNumber(value: 53_009_294_898_241 as UInt64),
        ]
        #expect(DisplayRegistry.identity(from: builtIn) == nil)
    }
}

import Foundation
