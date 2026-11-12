import Foundation
@testable import Glim
import GlimCore
import GlimTestSupport
import Testing

/// What the store keeps survives releases, partial damage and a second
/// accident, and keeps nothing under an id that changes at every reconnect.
@MainActor struct StorePersistenceTests {
    private func copies(_ defaults: UserDefaults, _ key: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".unreadable") }.sorted()
    }

    // MARK: Fixtures

    @Test func glim030And040DataLoadsCompletely() throws {
        let defaults = try TestDefaults("persist-fixtures")
        defaults.store.set(Data(PersistenceFixtures.scenes.utf8), forKey: GlimStore.scenesKey)
        defaults.store.set(Data(PersistenceFixtures.displays.utf8), forKey: GlimStore.displaysKey)
        defaults.store.set(Data(PersistenceFixtures.adaptive.utf8), forKey: GlimStore.adaptiveKey)
        let store = GlimStore(defaults: defaults.store)
        #expect(store.scenes.map(\.name) == ["Evening"])
        let preferences = store.preferences(for: "HPN-3753-A1")
        #expect(preferences.name == "Desk" && preferences.showsInMenu == false && preferences.rows == ["volume": false])
        #expect(store.loadAdaptive()["HPN-3753-A1"]?.nightKelvin == 4000)
        #expect(copies(defaults.store, GlimStore.scenesKey).isEmpty, "nothing was set aside")
        #expect(copies(defaults.store, GlimStore.displaysKey).isEmpty)
    }

    @Test func newerDisplayPreferencesLoadWithWhatIsUnknownIgnored() throws {
        let defaults = try TestDefaults("persist-newer-displays")
        let blob = #"{"a":{"name":"Desk","future":{"x":1},"rows":{"volume":false,"odd":"text"}},"b":7,"c":{"showsInMenu":"yes"}}"#
        defaults.store.set(Data(blob.utf8), forKey: GlimStore.displaysKey)
        let store = GlimStore(defaults: defaults.store)
        #expect(store.preferences(for: "a").name == "Desk")
        #expect(store.preferences(for: "a").rows == ["volume": false])
        #expect(store.displays["b"] == nil, "an entry that is not an object is skipped")
        #expect(store.displays["c"]?.showsInMenu == nil)
        #expect(copies(defaults.store, GlimStore.displaysKey) == [GlimStore.displaysKey + ".unreadable"], "the original is kept")
    }

    @Test func displayPreferencesLoseNothingWithAnyKeyMissing() throws {
        let full = try #require(try JSONSerialization.jsonObject(with: Data(PersistenceFixtures.displays.utf8)) as? [String: [String: Any]])
        for key in ["name", "rows", "showsInMenu"] {
            var blob = full
            blob["HPN-3753-A1"]?[key] = nil
            let defaults = try TestDefaults("persist-displays-without-\(key)")
            defaults.store.set(try JSONSerialization.data(withJSONObject: blob), forKey: GlimStore.displaysKey)
            let preferences = GlimStore(defaults: defaults.store).preferences(for: "HPN-3753-A1")
            #expect(preferences.name == (key == "name" ? nil : "Desk"), "without \(key)")
            #expect(preferences.showsInMenu == (key == "showsInMenu" ? nil : false), "without \(key)")
            #expect(preferences.rows == (key == "rows" ? [:] : ["volume": false]), "without \(key)")
        }
    }

    // MARK: Element by element

    @Test func oneCorruptSceneCostsOnlyItselfAndTheOriginalIsKept() throws {
        let defaults = try TestDefaults("persist-one-corrupt")
        var elements = try #require(try JSONSerialization.jsonObject(with: Data(PersistenceFixtures.scenes.utf8)) as? [Any])
        elements.insert("garbage", at: 0)
        let original = try JSONSerialization.data(withJSONObject: elements)
        defaults.store.set(original, forKey: GlimStore.scenesKey)
        let store = GlimStore(defaults: defaults.store)
        #expect(store.scenes.map(\.name) == ["Evening"])
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == original)
        // Launching again doesn't pile up the same copy.
        _ = GlimStore(defaults: defaults.store)
        #expect(copies(defaults.store, GlimStore.scenesKey) == [GlimStore.scenesKey + ".unreadable"])
    }

    // MARK: Recovery copies

    @Test func aSecondAccidentDoesNotOverwriteTheFirstCopy() throws {
        let defaults = try TestDefaults("persist-twice")
        let first = Data("first accident".utf8), second = Data("second accident".utf8)
        defaults.store.set(first, forKey: GlimStore.scenesKey)
        _ = GlimStore(defaults: defaults.store)
        defaults.store.set(second, forKey: GlimStore.scenesKey)
        _ = GlimStore(defaults: defaults.store)
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == first)
        let stamped = copies(defaults.store, GlimStore.scenesKey).filter { $0 != GlimStore.scenesKey + ".unreadable" }
        #expect(stamped.count == 1)
        #expect(stamped.first.flatMap { defaults.store.data(forKey: $0) } == second)
        #expect(stamped.first?.hasPrefix(GlimStore.scenesKey + ".unreadable.") == true)
        #expect(defaults.store.data(forKey: GlimStore.scenesKey) == nil)
    }

    @Test func atMostThreeTimestampedCopiesStayAndTheOldestGoFirst() throws {
        let defaults = try TestDefaults("persist-many")
        for number in 1...6 {
            defaults.store.set(Data("accident \(number)".utf8), forKey: GlimStore.scenesKey)
            _ = GlimStore(defaults: defaults.store)
        }
        let all = copies(defaults.store, GlimStore.scenesKey)
        let stamped = all.filter { $0 != GlimStore.scenesKey + ".unreadable" }
        #expect(all.count == 4 && stamped.count == 3)
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == Data("accident 1".utf8))
        let kept = Set(stamped.compactMap { defaults.store.data(forKey: $0) }.map { String(decoding: $0, as: UTF8.self) })
        #expect(kept == ["accident 4", "accident 5", "accident 6"])
    }

    @Test func aRecoveryCopyThatReadsNowComesBack() throws {
        let defaults = try TestDefaults("persist-restore")
        let copy = Data(PersistenceFixtures.scenes.utf8)
        defaults.store.set(copy, forKey: GlimStore.scenesKey + ".unreadable")
        let store = GlimStore(defaults: defaults.store)
        #expect(store.scenes.map(\.name) == ["Evening"])
        #expect(defaults.store.data(forKey: GlimStore.scenesKey) == copy)
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == nil)

        // One that still doesn't read stays where it is.
        let other = try TestDefaults("persist-restore-no")
        other.store.set(Data("still garbage".utf8), forKey: GlimStore.scenesKey + ".unreadable")
        #expect(GlimStore(defaults: other.store).scenes.isEmpty)
        #expect(other.store.data(forKey: GlimStore.scenesKey + ".unreadable") == Data("still garbage".utf8))
        // And one never replaces data that is there.
        let present = try TestDefaults("persist-restore-present")
        present.store.set(copy, forKey: GlimStore.scenesKey + ".unreadable")
        present.store.set(Data("[]".utf8), forKey: GlimStore.scenesKey)
        #expect(GlimStore(defaults: present.store).scenes.isEmpty)
        #expect(present.store.data(forKey: GlimStore.scenesKey + ".unreadable") == copy)
    }

    // MARK: Version marker

    @Test func everySaveWritesTheStoreVersion() throws {
        let defaults = try TestDefaults("persist-version")
        #expect(defaults.store.object(forKey: GlimStore.storeVersionKey) == nil, "0.3 and 0.4 wrote none")
        let store = GlimStore(defaults: defaults.store)
        #expect(defaults.store.object(forKey: GlimStore.storeVersionKey) == nil, "reading changes nothing")
        store.addScene(capturing: [])
        #expect(defaults.store.integer(forKey: GlimStore.storeVersionKey) == 2)
        // A newer marker is read without complaint, and the data loads.
        defaults.store.set(9, forKey: GlimStore.storeVersionKey)
        #expect(GlimStore(defaults: defaults.store).scenes.count == 1)
    }

    // MARK: Compatibility with 0.4.0

    private struct OldDisplayPreferences: Codable, Equatable {
        var name: String?
        var showsInMenu: Bool?
        var rows: [String: Bool]
    }

    @Test func whatIsWrittenNowReadsWithTheOldShape() throws {
        let defaults = try TestDefaults("persist-old-shape")
        let store = GlimStore(defaults: defaults.store)
        store.setName("Desk", for: "HPN-3753-A1")
        store.setShows(.volume, false, for: "HPN-3753-A1")
        store.setName("Other", for: "HPN-3753-B2")
        let bytes = try #require(defaults.store.data(forKey: GlimStore.displaysKey))
        let old = try JSONDecoder().decode([String: OldDisplayPreferences].self, from: bytes)
        #expect(old["HPN-3753-A1"] == OldDisplayPreferences(name: "Desk", showsInMenu: nil, rows: ["volume": false]))
        #expect(old["HPN-3753-B2"] == OldDisplayPreferences(name: "Other", showsInMenu: nil, rows: [:]))
    }

    // MARK: Monitor ids

    @Test func aLoneTwinsPreferencesApplyToItsSiblingAndSetsAreKeptApart() throws {
        let defaults = try TestDefaults("persist-twin")
        let store = GlimStore(defaults: defaults.store)
        store.setName("Left", for: "HPN-3753")
        #expect(store.preferences(for: "HPN-3753@dispext0").name == "Left")
        #expect(store.preferences(for: "HPN-3753@dispext1#9").name == "Left")
        // A write goes to the exact id and shadows the shared one.
        store.setName("Right", for: "HPN-3753@dispext1")
        #expect(store.preferences(for: "HPN-3753@dispext1").name == "Right")
        #expect(store.preferences(for: "HPN-3753@dispext0").name == "Left")
        #expect(Set(store.displays.keys) == ["HPN-3753", "HPN-3753@dispext1"])
        // Clearing an inherited name sticks.
        store.setName("", for: "HPN-3753@dispext0")
        #expect(store.preferences(for: "HPN-3753@dispext0").name == nil)
        // The other way round: a twin's entry serves the lone monitor.
        let reverse = GlimStore(defaults: nil)
        reverse.setName("Only", for: "ABC-1@dispext0")
        #expect(reverse.preferences(for: "ABC-1").name == "Only")
    }

    @Test func nothingIsKeptForADisplayNotIdentifiedYet() throws {
        let defaults = try TestDefaults("persist-transient")
        defaults.store.set(Data(#"{"unidentified-7":{"name":"Ghost"},"HPN-1":{"name":"Real"}}"#.utf8), forKey: GlimStore.displaysKey)
        let store = GlimStore(defaults: defaults.store)
        #expect(store.preferences(for: "unidentified-7").name == nil, "reads return defaults")
        #expect(store.preferences(for: "HPN-1").name == "Real")
        store.setName("Desk", for: "unidentified-7")
        store.setShows(.input, false, for: "unidentified-7")
        #expect(store.preferences(for: "unidentified-7").isEmpty)
        #expect(store.displays.keys.sorted() == ["HPN-1"])
        store.setName("Desk", for: "HPN-1")  // the next real save drops what was stored before
        let saved = try #require(defaults.store.data(forKey: GlimStore.displaysKey))
        #expect(!String(decoding: saved, as: UTF8.self).contains("unidentified"))

        var settings = AdaptiveSettings()
        settings.isEnabled = true
        store.saveAdaptive(["unidentified-7": settings, "HPN-1": settings])
        let loaded = GlimStore(defaults: defaults.store).loadAdaptive()
        #expect(loaded.keys.sorted() == ["HPN-1"])
    }
}
