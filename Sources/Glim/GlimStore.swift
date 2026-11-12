import Foundation
import GlimCore
import Observation
import SwiftUI

/// What one display is called and shows in the menu, when the user changed
/// it. Everything left nil follows the defaults.
struct DisplayPreferences: Codable, Hashable, Sendable {
    /// A name of the user's own, used everywhere instead of the model's.
    var name: String?
    /// False hides the whole display from the menu.
    var showsInMenu: Bool?
    /// Per-row choices, by ``MenuRow`` raw value, over the Settings defaults.
    var rows: [String: Bool] = [:]

    var isEmpty: Bool { name == nil && showsInMenu == nil && rows.isEmpty }
}

// Tolerant: a missing or unreadable field is left at its default.
extension DisplayPreferences {
    enum CodingKeys: String, CodingKey { case name, showsInMenu, rows }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: container.decodeOptional(.name), showsInMenu: container.decodeOptional(.showsInMenu),
                  rows: container.decodeLossyDictionary(.rows, of: Bool.self) ?? [:])
    }
}

/// The optional rows of a display's section in the menu. Brightness always
/// shows.
enum MenuRow: String, CaseIterable, Sendable {
    case contrast, color, volume, input

    /// The Settings key holding the default for every display.
    var defaultsKey: String {
        switch self {
        case .contrast: Preferences.showContrast
        case .color: Preferences.showColor
        case .volume: Preferences.showVolume
        case .input: Preferences.showInput
        }
    }

    var title: String {
        switch self {
        case .contrast: "Contrast"
        case .color: "Color"
        case .volume: "Volume"
        case .input: "Input"
        }
    }

    /// Whether `monitor` has this row at all.
    @MainActor
    func isOffered(by monitor: Monitor) -> Bool {
        switch self {
        case .contrast: monitor.contrast != nil
        case .color: monitor.colorTemperature != nil || monitor.colorPreset != nil
        case .volume: monitor.volume != nil
        case .input: monitor.input != nil
        }
    }
}

/// What the user keeps in Glim itself: scenes, and per-display names and
/// menu choices. Monitor values are never kept: they always come from the
/// monitor.
///
/// Saved as JSON in `UserDefaults`. Data that can't be read is moved aside
/// under `<key>.unreadable` rather than overwritten, so a downgrade or a bug
/// never silently loses someone's scenes.
@MainActor
@Observable
final class GlimStore {
    private(set) var scenes: [DisplayScene] = []
    private(set) var displays: [String: DisplayPreferences] = [:]

    @ObservationIgnored private let defaults: UserDefaults?

    static let scenesKey = "scenes"
    static let displaysKey = "displays"
    static let adaptiveKey = "adaptive"
    /// The version of what this build writes: 1 is 0.3.0 and 0.4.0, which
    /// wrote no marker; 2 is the first to read leniently. Decoding does not
    /// depend on it. It is only logged, so a report says what wrote the data.
    static let storeVersionKey = "storeVersion"
    static let storeVersion = 2
    /// How many timestamped copies of unreadable data are kept per key, on
    /// top of the first one.
    static let unreadableCopiesKept = 3

