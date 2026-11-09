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

    /// - Parameter defaults: Where to keep everything, or nil to keep it in
    ///   memory only.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        scenes = load([DisplayScene].self, key: Self.scenesKey) ?? []
        displays = load([String: DisplayPreferences].self, key: Self.displaysKey) ?? [:]
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

    func preferences(for monitorID: String) -> DisplayPreferences {
        displays[monitorID] ?? DisplayPreferences()
    }

    func updateDisplay(_ monitorID: String, _ change: (inout DisplayPreferences) -> Void) {
        var preferences = self.preferences(for: monitorID)
        change(&preferences)
        displays[monitorID] = preferences.isEmpty ? nil : preferences
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

    // MARK: Persistence

    private func saveScenes() { save(scenes, key: Self.scenesKey) }
    private func saveDisplays() { save(displays, key: Self.displaysKey) }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.app.fault("\(key, privacy: .public) unreadable, set aside: \(String(describing: error), privacy: .public)")
            defaults.set(data, forKey: key + ".unreadable")
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let defaults else { return }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
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
