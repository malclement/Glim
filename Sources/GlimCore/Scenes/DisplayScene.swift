import Foundation

/// A named set of display settings, such as "Day" or "Evening", applied in
/// one click. It holds, for each monitor it was saved from, the brightness,
/// contrast and color, and applies only the parts it ``includes``.
///
/// Input and volume are left out on purpose: an input switch needs its own
/// confirmation, and volume is not the display.
public struct DisplayScene: Codable, Hashable, Identifiable, Sendable {
    public enum Part: String, Codable, CaseIterable, Sendable {
        case brightness, contrast, color
    }

    /// A level as read from the monitor, with the top of its range so it can
    /// be shown while the monitor is away.
    public struct Level: Codable, Hashable, Sendable {
        public var value: Double
        public var maximum: Double

        public init(value: Double, maximum: Double) {
            self.value = value
            self.maximum = maximum
        }

        /// 0 to 1.
        public var fraction: Double { maximum > 0 ? min(max(value / maximum, 0), 1) : 0 }
    }

    public enum Color: Codable, Hashable, Sendable {
        /// One of the monitor's presets, by the 0x14 value that selects it.
        case preset(value: UInt16, name: String)
        /// A temperature, in 0x0C steps, and what that was in kelvin.
        case temperature(steps: Double, kelvin: Int)

        public var name: String {
            switch self {
            case .preset(_, let name): name
            case .temperature(_, let kelvin): "\(kelvin) K"
            }
        }
    }

    /// What one monitor is set to.
    public struct Settings: Codable, Hashable, Sendable {
        /// The monitor's own name when it was saved, to list it while away.
        public var monitorName: String
        public var brightness: Level?
        public var contrast: Level?
        public var color: Color?

        public init(monitorName: String, brightness: Level? = nil, contrast: Level? = nil, color: Color? = nil) {
            self.monitorName = monitorName
            self.brightness = brightness
            self.contrast = contrast
            self.color = color
        }

        /// Whether there is anything of `parts` to apply.
        public func hasAny(of parts: Set<Part>) -> Bool {
            (parts.contains(.brightness) && brightness != nil) || (parts.contains(.contrast) && contrast != nil)
                || (parts.contains(.color) && color != nil)
        }
    }

    public var id: UUID
    public var name: String
    /// An SF Symbol of the user's choice, or nil for the default. Optional,
    /// so scenes saved before it existed still decode.
    public var symbol: String?
    public var includes: Set<Part>
    /// By ``Monitor/id``, which stays the same across reconnects.
    public var monitors: [String: Settings]

    public init(id: UUID = UUID(), name: String, symbol: String? = nil, includes: Set<Part> = Set(Part.allCases),
                monitors: [String: Settings] = [:]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.includes = includes
        self.monitors = monitors
    }
}

extension DisplayScene {
    public static let defaultSymbol = "sparkles.rectangle.stack"

    /// The symbols a scene can wear, for the times of day and the things
    /// people use a screen for.
    public static let symbols = [
        "sparkles.rectangle.stack", "sun.max", "sun.horizon", "sunset", "moon", "moon.stars",
        "lightbulb", "book", "doc.text", "film", "gamecontroller", "paintbrush", "camera", "cup.and.saucer",
    ]

    public var shownSymbol: String { symbol ?? Self.defaultSymbol }

    /// A name a person can read or hear for each of ``symbols``.
    public static let symbolNames: [String: String] = [
        "sparkles.rectangle.stack": "Sparkles",
        "sun.max": "Sun",
        "sun.horizon": "Sunrise",
        "sunset": "Sunset",
        "moon": "Moon",
        "moon.stars": "Moon and stars",
        "lightbulb": "Light bulb",
        "book": "Book",
        "doc.text": "Document",
        "film": "Film",
        "gamecontroller": "Game controller",
        "paintbrush": "Paintbrush",
        "camera": "Camera",
        "cup.and.saucer": "Cup and saucer",
    ]

    /// The readable name of `symbol`; the symbol's own name for one not in
    /// ``symbols``.
    public static func name(ofSymbol symbol: String) -> String {
        symbolNames[symbol] ?? symbol
    }
}

// MARK: - Capturing and applying