    /// - Parameter defaults: Where to keep everything, or nil to keep it in
    ///   memory only.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let defaults {
            let found = defaults.object(forKey: Self.storeVersionKey) as? Int ?? 1
            AppLog.app.notice("store version \(found, privacy: .public) (this build writes \(Self.storeVersion, privacy: .public))")
            if found > Self.storeVersion {
                AppLog.app.notice("data written by a newer Glim, read leniently")
            }
        }
        scenes = loadArray(DisplayScene.self, key: Self.scenesKey) ?? []
        displays = (loadDictionary(DisplayPreferences.self, key: Self.displaysKey) ?? [:])
            .filter { !isTransientMonitorID($0.key) }
    }

    // MARK: Scenes

    func scene(_ id: DisplayScene.ID?) -> DisplayScene? {
        scenes.first { $0.id == id }
    }

    /// A new scene of what `monitors` show now, named "New Scene", "New
    /// Scene 2", and so on.
    @discardableResult
    func addScene(capturing monitors: [Monitor]) -> DisplayScene {
        let scene = DisplayScene.capturing(monitors, name: unusedName("New Scene"))
        scenes.append(scene)
        saveScenes()
        return scene
    }

    /// A copy just after the original, named "<name> Copy".
    @discardableResult
    func duplicateScene(_ id: DisplayScene.ID) -> DisplayScene? {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = scenes[index]
        copy.id = UUID()
        copy.name = unusedName("\(copy.name) Copy")
        scenes.insert(copy, at: index + 1)
        saveScenes()
        return copy
    }

    /// `base`, or `base 2`, `base 3`… whichever no scene has yet.
    private func unusedName(_ base: String) -> String {
        let taken = Set(scenes.map(\.name))
        var name = base
        var number = 2
        while taken.contains(name) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// The ⌘-digit that applies the scene: the first nine have one.
    func shortcutDigit(for id: DisplayScene.ID) -> Int? {
        scenes.firstIndex { $0.id == id }.flatMap { $0 < 9 ? $0 + 1 : nil }
    }

    func updateScene(_ id: DisplayScene.ID, _ change: (inout DisplayScene) -> Void) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        change(&scenes[index])
        saveScenes()
    }

    func rename(_ id: DisplayScene.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateScene(id) { $0.name = trimmed }
    }

    func deleteScene(_ id: DisplayScene.ID) {
        scenes.removeAll { $0.id == id }
        saveScenes()
    }

    func moveScenes(from source: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: source, toOffset: destination)
        saveScenes()
    }

    // MARK: Displays

    /// What the display has: its own entry, else the one of its model
    /// without the suffix that tells identical monitors apart (see
    /// ``monitorValue(in:for:)``). A display not identified yet has none.
    func preferences(for monitorID: String) -> DisplayPreferences {
        guard !isTransientMonitorID(monitorID) else { return DisplayPreferences() }
        return monitorValue(in: displays, for: monitorID) ?? DisplayPreferences()
    }

    /// Changes the display's preferences. They are written under its exact
    /// id, starting from what it inherits. Nothing is kept for a display
    /// that is not identified yet.
    func updateDisplay(_ monitorID: String, _ change: (inout DisplayPreferences) -> Void) {
        guard !isTransientMonitorID(monitorID) else { return }
        var preferences = self.preferences(for: monitorID)
        change(&preferences)
        // An empty entry is dropped, unless it has to shadow one it inherits.
        let shadows = fallbackMonitorValue(in: displays, for: monitorID) != nil
        displays[monitorID] = preferences.isEmpty && !shadows ? nil : preferences
        saveDisplays()
    }

    /// The user's name for the display, or the one Glim gives it.
    func title(for monitor: Monitor, in manager: MonitorManager) -> String {
        preferences(for: monitor.id).name ?? manager.title(for: monitor)
    }

    /// Sets the display's name. Blank goes back to Glim's.
    func setName(_ name: String, for monitorID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateDisplay(monitorID) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    func showsInMenu(_ monitorID: String) -> Bool {
        preferences(for: monitorID).showsInMenu ?? true
    }

    /// Whether the display's menu section shows `row`: its own choice, else
    /// the Settings default.
    func shows(_ row: MenuRow, for monitorID: String, default fallback: Bool) -> Bool {
        preferences(for: monitorID).rows[row.rawValue] ?? fallback
    }

    func setShows(_ row: MenuRow, _ shown: Bool, for monitorID: String) {
        updateDisplay(monitorID) { $0.rows[row.rawValue] = shown }
    }

    /// Drops the display's own menu choices, so it follows Settings again.
    /// Its name stays.
    func resetMenu(for monitorID: String) {
        updateDisplay(monitorID) {
            $0.rows = [:]
            $0.showsInMenu = nil
        }
    }

    // MARK: Automatic brightness

    /// Each display's automatic brightness and warmth, by monitor id. The
    /// controller owns them while Glim runs; they are kept here.
    func loadAdaptive() -> [String: AdaptiveSettings] {
        (loadDictionary(AdaptiveSettings.self, key: Self.adaptiveKey) ?? [:]).filter { !isTransientMonitorID($0.key) }
    }

    /// Keeps the settings of every identified display. A display not
    /// identified yet has no stable id, so nothing is kept for it.
    func saveAdaptive(_ settings: [String: AdaptiveSettings]) {
        save(settings.filter { !isTransientMonitorID($0.key) }, key: Self.adaptiveKey)
    }

    // MARK: Persistence

    private func saveScenes() { save(scenes, key: Self.scenesKey) }
    private func saveDisplays() { save(displays, key: Self.displaysKey) }

    private func loadArray<T: Decodable>(_ type: T.Type, key: String) -> [T]? {
        load(key: key) { try decodeLossyArray(type, from: $0) }
    }

    private func loadDictionary<T: Decodable>(_ type: T.Type, key: String) -> [String: T]? {
        load(key: key) { try decodeLossyDictionary(type, from: $0) }
    }

    /// Reads what is kept under `key`, as much as can be read.
    ///
    /// - Elements that can't be read are left out, and the original bytes
    ///   are kept as a recovery copy; the rest loads.
    /// - Data that isn't of the right kind at all is moved aside and the key
    ///   cleared.
    /// - With nothing under `key` but a recovery copy that reads now (the
    ///   user went back to a Glim that understands it), the copy comes back.
    private func load<Value>(key: String, decode: (Data) throws -> LossyDecoding<Value>) -> Value? {
        guard let defaults else { return nil }
        guard let data = defaults.data(forKey: key) else {
            let copyKey = key + Self.unreadableSuffix
            if let copy = defaults.data(forKey: copyKey), let decoded = try? decode(copy), decoded.skipped == 0 {
                AppLog.app.notice("\(key, privacy: .public) restored from its recovery copy")
                defaults.set(copy, forKey: key)
                defaults.removeObject(forKey: copyKey)
                return decoded.value
            }
            return nil
        }
        do {
            let decoded = try decode(data)
            if decoded.skipped > 0 {
                AppLog.app.fault("\(key, privacy: .public): \(decoded.skipped, privacy: .public) unreadable element(s) left out, original kept")
                setAside(data, key: key)
            }
            return decoded.value
        } catch {
            AppLog.app.fault("\(key, privacy: .public) unreadable, set aside: \(String(describing: error), privacy: .public)")
            setAside(data, key: key)
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    private static let unreadableSuffix = ".unreadable"

    /// Keeps `data` for recovery without ever overwriting an earlier copy:
    /// under `<key>.unreadable` if that is free, else under
    /// `<key>.unreadable.<unix time>`, of which the newest
    /// ``unreadableCopiesKept`` stay. Bytes already kept are not kept twice,
    /// so a blob that stays unreadable doesn't add a copy per launch.
    private func setAside(_ data: Data, key: String) {
        guard let defaults else { return }
        let first = key + Self.unreadableSuffix
        let prefix = first + "."
        let stamped = defaults.dictionaryRepresentation().keys.compactMap { name -> (name: String, time: Int)? in
            guard name.hasPrefix(prefix), let time = Int(name.dropFirst(prefix.count)) else { return nil }
            return (name, time)
        }.sorted { $0.time < $1.time }
        if defaults.data(forKey: first) == data || stamped.contains(where: { defaults.data(forKey: $0.name) == data }) { return }
        guard defaults.data(forKey: first) != nil else {
            defaults.set(data, forKey: first)
            return
        }
        // Later than every copy there is, so the order always says which is oldest.
        let time = max(Int(Date().timeIntervalSince1970), (stamped.last?.time ?? 0) + 1)
        defaults.set(data, forKey: prefix + String(time))
        for old in stamped.dropLast(max(Self.unreadableCopiesKept - 1, 0)) {
            defaults.removeObject(forKey: old.name)
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let defaults else { return }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            defaults.set(Self.storeVersion, forKey: Self.storeVersionKey)
        } catch {
            AppLog.app.fault("\(key, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

private struct GlimStoreKey: EnvironmentKey {
    static let defaultValue: GlimStore? = nil
}

extension EnvironmentValues {
    /// The app's store. Views without one (tests that don't need it) offer
    /// no scenes and use Glim's names.
    var glimStore: GlimStore? {
        get { self[GlimStoreKey.self] }
        set { self[GlimStoreKey.self] = newValue }
    }
}

private struct AdaptiveControllerKey: EnvironmentKey {
    static let defaultValue: AdaptiveController? = nil
}

extension EnvironmentValues {
    /// Automatic brightness. Views without it don't offer it.
    var adaptive: AdaptiveController? {
        get { self[AdaptiveControllerKey.self] }
        set { self[AdaptiveControllerKey.self] = newValue }
    }
}
