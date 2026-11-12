import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// One measured row: a code set on the HP, and what 0x14 and 0x0C read
/// afterwards.
struct ColorMeasurement: CustomTestStringConvertible, Sendable {
    var code: UInt8
    var value: UInt16
    var preset: UInt16
    var temperature: UInt16?

    var testDescription: String { "set \(String(code, radix: 16)) = \(value)" }

    /// `hp-e27m-g4-color-presets.txt`, measured on the hardware.
    static func all() throws -> [ColorMeasurement] {
        try Fixtures.text("hp-e27m-g4-color-presets").split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let pairs = try line.split(separator: " ").map { token -> (String, UInt16) in
                let parts = token.split(separator: "=")
                guard parts.count == 2, let value = UInt16(parts[1]) else { throw FixtureError.missing(String(line)) }
                return (String(parts[0]), value)
            }
            guard let set = pairs.first, let preset = pairs.dropFirst().first(where: { $0.0 == "14" })?.1,
                  let code = UInt8(set.0, radix: 16) else { return nil }
            return ColorMeasurement(code: code, value: set.1, preset: preset,
                                    temperature: pairs.dropFirst().first { $0.0 == "0C" }?.1)
        }
    }
}

/// The color temperature and preset: the HP's measured read-back mapping,
/// how the two codes move together, and the generic fallback.
@Suite @MainActor struct ColorTests {
    private let hp = MonitorProfile.hpE27mG4
    private var presets: ColorPresets { hp.colorPresets! }

    // MARK: Kelvin

    @Test func kelvinIsThreeThousandPlusTheIncrements() throws {
        let scale = try #require(hp.colorTemperature)
        #expect(scale.kelvin(for: 70) == 6500)
        #expect(scale.kelvin(for: 126) == 9300)
        #expect(scale.kelvin(for: 55) == 5750)
        #expect(scale.kelvin(for: 1) == 3050)
        // 0 is "no temperature", not 3000 K.
        #expect(scale.kelvin(for: 0) == nil)
    }

    // MARK: The measured mapping

    @Test func theFixtureHasEveryMeasurement() throws {
        let rows = try ColorMeasurement.all()
        #expect(rows.filter { $0.code == 0x14 }.map(\.value) == Array(1...13))
        #expect(rows.filter { $0.code == 0x0C }.count == 9)
    }