extension DisplayScene.Settings {
    /// What `monitor` shows now, or nil when it shows nothing worth saving.
    /// Only values read from the monitor count; a color without a name or a
    /// temperature (custom RGB, an unknown preset) is left out, since it
    /// could not be put back.
    @MainActor
    public init?(capturing monitor: Monitor) {
        func level(_ control: DeviceControl<Double>?) -> DisplayScene.Level? {
            guard let control, let value = control.value else { return nil }
            return DisplayScene.Level(value: value, maximum: control.range?.upperBound ?? 100)
        }
        var color: DisplayScene.Color?
        if let preset = monitor.colorPreset?.current {
            color = .preset(value: preset.value, name: preset.name)
        } else if let steps = monitor.colorTemperature?.value,
                  let kelvin = monitor.profile.colorTemperature?.kelvin(for: steps) {
            color = .temperature(steps: steps, kelvin: kelvin)
        }
        self.init(monitorName: monitor.name, brightness: level(monitor.brightness), contrast: level(monitor.contrast), color: color)
        if brightness == nil, contrast == nil, color == nil { return nil }
    }
}

extension DisplayScene {
    /// A scene of what `monitors` show now.
    @MainActor
    public static func capturing(_ monitors: [Monitor], name: String, includes: Set<Part> = Set(Part.allCases)) -> DisplayScene {
        var scene = DisplayScene(name: name, includes: includes)
        scene.recapture(monitors)
        return scene
    }

    /// Saves what `monitors` show now over what the scene held for them.
    /// Monitors that are away keep their saved settings.
    @MainActor
    public mutating func recapture(_ monitors: [Monitor]) {
        for monitor in monitors {
            if let settings = Settings(capturing: monitor) { self.monitors[monitor.id] = settings }
        }
    }

    /// The connected monitors this scene has settings for.
    @MainActor
    public func connected(in monitors: [Monitor]) -> [Monitor] {
        monitors.filter { self.monitors[$0.id]?.hasAny(of: includes) == true }
    }

    /// Sets every connected monitor it has settings for. Returns how many
    /// monitors got at least one change; a monitor not yet read gets none.
    @MainActor
    @discardableResult
    public func apply(to monitors: [Monitor]) -> Int {
        Log.state.notice("applying scene \(self.name, privacy: .public)")
        return connected(in: monitors).filter { monitor in
            self.monitors[monitor.id].map { monitor.apply($0, parts: includes) } ?? false
        }.count
    }

    /// Whether every connected monitor it has settings for shows them now,
    /// and there is at least one.
    @MainActor
    public func isActive(on monitors: [Monitor]) -> Bool {
        let relevant = connected(in: monitors)
        return !relevant.isEmpty && relevant.allSatisfy { monitor in
            self.monitors[monitor.id].map { monitor.shows($0, parts: includes) } ?? false
        }
    }
}

extension Monitor {
    /// Sets the parts of `settings` this monitor offers. Returns whether it
    /// changed anything.
    @discardableResult
    public func apply(_ settings: DisplayScene.Settings, parts: Set<DisplayScene.Part>) -> Bool {
        var applied = false
        func set(_ control: DeviceControl<Double>?, _ level: DisplayScene.Level?) {
            guard let control, control.value != nil, let level else { return }
            control.set(level.value)
            applied = true
        }
        if parts.contains(.brightness) { set(brightness, settings.brightness) }
        if parts.contains(.contrast) { set(contrast, settings.contrast) }
        if parts.contains(.color) {
            switch settings.color {
            case .preset(let value, _):
                if let selector = colorPreset, selector.value != nil,
                   let option = selector.options.first(where: { $0.value == value }) {
                    selector.select(option)
                    applied = true
                }
            case .temperature(let steps, _):
                set(colorTemperature, DisplayScene.Level(value: steps, maximum: steps))
            case nil:
                break
            }
        }
        return applied
    }

    /// Whether the monitor shows the parts of `settings` it offers.
    public func shows(_ settings: DisplayScene.Settings, parts: Set<DisplayScene.Part>) -> Bool {
        func matches(_ control: DeviceControl<Double>?, _ level: DisplayScene.Level?) -> Bool {
            guard let control, let level else { return true }
            return control.value == level.value
        }
        if parts.contains(.brightness), !matches(brightness, settings.brightness) { return false }
        if parts.contains(.contrast), !matches(contrast, settings.contrast) { return false }
        if parts.contains(.color) {
            switch settings.color {
            case .preset(let value, _):
                if let selector = colorPreset, selector.current?.value != value { return false }
            case .temperature(let steps, _):
                if let temperature = colorTemperature, temperature.value != steps { return false }
            case nil:
                break
            }
        }
        return true
    }
}
