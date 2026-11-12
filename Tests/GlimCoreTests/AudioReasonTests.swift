import CoreAudio
@testable import GlimCore
import GlimTestSupport
import Testing

/// Why a monitor has no USB speakers: read-only, for the UI to explain.
@Suite @MainActor struct AudioReasonTests {
    private let hpAudio = AudioDeviceInfo(id: 97, name: "HP E27m G4 USB Audio", isUSB: true)

    private func started(_ platform: FakePlatform) async -> MonitorManager {
        let manager = MonitorManager(platform: platform)
        manager.start()
        _ = await eventually { !manager.isDiscovering }
        return manager
    }

    @Test func aMonitorWithItsSpeakersHasNoReason() async throws {
        let platform = FakePlatform()
        platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.volume != nil })
        #expect(monitor.audioUnattachedReason == nil)
    }

    @Test func noDeviceIsToldApartFromAnAmbiguousOne() async throws {
        let platform = FakePlatform()
        platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        #expect(monitor.audioUnattachedReason == .noDevice)
        // Two devices for one monitor: nothing says which is its own.
        platform.addAudio(hpAudio)
        platform.addAudio(AudioDeviceInfo(id: 98, name: "HP E27m G4 USB Audio", isUSB: true))
        await manager.refresh()
        #expect(monitor.audioUnattachedReason == .ambiguous)
        #expect(monitor.volume == nil)
    }

    @Test func twoMonitorsOfOneModelAreAmbiguous() async throws {
        let platform = FakePlatform()
        let anonymous = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, serialNumber: 0x0101_0101, productName: "HP E27m G4")
        platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: anonymous))
        platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: anonymous))
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        #expect(manager.monitors.count == 2)
        for monitor in manager.monitors {
            #expect(monitor.audioUnattachedReason == .ambiguous)
        }
    }

    @Test func everySceneSymbolHasAReadableName() {
        for symbol in DisplayScene.symbols {
            let name = DisplayScene.name(ofSymbol: symbol)
            #expect(!name.isEmpty && name != symbol, "\(symbol) has no readable name")
        }
        #expect(Set(DisplayScene.symbols.map(DisplayScene.name(ofSymbol:))).count == DisplayScene.symbols.count, "names are distinct")
        #expect(DisplayScene.name(ofSymbol: DisplayScene.defaultSymbol) != DisplayScene.defaultSymbol)
    }
}
