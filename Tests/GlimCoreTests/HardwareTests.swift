import CoreAudio
import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// Tests against a real HP E27m G4. Off unless `GLIM_HARDWARE_TESTS=1`
/// (`make hardware-test`).
///
/// Every write here was verified as safe and reversible during the reverse
/// engineering (docs/controls.md): brightness, contrast, and the USB Audio
/// level and mute. Each one is restored, even when an expectation fails.
/// Nothing touches the input, power or any vendor code.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIM_HARDWARE_TESTS"] == "1"), .serialized)
struct HardwareTests {
    private func hp() throws -> DiscoveredDisplay {
        let displays = DisplayRegistry.externalDisplays()
        return try #require(displays.first { $0.identity.map { MonitorProfile.known(for: $0) == .hpE27mG4 } ?? false },
                            "no HP E27m G4 among \(displays)")
    }

    private func channel() throws -> any DDCDevice {
        LivePlatform().makeDevice(for: try hp())
    }

    @Test func theTransportIsAvailable() {
        #expect(IOAVServiceAPI.shared != nil)
        #expect(LivePlatform().isDDCAvailable)
    }

    @Test func discoveryIdentifiesTheMonitor() throws {
        let display = try hp()
        let identity = try #require(display.identity)
        #expect(identity.productName == "HP E27m G4")
        #expect(identity.manufacturerCode == "HPN")
        #expect(identity.alphanumericSerial?.isEmpty == false)
        #expect(display.framebuffer?.hasPrefix("dispext") == true)
    }

    @Test func capabilitiesMatchTheCapture() async throws {
        let caps = try await readCapabilities(from: try channel())
        #expect(caps == (try Fixtures.hpCapabilities()))
    }

    @Test func readsTheVerifiedCodes() async throws {
        let device = try channel()
        let brightness = try await device.read(.brightness)
        #expect(brightness.maximum == 100)
        let contrast = try await device.read(.contrast)
        #expect(contrast.maximum == 100)
        let input = try await device.read(.inputSource).current
        #expect([0x0F, 0x11, 0x13].contains(input))
        await #expect(throws: DDCError.unsupported(VCPCode(0xE1))) {
            _ = try await device.read(VCPCode(0xE1))
        }
    }

    @Test(arguments: [VCPCode.brightness, .contrast])
    func levelRoundTrip(code: VCPCode) async throws {
        let device = try channel()
        let original = try await device.read(code).current
        let target: UInt16 = original >= 40 ? original - 7 : original + 7
        try await restoring({ try await device.write(code, value: original) }) {
            try await device.write(code, value: target)
            let written = try await device.read(code).current
            #expect(written == target)
        }
        let restored = try await device.read(code).current
        #expect(restored == original)
    }

    /// A slider drag through the real control: many changes, few writes, and
    /// the monitor ends at the last one.
    @Test @MainActor func aDragEndsAtTheLastValue() async throws {
        let device = try channel()
        let original = try await device.read(.brightness).current
        let control = DeviceControl(backend: .vcpLevel(.brightness, on: device), quantize: quantizeToSteps)
        try await restoring({ try await device.write(.brightness, value: original) }) {
            await control.refresh()
            #expect(control.value == Double(original))
            let start = ContinuousClock.now
            for step in 0..<30 { control.set(Double(max(Int(original) - 30, 40) + step)) }
            let last = control.value
            let settled = await eventually(timeout: .seconds(15)) { !control.isWriting && control.deviceValue == last }
            #expect(settled)
            print("30 changes settled at \(last ?? -1) in \(start.duration(to: .now))")
            let final = try await device.read(.brightness).current
            #expect(Double(final) == last)
        }
    }

    @Test func volumeThroughUSBAudio() async throws {
        let info = try #require(AudioDevices.outputs().first { $0.isUSB && $0.name.hasPrefix("HP E27m G4") })
        let output = CoreAudioOutput(device: info)
        let saved = channelDecibels(info.id)
        #expect(saved.count == 2)
        let ddc = try channel()
        let mirrorBefore = try await ddc.read(.audioVolume).current
        let original = try await output.volume()
        let target = original > 0.5 ? original - 0.2 : original + 0.2
        try await restoring({ setChannelDecibels(info.id, saved) }) {
            try await output.setVolume(target)
            let applied = try await output.volume()
            #expect(abs(applied - target) < 0.02)
            // DDC 0x62 follows the USB level: it is a mirror.
            let mirrored = await eventually(timeout: .seconds(3)) {
                ((try? await ddc.read(.audioVolume).current) ?? mirrorBefore) != mirrorBefore
            }
            #expect(mirrored)
        }
        #expect(channelDecibels(info.id) == saved)
        let mirrorAfter = try await ddc.read(.audioVolume).current
        #expect(mirrorAfter == mirrorBefore)
    }

    @Test func muteThroughUSBAudio() async throws {
        let info = try #require(AudioDevices.outputs().first { $0.isUSB && $0.name.hasPrefix("HP E27m G4") })
        let output = CoreAudioOutput(device: info)
        let original = try await output.isMuted()
        try await restoring({ try await output.setMuted(original) }) {
            try await output.setMuted(!original)
            let muted = try await output.isMuted()
            #expect(muted == !original)
            let mirror = try await channel().read(.audioMute).current
            print("USB mute \(!original): DDC 0x8D reads \(mirror)")
        }
        let restored = try await output.isMuted()
        #expect(restored == original)
    }

    // MARK: Helpers

    private func restoring(
        isolation: isolated (any Actor)? = #isolation,
        _ restore: () async throws -> Void,
        _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            try? await restore()
            throw error
        }
        try await restore()
    }

    /// Per-channel output levels in dB, which restore exactly where the
    /// 0–1 scalar would round.
    private func channelDecibels(_ id: AudioObjectID) -> [Float32] {
        (1...2).compactMap { element in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
    }

    private func setChannelDecibels(_ id: AudioObjectID, _ values: [Float32]) {
        for (index, decibels) in values.enumerated() {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(index + 1))
            var value = decibels
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }
}
