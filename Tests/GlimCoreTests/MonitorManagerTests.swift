import CoreAudio
@testable import GlimCore
import GlimTestSupport
import Testing

/// Discovery, identity and lifecycle, against simulated displays.
@Suite @MainActor struct MonitorManagerTests {
    private let hpAudio = AudioDeviceInfo(id: 97, name: "HP E27m G4 USB Audio", isUSB: true)

    private func hp(serviceID: UInt64 = 1, pipe: String = "dispext0",
                    identity: DisplayIdentity = Fixtures.hpIdentity) -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: pipe, identity: identity)
    }

    private func started(_ platform: FakePlatform) async -> MonitorManager {
        let manager = MonitorManager(platform: platform)
        manager.start()
        _ = await eventually { !manager.isDiscovering }
        return manager
    }

    private func ready(_ monitor: Monitor?) async -> Bool {
        await eventually { monitor?.status == .ready && monitor?.brightness?.value != nil }
    }

    @Test func theHPIsFoundWithItsVerifiedControls() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.addAudio(hpAudio)
        let manager = await started(platform)

        let monitor = try #require(manager.monitors.first)
        #expect(manager.monitors.count == 1)
        #expect(await ready(monitor))
        #expect(monitor.name == "HP E27m G4")
        #expect(manager.title(for: monitor) == "HP E27m G4")
        #expect(monitor.profile == .hpE27mG4)
        #expect(monitor.id == "HPN-3753-TEST0000001")
        #expect(monitor.brightness?.value == 100)
        #expect(await eventually { monitor.contrast?.value == 100 })
        #expect(await eventually { monitor.input?.current?.name == "USB-C" })
        #expect(monitor.input?.options.map(\.name) == ["DisplayPort", "HDMI", "USB-C"])
        // The HP's speakers are its USB Audio device, not DDC 0x62.
        #expect(await eventually { monitor.volume?.value == 0.5 })
        #expect(monitor.audioDeviceName == "HP E27m G4 USB Audio")
        #expect(monitor.capabilitiesString == nil)
    }

    @Test func volumeGoesToTheUSBDevice() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.volume?.value != nil })

        monitor.volume?.set(0.3)
        let output = try #require(platform.output(hpAudio.id))
        #expect(await eventually { await output.volumeWrites == [0.3] })
    }

    @Test func noAudioDeviceMeansNoVolumeControl() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.addAudio(AudioDeviceInfo(id: 5, name: "MacBook Air Speakers", isUSB: false))
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await ready(monitor))
        #expect(monitor.volume == nil)
        #expect(monitor.mute == nil)
    }

    @Test func theUSBDeviceIsPickedUpWhenItAppearsLater() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await ready(monitor))
        #expect(monitor.volume == nil)
        platform.addAudio(hpAudio)
        await manager.refresh()
        #expect(await eventually { monitor.volume?.value == 0.5 })
    }

    /// Two identical monitors and two identical audio devices: nothing says
    /// which speaker is whose, so neither gets a volume control.
    @Test func twoIdenticalMonitorsAreKeptApartAndGetNoVolume() async {
        let platform = FakePlatform()
        let anonymous = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, serialNumber: 0x0101_0101, productName: "HP E27m G4")
        platform.connect(hp(serviceID: 1, pipe: "dispext0", identity: anonymous))
        platform.connect(hp(serviceID: 2, pipe: "dispext1", identity: anonymous))
        platform.addAudio(hpAudio)
        platform.addAudio(AudioDeviceInfo(id: 98, name: "HP E27m G4 USB Audio", isUSB: true))
        let manager = await started(platform)

        #expect(manager.monitors.map(\.id) == ["HPN-3753@dispext0", "HPN-3753@dispext1"])
        #expect(manager.monitors.map(manager.title(for:)) == ["HP E27m G4 (1)", "HP E27m G4 (2)"])
        for monitor in manager.monitors {
            #expect(await ready(monitor))
            #expect(monitor.volume == nil)
        }
    }

    @Test func aMonitorWithoutAProfileUsesItsCapabilities() async throws {
        let platform = FakePlatform()
        let identity = DisplayIdentity(vendorID: 0x10AC, productID: 0x4242, productName: nil)
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array("(prot(monitor)type(LCD)model(Example 27)cmds(01 02 03 F3)vcp(10 12 60(0F 11) 62 8D(01 02)))".utf8)
            state.values = [
                0x10: .init(current: 40, maximum: 100),
                0x12: .init(current: 70, maximum: 100),
                0x60: .init(current: 0x0F, maximum: 0),
                0x62: .init(current: 25, maximum: 100),
                0x8D: .init(current: 2, maximum: 2),
            ]
        }
        platform.connect(DiscoveredDisplay(serviceID: 7, framebuffer: "dispext0", identity: identity), simulated: simulated)
        let manager = await started(platform)

        let monitor = try #require(manager.monitors.first)
        #expect(await ready(monitor))
        #expect(monitor.profile.isGeneric)
        #expect(!monitor.profile.isTested)
        #expect(monitor.name == "Example 27")
        #expect(monitor.brightness?.value == 40)
        #expect(await eventually { monitor.volume?.value == 25 })
        #expect(await eventually { monitor.mute?.value == false })
        #expect(monitor.input?.options.map(\.name) == ["DisplayPort 1", "HDMI 1"])
        #expect(monitor.capabilitiesString?.contains("Example 27") == true)
    }

    @Test func listedControlsThatDoNotAnswerAreDropped() async throws {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array("(vcp(10 12))".utf8)
            state.values = [0x10: .init(current: 40, maximum: 100)]    // no 0x12
        }
        platform.connect(DiscoveredDisplay(serviceID: 7, framebuffer: "dispext0", identity: nil), simulated: simulated)
        let manager = await started(platform)

        let monitor = try #require(manager.monitors.first)
        #expect(await ready(monitor))
        #expect(await eventually { monitor.contrast == nil })
        #expect(monitor.brightness != nil)
        #expect(monitor.name == "External Display")
    }


    /// A replug or a sleep gives the same monitor a new transport. It keeps
    /// its object, so the UI does not flicker, and gets fresh controls on the
    /// new channel.
    @Test func aReconnectedMonitorKeepsItsObject() async throws {
        let platform = FakePlatform()
        platform.connect(hp(serviceID: 1))
        let manager = await started(platform)
        let first = try #require(manager.monitors.first)
        #expect(await ready(first))

        platform.disconnectAll()
        let replacement = SimulatedDisplay.hp()
        replacement.update { $0.values[0x10]?.current = 55 }
        platform.connect(hp(serviceID: 2), simulated: replacement)
        platform.fireChange()

        #expect(await eventually { manager.monitors.first?.brightness?.value == 55 })
        #expect(manager.monitors.first === first)
        #expect(manager.monitors.count == 1)
    }

    @Test func aSilentMonitorIsNotRespondingUntilItAnswers() async throws {
        let platform = FakePlatform()
        let simulated = platform.connect(hp(), simulated: SimulatedDisplay.hp())
        simulated.update { $0.silent = true }
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.status == .notResponding })
        #expect(monitor.brightness?.value == nil)

        simulated.update { $0.silent = false }
        try await Task.sleep(for: .seconds(2.1))   // past the refresh throttle
        await manager.refresh()
        #expect(await ready(monitor))
    }

    @Test func aMacWithoutTheInterfaceIsUnavailable() async {
        let platform = FakePlatform()
        platform.state.withLock { $0.available = false }
        let manager = MonitorManager(platform: platform)
        manager.start()
        guard case .unavailable = manager.availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(manager.monitors.isEmpty)
        #expect(!manager.isDiscovering)
    }

    @Test func stopReleasesEverything() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        let manager = await started(platform)
        #expect(await ready(manager.monitors.first))
        manager.stop()
        #expect(manager.monitors.isEmpty)
        #expect(platform.state.withLock { $0.onChange == nil })
    }

    @Test func monitorKeys() {
        let a = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "A1")
        let b = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "B2")
        let keys = MonitorManager.monitorKeys(for: [
            DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: a),
            DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: b),
            DiscoveredDisplay(serviceID: 3, framebuffer: nil, identity: nil),
        ])
        #expect(keys == ["HPN-3753-A1", "HPN-3753-B2", "unidentified-3"])
    }
}