    /// `hp-e27m-g4-color-sequences.txt`: several writes in a row, measured
    /// on the hardware, where the outcome depends on what came before.
    private func measuredSequences() throws -> [(sets: [(UInt8, UInt16)], preset: UInt16, temperature: UInt16)] {
        try Fixtures.text("hp-e27m-g4-color-sequences").split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let pairs = try line.split(separator: " ").map { token -> (UInt8, UInt16) in
                let parts = token.split(separator: "=")
                guard parts.count == 2, let code = UInt8(parts[0], radix: 16), let value = UInt16(parts[1]) else {
                    throw FixtureError.missing(String(line))
                }
                return (code, value)
            }
            guard pairs.count >= 3 else { throw FixtureError.missing(String(line)) }
            let reads = pairs.suffix(2)
            guard reads.first?.0 == 0x14, reads.last?.0 == 0x0C else { throw FixtureError.missing(String(line)) }
            return (Array(pairs.dropLast(2)), reads.first?.1 ?? 0, reads.last?.1 ?? 0)
        }
    }

    /// The simulator has the HP's custom temperature state: every sequence
    /// measured on the hardware reads back the same from it.
    @Test func theSimulatorMatchesTheMeasuredSequences() async throws {
        let sequences = try measuredSequences()
        #expect(sequences.count == 15)
        for sequence in sequences {
            let display = SimulatedDisplay.hp()
            let channel = DDCChannel.simulated(display)
            for (code, value) in sequence.sets { try await channel.write(VCPCode(code), value: value) }
            let preset = try await channel.read(.colorPreset).current
            let temperature = try await channel.read(.colorTemperature).current
            #expect(preset == sequence.preset && temperature == sequence.temperature,
                    "\(sequence.sets) read (\(preset), \(temperature))")
        }
    }

    /// The regression the hardware found: after a temperature set by hand,
    /// 0x14 alone no longer moves 0x0C, so every pick is checked and the
    /// temperature put on a preset's own value.
    @Test(arguments: [UInt16(0x01), 0x02, 0x04, 0x05, 0x08])
    func aPresetPickedFromACustomTemperatureIsRecognized(preset: UInt16) async throws {
        let (monitor, display, manager) = try await readyHP()
        let selector = try #require(monitor.colorPreset)
        monitor.colorTemperature?.set(55)
        #expect(await eventually { selector.currentName == "Custom" })
        #expect(await settled(monitor))
        let option = try #require(selector.options.first { $0.value == preset })
        selector.select(option)
        #expect(await eventually { selector.current == option && selector.isWriting == false })
        #expect(await settled(monitor))
        #expect(display.value(0x14) == option.reading && display.value(0x0C) == option.temperature)
        // The slider follows once it is read again after the pick settles.
        #expect(await eventually { Double(option.temperature ?? 0) == monitor.colorTemperature?.value })
        manager.stop()
    }

    /// From a clean state a pick is one write: nothing extra is sent.
    @Test func aPresetPickedFromAPresetIsOneWrite() async throws {
        let (monitor, display, manager) = try await readyHP()
        let selector = try #require(monitor.colorPreset)
        selector.select(try #require(selector.options.first { $0.value == 0x01 }))
        #expect(await eventually { selector.current?.value == 0x01 && selector.isWriting == false })
        selector.select(try #require(selector.options.first { $0.value == 0x08 }))
        #expect(await eventually { selector.current?.value == 0x08 && selector.isWriting == false })
        #expect(await settled(monitor))
        #expect(sets(display) == ["14=1", "14=8"])
        manager.stop()
    }

    /// Every 0x14 write measured on the HP is recognized as the preset it
    /// selected if Glim offers it, and as something else otherwise. In
    /// particular, reading 2 is 9300 K only together with 0x0C = 126: user 2
    /// also reads 2. 10000 K (09) is the one write that reads exactly like an
    /// offered preset (9300 K): the HP stops at 9300 K, so it is that preset.
    @Test func everyMeasuredPresetIsRecognized() throws {
        let offered = Set(presets.options.map(\.value))
        let sameAs: [UInt16: UInt16] = [0x09: 0x08]
        for row in try ColorMeasurement.all() where row.code == 0x14 {
            let value = presets.value(reading: row.preset, temperature: row.temperature)
            if let preset = offered.contains(row.value) ? row.value : sameAs[row.value] {
                #expect(value == .preset(preset), "\(row.testDescription)")
            } else {
                #expect(value == .other(reading: row.preset, temperature: row.temperature), "\(row.testDescription)")
            }
        }
        #expect(presets.value(reading: 2, temperature: 0) != .preset(0x08))
    }

    /// A temperature set by hand is "Custom", even when 0x14 reports the
    /// bucket of a preset, unless it is exactly that preset's temperature.
    @Test func aTemperatureSetByHandIsCustom() throws {
        let names = try ColorMeasurement.all().filter { $0.code == 0x0C }.map { row in
            presets.name(of: presets.value(reading: row.preset, temperature: row.value))
        }
        // 0, 40, 55, 100, then the bucket edges 1, 41, 70, 71, 126.
        #expect(names == ["Custom RGB", "5000 K", "Custom", "Custom",
                          "Custom", "Custom", "6500 K (factory)", "Custom", "9300 K"])
    }

    @Test func theHPOffersTheUnderstoodPresetsWithTheFactoryOne() {
        #expect(presets.options.map(\.name) == ["sRGB", "Native", "5000 K", "6500 K (factory)", "9300 K"])
        #expect(presets.factory == 0x05)
        #expect(presets.name(of: .other(reading: 6, temperature: 0)) == "Other")
    }

    /// The simulator stands in for the HP in every other test, so it must
    /// answer as the hardware did.
    @Test func theSimulatorMatchesTheMeasurements() async throws {
        for row in try ColorMeasurement.all() {
            let display = SimulatedDisplay.hp()
            let channel = DDCChannel.simulated(display)
            try await channel.write(VCPCode(row.code), value: row.value)
            #expect(try await channel.read(.colorPreset).current == row.preset, "\(row.testDescription)")
            if let temperature = row.temperature {
                #expect(try await channel.read(.colorTemperature).current == temperature, "\(row.testDescription)")
            }
        }
    }

    // MARK: Through the monitor

    private func readyHP() async throws -> (Monitor, SimulatedDisplay, MonitorManager) {
        let platform = FakePlatform()
        let display = platform.connect(DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: Fixtures.hpIdentity))
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.colorTemperature?.value != nil && monitor.colorPreset?.value != nil })
        display.update { $0.frames = [] }
        return (monitor, display, manager)
    }

    /// The Sets the display received, in order, without the repeats.
    private func sets(_ display: SimulatedDisplay) -> [String] {
        var result: [String] = []
        var last: [UInt8]?
        for frame in display.state.withLock(\.frames) where frame.count == 6 && frame[1] == 0x03 {
            if frame != last {
                result.append("\(String(format: "%02X", frame[2]))=\(Int(frame[3]) << 8 | Int(frame[4]))")
            }
            last = frame
        }
        return result
    }

    private func settled(_ monitor: Monitor) async -> Bool {
        await eventually {
            monitor.colorTemperature?.isWriting == false && monitor.colorPreset?.isWriting == false
        }
    }

    @Test func theHPShowsItsFactoryColor() async throws {
        let (monitor, _, manager) = try await readyHP()
        #expect(monitor.colorTemperature?.value == 70)
        #expect(monitor.colorTemperature?.range == 1...126)
        #expect(monitor.colorPreset?.current?.name == "6500 K (factory)")
        #expect(monitor.colorPreset?.factory?.value == 0x05)
        manager.stop()
    }

    /// Picking a preset moves the temperature, so it is read again.
    @Test func pickingAPresetRereadsTheTemperature() async throws {
        let (monitor, display, manager) = try await readyHP()
        let srgb = try #require(monitor.colorPreset?.options.first { $0.name == "sRGB" })
        monitor.colorPreset?.select(srgb)
        #expect(await eventually { monitor.colorTemperature?.value == 0 })
        #expect(monitor.colorPreset?.current == srgb)
        #expect(sets(display) == ["14=1"])
        manager.stop()
    }

    /// Moving the temperature moves the preset's read-back, so it is read
    /// again, and a temperature between presets is "Custom".
    @Test func movingTheTemperatureRereadsThePreset() async throws {
        let (monitor, display, manager) = try await readyHP()
        monitor.colorTemperature?.set(55)
        #expect(await eventually { monitor.colorPreset?.value == .other(reading: 8, temperature: 55) })
        #expect(monitor.colorPreset?.currentName == "Custom")
        #expect(sets(display) == ["0C=55"])

        // Exactly a preset's temperature is that preset.
        monitor.colorTemperature?.set(40)
        #expect(await eventually { monitor.colorPreset?.current?.name == "5000 K" })
        manager.stop()
    }

    /// From a preset without a temperature, the slider first brings back a
    /// preset that has one, then sets the temperature.
    @Test func theSliderLeavesSRGBByItselfOnTheHP() async throws {
        let (monitor, display, manager) = try await readyHP()
        let srgb = try #require(monitor.colorPreset?.options.first { $0.value == 0x01 })
        monitor.colorPreset?.select(srgb)
        #expect(await eventually { monitor.colorTemperature?.value == 0 && monitor.colorPreset?.isWriting == false })
        #expect(await settled(monitor))
        display.update { $0.frames = [] }

        // A lone 0x0C write leaves sRGB on the HP: no preset goes first.
        monitor.colorTemperature?.set(40)
        #expect(await eventually { monitor.colorPreset?.current?.name == "5000 K" })
        #expect(await settled(monitor))
        #expect(sets(display) == ["0C=40"])
        manager.stop()
    }

    /// A monitor whose profile names a Kelvin preset gets it written before
    /// the first temperature, while 0x0C reads 0.
    @Test func aTemperatureFromNoTemperatureGoesThroughTheKelvinPreset() async throws {
        let display = SimulatedDisplay.hp()
        display.update { $0.values[0x0C]?.current = 0; $0.values[0x14]?.current = 1 }
        let device = DDCChannel.simulated(display)
        let backend = ControlBackend<Double>.colorTemperature(
            on: device, scale: ColorTemperatureScale(increment: 50, kelvinPreset: 0x05))
        _ = try await backend.read()
        try await backend.write(40)
        try await backend.write(100)
        #expect(sets(display) == ["14=5", "0C=40", "0C=100"])
    }

    /// The issue's acceptance: sRGB, then 6500 K, is the factory state.
    @Test func sRGBThenTheFactoryPresetRestoresTheFactoryState() async throws {
        let (monitor, display, manager) = try await readyHP()
        let selector = try #require(monitor.colorPreset)
        monitor.colorTemperature?.set(20)
        #expect(await eventually { monitor.colorPreset?.currentName == "Custom" })
        selector.select(try #require(selector.options.first { $0.value == 0x01 }))
        #expect(await eventually { monitor.colorTemperature?.value == 0 && selector.current?.value == 0x01 })
        selector.select(try #require(selector.factory))
        #expect(await eventually { monitor.colorTemperature?.value == 70 && selector.current == selector.factory })
        #expect(display.value(0x14) == 8 && display.value(0x0C) == 70)
        manager.stop()
    }

    @Test func diagnosticsNameTheColor() async throws {
        let (_, _, manager) = try await readyHP()
        let report = manager.diagnosticsReport(appVersion: "test")
        #expect(report.contains("color temperature: 70.0 of 1.0…126.0 (6500 K)"))
        #expect(report.contains("color preset: preset(5) (6500 K (factory))"))
        manager.stop()
    }

    // MARK: Monitors without a profile

    private func generic(_ capabilities: String, values: [UInt8: SimulatedDisplay.Value]) async throws -> (Monitor, MonitorManager) {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array(capabilities.utf8)
            state.values = values.merging([0x10: .init(current: 40, maximum: 100)]) { $1 }
        }
        platform.connect(DiscoveredDisplay(serviceID: 7, framebuffer: "dispext0",
                                           identity: DisplayIdentity(vendorID: 0x10AC, productID: 0x4242)), simulated: simulated)
        let manager = MonitorManager(platform: platform)
        manager.start()
        let monitor = try #require(await eventually { manager.monitors.first != nil } ? manager.monitors.first : nil)
        #expect(await eventually { monitor.status == .ready && monitor.brightness?.value != nil })
        return (monitor, manager)
    }

    @Test func aListedTemperatureAndPresetsAreOffered() async throws {
        let (monitor, manager) = try await generic(
            "(model(Example 27)vcp(0B 0C 10 14(01 05 08 0B)))",
            values: [0x0B: .init(current: 100, maximum: 100), 0x0C: .init(current: 35, maximum: 70),
                     0x14: .init(current: 5, maximum: 13)]
        )
        #expect(await eventually { monitor.colorTemperature?.value == 35 && monitor.colorPreset?.value != nil })
        #expect(monitor.profile.colorTemperature == ColorTemperatureScale(increment: 100, kelvinPreset: 0x05))
        #expect(monitor.profile.colorTemperature?.kelvin(for: 35) == 6500)
        #expect(monitor.colorPreset?.options.map(\.name) == ["sRGB", "6500 K", "9300 K", "User 1"])
        // MCCS: a preset reads back as written.
        #expect(monitor.colorPreset?.current?.name == "6500 K")
        #expect(!monitor.profile.isTested(.colorTemperature) && !monitor.profile.isTested(.colorPreset))
        manager.stop()
    }

    @Test func unlistedColorIsNotOffered() async throws {
        let (monitor, manager) = try await generic(
            "(model(Example 27)vcp(10))",
            values: [0x0B: .init(current: 50, maximum: 50), 0x0C: .init(current: 70, maximum: 126),
                     0x14: .init(current: 5, maximum: 13)]
        )
        #expect(monitor.profile.colorTemperature == nil && monitor.profile.colorPresets == nil)
        #expect(monitor.colorTemperature == nil && monitor.colorPreset == nil)
        manager.stop()
    }

    /// Without 0x0B there is no kelvin to show; presets listed but silent
    /// are dropped like any control that doesn't answer.
    @Test func colorThatDoesNotAnswerIsNotOffered() async throws {
        let (monitor, manager) = try await generic(
            "(model(Example 27)vcp(0B 0C 10 14(01 05)))",
            values: [0x0C: .init(current: 70, maximum: 126)]
        )
        #expect(monitor.profile.colorTemperature == nil)
        #expect(monitor.colorTemperature == nil)
        #expect(await eventually { monitor.colorPreset == nil })
        manager.stop()
    }

    @Test func standardPresetsNeedAChoice() {
        #expect(ColorPresets.standard(listed: [0x05]) == nil)
        #expect(ColorPresets.standard(listed: [0x00, 0x05]) == nil)
        #expect(ColorPresets.standard(listed: [0x05, 0x0E])?.options.map(\.name) == ["6500 K", "Preset 0x0E"])
    }
}

/// A control told when its own writes have settled, so that a control they
/// move can be read again.
@Suite @MainActor struct SettleNotificationTests {
    @Test func settlingAfterWritesIsReportedOnceAndAPlainReadIsNot() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: .zero), quantize: quantizeToSteps)
        var settles = 0
        control.onSettled = { settles += 1 }
        await control.refresh()
        #expect(settles == 0)

        control.set(60)
        control.set(70)
        #expect(await eventually { settles == 1 && !control.isWriting })
        await control.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(settles == 1)
    }

    @Test func aDragSettlesWhenItEnds() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: .zero), quantize: quantizeToSteps)
        var settles = 0
        control.onSettled = { settles += 1 }
        await control.refresh()
        control.setEditing(true)
        control.set(60)
        #expect(await eventually { !control.isWriting })
        #expect(settles == 0)
        control.setEditing(false)
        #expect(await eventually { settles == 1 })
    }
}
