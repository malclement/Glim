@testable import GlimCore
import Testing

@Suite struct SkeletonTests {
    @Test func requestFrameMatchesCapture() {
        #expect(DDC.requestFrame([0x01, 0x10]) == [0x82, 0x01, 0x10, 0xAC])
    }
}