@Suite struct IdentityAndProfileTests {
    @Test func manufacturerCode() {
        #expect(DisplayIdentity(vendorID: 0x220E, productID: 0).manufacturerCode == "HPN")
        #expect(DisplayRegistry.packedPnP("HPN") == 0x220E)
        #expect(DisplayRegistry.packedPnP("DEL") == 0x10AC)
        #expect(DisplayRegistry.packedPnP("H1N") == nil)
    }

    @Test func stableKeys() {
        #expect(Fixtures.hpIdentity.stableKey == "HPN-3753-TEST0000001")
        #expect(DisplayIdentity(vendorID: 0x220E, productID: 0x3753, serialNumber: 0x0101_0101).stableKey == "HPN-3753")
        #expect(DisplayIdentity(vendorID: 0x220E, productID: 0x3753, serialNumber: 0x1234_ABCD).stableKey == "HPN-3753-1234ABCD")
    }

    /// The shape of the HP's `DisplayAttributes.ProductAttributes`, with the
    /// real serial replaced.
    @Test func identityFromTheRegistry() throws {
        let attributes: [String: Any] = [
            "ManufacturerID": "HPN", "LegacyManufacturerID": NSNumber(value: 8718), "ProductID": NSNumber(value: 14163),
            "SerialNumber": NSNumber(value: 16_843_009), "AlphanumericSerialNumber": "TEST0000001",
            "ProductName": "HP E27m G4", "YearOfManufacture": NSNumber(value: 2023), "WeekOfManufacture": NSNumber(value: 34),
        ]
        let identity = try #require(DisplayRegistry.identity(from: attributes))
        #expect(identity == Fixtures.hpIdentity)
        #expect(MonitorProfile.known(for: identity) == .hpE27mG4)
    }


    @Test func theHPProfileSaysWhatWasTested() {
        let hp = MonitorProfile.hpE27mG4
        #expect(hp.isTested)
        #expect(hp.isTested(.brightness) && hp.isTested(.contrast) && hp.isTested(.volume) && hp.isTested(.mute))
        // Input switching was never tried on the hardware.
        #expect(!hp.isTested(.input))
        #expect(!MonitorProfile.generic(capabilities: nil).isTested(.brightness))
    }

    @Test func profiles() throws {
        #expect(MonitorProfile.known(for: nil) == nil)
        #expect(MonitorProfile.known(for: DisplayIdentity(vendorID: 0x220E, productID: 0x1111)) == nil)

        let generic = MonitorProfile.generic(capabilities: MonitorCapabilities(parsing: try Fixtures.hpCapabilities()))
        #expect(generic.isGeneric)
        #expect(generic.volume == .ddc)
        #expect(generic.inputs?.map(\.name) == ["DisplayPort 1", "HDMI 1", "Input 0x13"])

        let blind = MonitorProfile.generic(capabilities: nil)
        #expect(blind.brightness && blind.contrast)
        #expect(blind.volume == nil)
        #expect(blind.inputs == nil)
        #expect(MonitorProfile.generic(capabilities: MonitorCapabilities(parsing: "(vcp(10 60(0F)))")).inputs == nil)
    }
}

import Foundation
