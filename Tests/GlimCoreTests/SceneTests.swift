import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// Scenes: what is captured, what is applied, and when one is active.
@Suite @MainActor struct SceneTests {
    private let secondIdentity = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002",
                                                 productName: "HP E27m G4")

    /// Two HPs, every control read. The second starts at brightness 25.
    private func twoHPs() async throws -> (MonitorManager, [SimulatedDisplay]) {
        let platform = FakePlatform()
        let first = platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        let second = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: secondIdentity))
        second.update { $0.values[0x10]?.current = 25 }
        let manager = MonitorManager(platform: platform)
        manager.start()
        let loaded = await eventually {
            manager.monitors.count == 2 && manager.monitors.allSatisfy {
                $0.brightness?.value != nil && $0.contrast?.value != nil && $0.colorPreset?.value != nil
                    && $0.colorTemperature?.value != nil
            }
        }
        try #require(loaded)
        return (manager, [first, second])
    }

    private func idle(_ manager: MonitorManager) async -> Bool {
        await eventually {
            manager.monitors.allSatisfy {
                $0.brightness?.isWriting == false && $0.contrast?.isWriting == false
                    && $0.colorTemperature?.isWriting == false && $0.colorPreset?.isWriting == false
            }
        }
    }

    @Test func aSceneHoldsWhatEachDisplayShows() async throws {
        let (manager, _) = try await twoHPs()
        let scene = DisplayScene.capturing(manager.monitors, name: "Day")
        #expect(scene.includes == [.brightness, .contrast, .color])
        let first = try #require(scene.monitors[manager.monitors[0].id])
        let second = try #require(scene.monitors[manager.monitors[1].id])
        #expect(first.brightness == DisplayScene.Level(value: 100, maximum: 100))
        #expect(second.brightness?.value == 25)
        #expect(first.color == .preset(value: 0x05, name: "6500 K (factory)"))
        #expect(first.monitorName == "HP E27m G4")
        #expect(scene.isActive(on: manager.monitors))
        manager.stop()
    }

    /// A temperature between presets is kept as a temperature; a color that
    /// can't be put back (custom RGB) is left out.
    @Test func colorIsKeptOnlyWhenItCanBePutBack() async throws {
        let (manager, displays) = try await twoHPs()
        let monitor = manager.monitors[0]
        monitor.colorTemperature?.set(55)
        #expect(await eventually { monitor.colorPreset?.currentName == "Custom" })
        #expect(DisplayScene.Settings(capturing: monitor)?.color == .temperature(steps: 55, kelvin: 5750))

        // Writing 0 is what custom RGB reads as; only the simulator does it.
        displays[0].update {
            $0.values[0x0C]?.current = 0
            $0.values[0x14]?.current = 15
        }
        await monitor.refresh()
        #expect(monitor.colorPreset?.currentName == "Custom RGB")
        let settings = try #require(DisplayScene.Settings(capturing: monitor))
        #expect(settings.color == nil)
        #expect(settings.brightness != nil)
        manager.stop()
    }

    @Test func applyingPutsEveryDisplayBack() async throws {
        let (manager, displays) = try await twoHPs()
        let evening = DisplayScene.capturing(manager.monitors, name: "Evening")
        let (first, second) = (manager.monitors[0], manager.monitors[1])
        first.brightness?.set(30)
        first.colorTemperature?.set(40)
        second.brightness?.set(90)
        #expect(await eventually { first.colorPreset?.current?.name == "5000 K" })
        #expect(await idle(manager))
        #expect(!evening.isActive(on: manager.monitors))

        #expect(evening.apply(to: manager.monitors) == 2)
        #expect(await eventually { evening.isActive(on: manager.monitors) })
        #expect(await idle(manager))
        #expect(displays[0].value(0x10) == 100 && displays[1].value(0x10) == 25)
        #expect(displays[0].value(0x14) == 8 && displays[0].value(0x0C) == 70)
        manager.stop()
    }

    @Test func aTemperatureIsAppliedAsATemperature() async throws {
        let (manager, displays) = try await twoHPs()
        let monitor = manager.monitors[0]
        monitor.colorTemperature?.set(55)
        #expect(await eventually { monitor.colorPreset?.currentName == "Custom" })
        #expect(await idle(manager))
        let warm = DisplayScene.capturing([monitor], name: "Warm")
        monitor.colorPreset?.select(try #require(monitor.colorPreset?.options.first { $0.name == "sRGB" }))
        #expect(await eventually { monitor.colorTemperature?.value == 0 })
        #expect(await idle(manager))

        warm.apply(to: manager.monitors)
        #expect(await eventually { warm.isActive(on: manager.monitors) })
        #expect(await idle(manager))
        #expect(displays[0].value(0x0C) == 55)
        manager.stop()
    }

    /// Only the parts a scene includes are applied, and only they decide
    /// whether it is active.
    @Test func partsLeftOutStayAsTheyAre() async throws {
        let (manager, displays) = try await twoHPs()
        var dim = DisplayScene.capturing(manager.monitors, name: "Dim")
        dim.includes = [.brightness]
        let monitor = manager.monitors[0]
        monitor.brightness?.set(10)
        monitor.contrast?.set(60)
        #expect(await idle(manager))
        dim.apply(to: manager.monitors)
        #expect(await eventually { monitor.brightness?.value == 100 })
        #expect(await idle(manager))
        #expect(displays[0].value(0x12) == 60)
        #expect(dim.isActive(on: manager.monitors))
        manager.stop()
    }

    /// A scene saved from a display that is away changes nothing, and
    /// re-saving keeps what it holds for it.
    @Test func displaysThatAreAwayAreSkippedAndKept() async throws {
        let (manager, _) = try await twoHPs()
        var scene = DisplayScene.capturing(manager.monitors, name: "Both")
        let away = manager.monitors[1].id
        let onlyFirst = [manager.monitors[0]]
        #expect(scene.connected(in: onlyFirst).map(\.id) == [manager.monitors[0].id])
        #expect(scene.apply(to: []) == 0)
        #expect(!scene.isActive(on: []))
        scene.recapture(onlyFirst)
        #expect(scene.monitors[away] != nil)
        manager.stop()
    }

    /// A display whose controls were never read has nothing to set: a
    /// write before the first read would go out blind.
    @Test func aDisplayNotYetReadGetsNothing() async throws {
        let platform = FakePlatform()
        platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity),
                         simulated: SimulatedDisplay { $0.silent = true })
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first?.status == .notResponding } ? manager.monitors.first : nil)
        let scene = DisplayScene(name: "Day", monitors: [
            monitor.id: .init(monitorName: "HP E27m G4", brightness: .init(value: 50, maximum: 100),
                              color: .preset(value: 0x01, name: "sRGB")),
        ])
        #expect(scene.connected(in: manager.monitors).count == 1)
        #expect(scene.apply(to: manager.monitors) == 0)
        #expect(monitor.brightness?.value == nil)
        manager.stop()
    }

    /// Scenes saved before scenes had a symbol still load, with the default.
    @Test func aSceneWithoutASymbolStillDecodes() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old","includes":["brightness"],"monitors":{}}"#
        let scene = try JSONDecoder().decode(DisplayScene.self, from: Data(json.utf8))
        #expect(scene.symbol == nil && scene.shownSymbol == DisplayScene.defaultSymbol)
        #expect(scene.includes == [.brightness])
    }

    @Test func scenesSurviveEncoding() throws {
        let scene = DisplayScene(name: "Evening", symbol: "moon", includes: [.brightness, .color], monitors: [
            "HPN-3753-1": .init(monitorName: "HP E27m G4", brightness: .init(value: 30, maximum: 100),
                                color: .temperature(steps: 40, kelvin: 5000)),
            "AOC-1": .init(monitorName: "U34G2G4R3", contrast: .init(value: 50, maximum: 100),
                           color: .preset(value: 1, name: "sRGB")),
        ])
        let decoded = try JSONDecoder().decode(DisplayScene.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
    }

    // MARK: The temperature increment

    /// A lost 0x0B read costs the temperature only until the monitor is
    /// read again, as a lost capabilities string does.
    @Test func aMissedIncrementIsReadAgain() async throws {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array("(model(AOCCU34G2X)vcp(0B 0C 10 14(01 05 06 08 0B)))".utf8)
            state.values = [
                0x0B: .init(current: 100, maximum: 0), 0x0C: .init(current: 35, maximum: 63),
                0x10: .init(current: 50, maximum: 100), 0x14: .init(current: 5, maximum: 11),
            ]
            state.silentCodes = [0x0B]
        }
        platform.connect(DiscoveredDisplay(serviceID: 3, framebuffer: "dispext0",
                                           identity: DisplayIdentity(vendorID: 0x05E3, productID: 0x3402)), simulated: simulated)
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.status == .ready && monitor.colorPreset?.value != nil })
        #expect(monitor.colorTemperature == nil)

        simulated.update { $0.silentCodes = [] }
        await monitor.refresh()
        #expect(await eventually { monitor.colorTemperature?.value == 35 })
        // The AOC's own numbers: 100 K per step, 35 is 6500 K, 63 is 9300 K.
        #expect(monitor.profile.colorTemperature?.kelvin(for: 35) == 6500)
        #expect(monitor.profile.colorTemperature?.kelvin(for: 63) == 9300)
        #expect(monitor.colorPreset?.options.map(\.name) == ["sRGB", "6500 K", "7500 K", "9300 K", "User 1"])
        manager.stop()
    }

    /// A monitor that says it has no 0x0B is not asked again.
    @Test func anUnsupportedIncrementIsNotReadAgain() async throws {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array("(model(X)vcp(0B 0C 10))".utf8)
            state.values = [0x0C: .init(current: 35, maximum: 63), 0x10: .init(current: 50, maximum: 100)]
        }
        platform.connect(DiscoveredDisplay(serviceID: 3, framebuffer: "dispext0",
                                           identity: DisplayIdentity(vendorID: 0x05E3, productID: 0x3402)), simulated: simulated)
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.status == .ready && monitor.brightness?.value != nil })
        func capabilityRequests() -> Int {
            simulated.state.withLock { $0.frames.filter { $0.count > 1 && $0[1] == 0xF3 }.count }
        }
        let before = capabilityRequests()
        await monitor.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(capabilityRequests() == before)
        #expect(monitor.colorTemperature == nil)
        manager.stop()
    }
}
