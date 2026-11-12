import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// What Glim keeps must read back across releases: older data that lacks new
/// fields, newer data with fields and cases this release doesn't know, and
/// damaged values, all without losing the rest.
@Suite struct PersistenceTests {
    // MARK: Helpers

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func scenes(_ object: Any) throws -> LossyDecoding<[DisplayScene]> {
        try decodeLossyArray(DisplayScene.self, from: data(object))
    }

    private func adaptive(_ object: Any) throws -> LossyDecoding<[String: AdaptiveSettings]> {
        try decodeLossyDictionary(AdaptiveSettings.self, from: data(object))
    }

    /// Every path to a key of an object inside `object`.
    private func keyPaths(in object: Any, _ prefix: [Any] = []) -> [[Any]] {
        if let dictionary = object as? [String: Any] {
            return dictionary.flatMap { key, value in [prefix + [key]] + keyPaths(in: value, prefix + [key]) }
        }
        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in keyPaths(in: value, prefix + [index]) }
        }
        return []
    }

    private func removing(_ path: [Any], from object: Any) -> Any {
        guard let head = path.first else { return object }
        if let key = head as? String, var dictionary = object as? [String: Any] {
            if path.count == 1 {
                dictionary[key] = nil
            } else if let child = dictionary[key] {
                dictionary[key] = removing(Array(path.dropFirst()), from: child)
            }
            return dictionary
        }
        if let index = head as? Int, var array = object as? [Any] {
            array[index] = removing(Array(path.dropFirst()), from: array[index])
            return array
        }
        return object
    }

    /// `object` with one extra key in every object.
    private func addingUnknownKey(to object: Any) -> Any {
        if var dictionary = object as? [String: Any] {
            for (key, value) in dictionary { dictionary[key] = addingUnknownKey(to: value) }
            dictionary["fromTheFuture"] = ["nested": [1, 2, 3]]
            return dictionary
        }
        if let array = object as? [Any] { return array.map { addingUnknownKey(to: $0) } }
        return object
    }

    // MARK: Fixtures

    @Test func glim030And040ScenesLoadCompletely() throws {
        let decoded = try scenes(json(PersistenceFixtures.scenes))
        #expect(decoded.skipped == 0)
        let scene = try #require(decoded.value.first)
        #expect(decoded.value.count == 1)
        #expect(scene.id == PersistenceFixtures.sceneID)
        #expect(scene.name == "Evening" && scene.symbol == "moon")
        #expect(scene.includes == [.brightness, .color])
        #expect(scene.monitors.count == 2)
        let first = try #require(scene.monitors["HPN-3753-A1"])
        #expect(first.monitorName == "HP E27m")
        #expect(first.brightness == .init(value: 30, maximum: 100))
        #expect(first.contrast == .init(value: 50, maximum: 100))
        #expect(first.color == .preset(value: 5, name: "Warm"))
        let second = try #require(scene.monitors["HPN-3753-B2"])
        #expect(second.brightness == nil && second.contrast == nil)
        #expect(second.color == .temperature(steps: 12, kelvin: 5000))
    }

    @Test func glim040AdaptiveSettingsLoadCompletely() throws {
        let decoded = try adaptive(json(PersistenceFixtures.adaptive))
        #expect(decoded.skipped == 0)
        let settings = try #require(decoded.value["HPN-3753-A1"])
        #expect(settings.isEnabled && !settings.learns && settings.warmsInEvening)
        #expect(settings.source == .followBuiltIn)
        #expect(settings.dayKelvin == 6000 && settings.nightKelvin == 4000)
        #expect(settings.lightCurve.points == [.init(x: 0, y: 0.2), .init(x: 1.5, y: 0.6), .init(x: 3, y: 1)])
        #expect(settings.followCurve == .followDefault)
        #expect(settings.schedule.dayStarts == 400 && settings.schedule.nightStarts == 1260)
        #expect(settings.schedule.dayBrightness == 0.9 && settings.schedule.nightBrightness == 0.35)
    }

    // MARK: Newer data

    @Test func unknownFieldsPartsAndCasesDoNotCostTheRest() throws {
        var scene = try #require(try json(PersistenceFixtures.scenes) as? [[String: Any]])
        scene[0]["includes"] = ["brightness", "hologram", "color"]
        var monitors = try #require(scene[0]["monitors"] as? [String: [String: Any]])
        monitors["HPN-3753-B2"]?["color"] = ["gradient": ["from": 1]]
        scene[0]["monitors"] = monitors
        let decoded = try scenes(addingUnknownKey(to: scene))
        let loaded = try #require(decoded.value.first)
        #expect(decoded.skipped == 0)
        #expect(loaded.includes == [.brightness, .color], "the unknown part is dropped")
        #expect(loaded.monitors["HPN-3753-A1"]?.color == .preset(value: 5, name: "Warm"))
        #expect(loaded.monitors["HPN-3753-B2"]?.color == nil, "the unknown color is left out")
        #expect(loaded.monitors["HPN-3753-B2"]?.monitorName == "Other")
        #expect(loaded.name == "Evening" && loaded.symbol == "moon")

        var stored = try #require(try json(PersistenceFixtures.adaptive) as? [String: [String: Any]])
        stored["HPN-3753-A1"]?["source"] = "telepathy"
        let adapted = try adaptive(addingUnknownKey(to: stored))
        let settings = try #require(adapted.value["HPN-3753-A1"])
        #expect(settings.source == AdaptiveSettings().source, "an unknown source takes the default")
        #expect(settings.isEnabled && settings.nightKelvin == 4000 && settings.schedule.dayStarts == 400)
    }

    // MARK: Older data

    @Test func aBlobWithAnyKeyRemovedStillLoads() throws {
        let sceneBlob = try json(PersistenceFixtures.scenes)
        let sceneKeys = keyPaths(in: sceneBlob).filter { !(($0.last as? String)?.hasPrefix("HPN") ?? false) }
        #expect(sceneKeys.count > 15)
        for path in sceneKeys {
            let decoded = try scenes(removing(path, from: sceneBlob))
            #expect(decoded.value.count == 1 && decoded.skipped == 0, "scenes without \(path)")
        }
        let adaptiveBlob = try json(PersistenceFixtures.adaptive)
        let adaptiveKeys = keyPaths(in: adaptiveBlob).filter { !(($0.last as? String)?.hasPrefix("HPN") ?? false) }
        #expect(adaptiveKeys.count > 15)
        for path in adaptiveKeys {
            let decoded = try adaptive(removing(path, from: adaptiveBlob))
            #expect(decoded.value.count == 1 && decoded.skipped == 0, "adaptive without \(path)")
        }
    }

    @Test func aMissingFieldTakesItsDefaultAndKeepsTheRest() throws {
        let defaults = AdaptiveSettings()
        let fields: [(String, (AdaptiveSettings) -> AnyHashable)] = [
            ("isEnabled", { $0.isEnabled }), ("source", { $0.source }), ("learns", { $0.learns }),
            ("lightCurve", { $0.lightCurve }), ("followCurve", { $0.followCurve }), ("schedule", { $0.schedule }),
            ("warmsInEvening", { $0.warmsInEvening }), ("dayKelvin", { $0.dayKelvin }), ("nightKelvin", { $0.nightKelvin }),
        ]
        let full = try #require(try adaptive(json(PersistenceFixtures.adaptive)).value["HPN-3753-A1"])
        let blob = try #require(try json(PersistenceFixtures.adaptive) as? [String: [String: Any]])
        for (key, read) in fields {
            var stored = blob
            stored["HPN-3753-A1"]?[key] = nil
            let loaded = try #require(try adaptive(stored).value["HPN-3753-A1"])
            #expect(read(loaded) == read(defaults), "\(key) defaults")
            for (other, readOther) in fields where other != key {
                #expect(readOther(loaded) == readOther(full), "\(other) survives the loss of \(key)")
            }
        }
        // Whole scene fields.
        var scene = try #require(try json(PersistenceFixtures.scenes) as? [[String: Any]])
        scene[0]["id"] = nil
        scene[0]["name"] = nil
        scene[0]["includes"] = nil
        let loaded = try #require(try scenes(scene).value.first)
        #expect(loaded.name == "Scene" && loaded.includes == Set(DisplayScene.Part.allCases))
        #expect(loaded.monitors.count == 2 && loaded.symbol == "moon")
    }

    @Test func oneCorruptSceneCostsOnlyItself() throws {
        var scene = try #require(try json(PersistenceFixtures.scenes) as? [Any])
        scene.insert("garbage", at: 0)
        scene.append(42)
        let decoded = try scenes(scene)
        #expect(decoded.value.count == 1 && decoded.skipped == 2)
        #expect(throws: (any Error).self) { try decodeLossyArray(DisplayScene.self, from: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try decodeLossyDictionary(AdaptiveSettings.self, from: Data("[]".utf8)) }
    }

    // MARK: Validation

    @Test func aDamagedCurveBecomesAValidOne() throws {
        func curve(_ points: String) throws -> BrightnessCurve {
            try #require(try adaptive(json("{\"a\":{\"lightCurve\":{\"points\":\(points)}}}")).value["a"]).lightCurve
        }
        #expect(try curve("[]") == .lightDefault, "empty falls back to the default")
        #expect(try curve("[{\"x\":1}]") == .lightDefault, "a point without y is dropped, and none is left")
        #expect(try curve("\"nope\"") == .lightDefault)
        let unsorted = try curve("[{\"x\":3,\"y\":0.9},{\"x\":0,\"y\":0.5},{\"x\":1,\"y\":0.2},{\"x\":2,\"y\":7}]")
        #expect(unsorted.points.map(\.x) == [0, 1, 2, 3])
        #expect(unsorted.points.map(\.y) == [0.5, 0.5, 1, 1], "monotonic and within 0 to 1")
        let single = try curve("[{\"x\":1,\"y\":0.4}]")
        #expect(single.points.count == 2 && single.brightness(at: 0) == 0.4)
        // Same for the follow curve, with its own default.
        let follow = try #require(try adaptive(json("{\"a\":{\"followCurve\":{\"points\":[]}}}")).value["a"]).followCurve
        #expect(follow == .followDefault)
        // Standing alone, a curve with nothing usable is an error, not full brightness.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BrightnessCurve.self, from: Data("{\"points\":[]}".utf8)) }
    }

    @Test func aCurveNeverHoldsNonFiniteValues() throws {
        let curve = BrightnessCurve(points: [.init(x: .nan, y: 0.5), .init(x: 1, y: .infinity), .init(x: 2, y: -3), .init(x: 3, y: 0.7)])
        #expect(curve.points == [.init(x: 2, y: 0), .init(x: 3, y: 0.7)])
        var learned = BrightnessCurve.lightDefault
        learned.learn(x: .nan, y: 0.5)
        learned.learn(x: 1, y: .nan)
        #expect(learned == .lightDefault)
        let empty = BrightnessCurve(points: [])
        #expect(empty.points.count == 2)
        _ = try JSONEncoder().encode(curve)
    }

    @Test func outOfRangeKelvinAndMinutesAreRepaired() throws {
        let stored = """
        {"a":{"dayKelvin":99999,"nightKelvin":12,"schedule":{"dayStarts":-5,"nightStarts":99999,"dayBrightness":3,"nightBrightness":-1}},
         "b":{"dayKelvin":1000,"nightKelvin":10000}}
        """
        let decoded = try adaptive(json(stored)).value
        let a = try #require(decoded["a"])
        #expect(a.dayKelvin == 6500 && a.nightKelvin == 4500, "out of range goes back to the defaults")
        #expect(a.schedule.dayStarts == 0 && a.schedule.nightStarts == 1439)
        #expect(a.schedule.dayBrightness == 1 && a.schedule.nightBrightness == 0)
        let b = try #require(decoded["b"])
        #expect(b.dayKelvin == 1000 && b.nightKelvin == 10000, "the bounds are inside")
    }

    /// Equal times keep their values. The day is zero minutes long, so it is
    /// always night: no division, no loop.
    @Test func equalDayAndNightTimesAreAlwaysNight() throws {
        let decoded = try adaptive(json("{\"a\":{\"schedule\":{\"dayStarts\":480,\"nightStarts\":480}}}")).value
        let schedule = try #require(decoded["a"]).schedule
        #expect(schedule.dayStarts == 480 && schedule.nightStarts == 480)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for hour in 0..<24 {
            let date = Date(timeIntervalSince1970: Double(hour) * 3600 + 1800)
            #expect(schedule.period(at: date, calendar: calendar) == .night)
            let brightness = schedule.brightness(at: date, calendar: calendar)
            #expect(brightness.isFinite && (schedule.nightBrightness...schedule.dayBrightness).contains(brightness))
            #expect(schedule.dayness(at: date, calendar: calendar).isFinite)
        }
    }

    @Test func nonFiniteLevelsAreWrittenAsNumbers() throws {
        var scene = DisplayScene(name: "x", monitors: ["a": .init(monitorName: "A", brightness: .init(value: .nan, maximum: .infinity),
                                                                    color: .temperature(steps: .nan, kelvin: 5000))])
        scene.symbol = nil
        let bytes = try JSONEncoder().encode([scene])
        let back = try decodeLossyArray(DisplayScene.self, from: bytes)
        #expect(back.skipped == 0)
        #expect(back.value.first?.monitors["a"]?.brightness == .init(value: 0, maximum: 100))
        var schedule = DaySchedule()
        schedule.dayBrightness = .nan
        let encoded = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(DaySchedule.self, from: encoded).dayBrightness == DaySchedule().dayBrightness)
    }

    // MARK: Compatibility with 0.4.0

    // The shapes 0.3.0 and 0.4.0 decode with, synthesized as they were.
    private enum OldScenePart: String, Codable { case brightness, contrast, color }
    private struct OldLevel: Codable, Equatable { var value: Double; var maximum: Double }
    private enum OldSceneColor: Codable, Equatable {
        case preset(value: UInt16, name: String)
        case temperature(steps: Double, kelvin: Int)
    }
    private struct OldSceneSettings: Codable, Equatable {
        var monitorName: String
        var brightness: OldLevel?
        var contrast: OldLevel?
        var color: OldSceneColor?
    }
    private struct OldScene: Codable {
        var id: UUID
        var name: String
        var symbol: String?
        var includes: Set<OldScenePart>
        var monitors: [String: OldSceneSettings]
    }
    private struct OldPoint: Codable, Equatable { var x: Double; var y: Double }
    private struct OldCurve: Codable, Equatable { var points: [OldPoint] }
    private struct OldSchedule: Codable, Equatable {
        var dayStarts: Int
        var nightStarts: Int
        var dayBrightness: Double
        var nightBrightness: Double
    }
    private enum OldSource: String, Codable { case lightSensor, followBuiltIn, schedule }
    private struct OldAdaptive: Codable {
        var isEnabled: Bool
        var source: OldSource
        var learns: Bool
        var lightCurve: OldCurve
        var followCurve: OldCurve
        var schedule: OldSchedule
        var warmsInEvening: Bool
        var dayKelvin: Int
        var nightKelvin: Int
    }

    @Test func whatIsWrittenNowReadsWithTheOldShapes() throws {
        let scenes = try decodeLossyArray(DisplayScene.self, from: Data(PersistenceFixtures.scenes.utf8)).value
        let written = try JSONEncoder().encode(scenes)
        let old = try JSONDecoder().decode([OldScene].self, from: written)
        let before = try JSONDecoder().decode([OldScene].self, from: Data(PersistenceFixtures.scenes.utf8))
        #expect(old.count == 1)
        #expect(old[0].id == before[0].id && old[0].name == before[0].name && old[0].symbol == before[0].symbol)
        #expect(old[0].includes == before[0].includes && old[0].monitors == before[0].monitors)

        let stored = try decodeLossyDictionary(AdaptiveSettings.self, from: Data(PersistenceFixtures.adaptive.utf8)).value
        let adaptiveBytes = try JSONEncoder().encode(stored)
        let oldAdaptive = try JSONDecoder().decode([String: OldAdaptive].self, from: adaptiveBytes)
        let oldBefore = try JSONDecoder().decode([String: OldAdaptive].self, from: Data(PersistenceFixtures.adaptive.utf8))
        let now = try #require(oldAdaptive["HPN-3753-A1"]), then = try #require(oldBefore["HPN-3753-A1"])
        #expect(now.isEnabled == then.isEnabled && now.source == then.source && now.learns == then.learns)
        #expect(now.lightCurve == then.lightCurve && now.followCurve == then.followCurve && now.schedule == then.schedule)
        #expect(now.warmsInEvening == then.warmsInEvening && now.dayKelvin == then.dayKelvin && now.nightKelvin == then.nightKelvin)

        // And the key sets are exactly those of 0.4.0, nothing added.
        let object = try #require(try JSONSerialization.jsonObject(with: adaptiveBytes) as? [String: [String: Any]])
        let reference = try #require(try json(PersistenceFixtures.adaptive) as? [String: [String: Any]])
        #expect(Set(object["HPN-3753-A1"]?.keys ?? [:].keys) == Set(reference["HPN-3753-A1"]?.keys ?? [:].keys))
        let sceneObject = try #require(try JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        let sceneReference = try #require(try json(PersistenceFixtures.scenes) as? [[String: Any]])
        #expect(Set(sceneObject[0].keys) == Set(sceneReference[0].keys))
    }

    // MARK: Monitor ids

    @Test func baseAndTransientIDs() {
        let table: [(String, String, Bool)] = [
            ("ABC-1234", "ABC-1234", false),
            ("ABC-1234@dispext1", "ABC-1234", false),
            ("ABC-1234@dispext1#99", "ABC-1234", false),
            ("ABC-1234@77", "ABC-1234", false),
            ("ABC-1234@77#99", "ABC-1234", false),
            ("HPN-3753-A1", "HPN-3753-A1", false),
            ("unidentified-7", "unidentified-7", true),
            ("unidentified-7@dispext0", "unidentified-7", true),
            ("ABC-1234#99", "ABC-1234#99", false),
            ("ABC-1234@", "ABC-1234@", false),
            ("ABC-1234@dispext1#", "ABC-1234@dispext1#", false),
            ("ABC-1234@dispext1#x", "ABC-1234@dispext1#x", false),
            ("@dispext0", "@dispext0", false),
            ("", "", false),
        ]
        for (id, base, transient) in table {
            #expect(baseMonitorID(id) == base, "base of \(id)")
            #expect(isTransientMonitorID(id) == transient, "transient \(id)")
        }
    }

    /// The ids the manager really gives identical monitors without a serial.
    @Test @MainActor func baseIDOfWhatMonitorKeysProduces() {
        let twin = DisplayIdentity(vendorID: 0x220E, productID: 0x3753)
        let key = twin.stableKey
        #expect(key == "HPN-3753")
        let lone = MonitorManager.monitorKeys(for: [DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: twin)])
        #expect(lone == [key])
        let pair = MonitorManager.monitorKeys(for: [
            DiscoveredDisplay(serviceID: 1, framebuffer: "dispext0", identity: twin),
            DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: twin),
        ])
        #expect(pair == [key + "@dispext0", key + "@dispext1"])
        let samePipe = MonitorManager.monitorKeys(for: [
            DiscoveredDisplay(serviceID: 10, framebuffer: "dispext0", identity: twin),
            DiscoveredDisplay(serviceID: 11, framebuffer: "dispext0", identity: twin),
        ])
        #expect(samePipe == [key + "@dispext0#10", key + "@dispext0#11"])
        let noPipe = MonitorManager.monitorKeys(for: [
            DiscoveredDisplay(serviceID: 5, framebuffer: nil, identity: twin),
            DiscoveredDisplay(serviceID: 6, framebuffer: nil, identity: twin),
        ])
        #expect(noPipe == [key + "@5", key + "@6"])
        for id in pair + samePipe + noPipe + lone { #expect(baseMonitorID(id) == key) }
        let unknown = MonitorManager.monitorKeys(for: [DiscoveredDisplay(serviceID: 7)])
        #expect(unknown == ["unidentified-7"] && isTransientMonitorID(unknown[0]))
        // A real serial is left alone.
        let serial = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "CN-1#2")
        #expect(baseMonitorID(serial.stableKey) == serial.stableKey)
    }

    @Test func lookupsFindTheEntryOfTheTwin() {
        let entries = ["K": "lone", "J@dispext1": "sibling", "J@dispext0": "first"]
        #expect(monitorValue(in: entries, for: "K") == "lone")
        #expect(monitorValue(in: entries, for: "K@dispext0") == "lone")
        #expect(monitorValue(in: entries, for: "K@dispext0#4") == "lone")
        #expect(monitorValue(in: entries, for: "J") == "first", "a lone twin takes its sibling's, the first by id")
        #expect(monitorValue(in: entries, for: "J@dispext1") == "sibling", "the exact id wins")
        #expect(monitorValue(in: entries, for: "J@dispext2") == nil, "only a lone twin takes a sibling's")
        #expect(monitorValue(in: entries, for: "Z") == nil)
        #expect(fallbackMonitorValue(in: entries, for: "K") == nil)
        #expect(fallbackMonitorValue(in: entries, for: "K@dispext1") == "lone")
    }

    @Test func aSceneFindsALoneTwinsSettingsForItsSibling() {
        let scene = DisplayScene(name: "x", monitors: ["HPN-3753": .init(monitorName: "HP")])
        #expect(scene.settings(for: "HPN-3753")?.monitorName == "HP")
        #expect(scene.settings(for: "HPN-3753@dispext0")?.monitorName == "HP")
        #expect(scene.settings(for: "HPN-3753@dispext1#9")?.monitorName == "HP")
        #expect(scene.settings(for: "HPN-9999") == nil)
    }
}
