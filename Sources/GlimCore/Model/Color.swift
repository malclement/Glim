/// How VCP 0x0C turns into kelvin. MCCS defines the color temperature as
/// 3000 K plus the value times the increment the monitor reports in 0x0B.
public struct ColorTemperatureScale: Sendable, Equatable {
    /// Kelvin per step, from 0x0B.
    public var increment: UInt16
    /// The preset (a 0x14 value) to select before setting a temperature while
    /// the monitor is in a preset without one (0x0C reads 0), or nil to
    /// write 0x0C alone.
    public var kelvinPreset: UInt16?

    public init(increment: UInt16, kelvinPreset: UInt16?) {
        self.increment = increment
        self.kelvinPreset = kelvinPreset
    }

    public static let base = 3000

    /// The temperature for a 0x0C value, or nil for 0, which means the active
    /// preset has no temperature (sRGB, native, custom).
    public func kelvin(for value: Double) -> Int? {
        let steps = Int(value.rounded())
        return steps > 0 ? Self.base + steps * Int(increment) : nil
    }
}

/// One color preset Glim offers.
public struct ColorPresetOption: Hashable, Sendable, Identifiable {
    /// The 0x14 value written to select it.
    public var value: UInt16
    public var name: String
    /// What 0x14 reads while it is active.
    public var reading: UInt16
    /// What 0x0C reads while it is active, when that is needed to tell it
    /// apart, or nil if 0x0C plays no part.
    public var temperature: UInt16?

    public var id: UInt16 { value }

    public init(value: UInt16, name: String, reading: UInt16, temperature: UInt16? = nil) {
        self.value = value
        self.name = name
        self.reading = reading
        self.temperature = temperature
    }
}

/// What the color preset control shows: one of the offered presets, or
/// whatever else the monitor reports.
public enum ColorPresetValue: Hashable, Sendable {
    /// An offered preset, by the 0x14 value that selects it.
    case preset(UInt16)
    /// Anything else, as read: 0x14 and, when it is read, 0x0C.
    case other(reading: UInt16, temperature: UInt16?)
}

/// The presets a monitor offers, and how to recognize the active one.
public struct ColorPresets: Sendable, Equatable {
    public var options: [ColorPresetOption]
    /// The 0x14 value that restores the factory color, if known.
    public var factory: UInt16?
    /// Whether 0x0C is read along with 0x14 to recognize the active preset.
    public var readsTemperature: Bool
    /// Names for 0x14 readings that are not an offered preset, used while
    /// 0x0C reads 0.
    public var otherNames: [UInt16: String]

    public init(options: [ColorPresetOption], factory: UInt16? = nil, readsTemperature: Bool = false,
                otherNames: [UInt16: String] = [:]) {
        self.options = options
        self.factory = factory
        self.readsTemperature = readsTemperature
        self.otherNames = otherNames
    }

    /// The preset a pair of readings stands for. An offered preset that
    /// names a temperature matches only that exact temperature: on the HP,
    /// 0x14 reports the nearest of a few buckets once 0x0C is set by hand.
    public func value(reading: UInt16, temperature: UInt16?) -> ColorPresetValue {
        let match = options.first { option in
            option.reading == reading && (option.temperature == nil || option.temperature == temperature)
        }
        return match.map { .preset($0.value) } ?? .other(reading: reading, temperature: temperature)
    }

    /// A 0x0C value that is some preset's own, the factory one's if it has
    /// one. Writing it ends a temperature set by hand without leaving the
    /// monitor between presets.
    public var neutralTemperature: UInt16? {
        let factoryOption = factory.flatMap { factory in options.first { $0.value == factory } }
        if let temperature = factoryOption?.temperature, temperature != 0 { return temperature }
        return options.lazy.compactMap(\.temperature).first { $0 != 0 }
    }

    public func option(for value: ColorPresetValue) -> ColorPresetOption? {
        guard case .preset(let raw) = value else { return nil }
        return options.first { $0.value == raw }
    }

    /// The name to show for any value.
    public func name(of value: ColorPresetValue) -> String {
        switch value {
        case .preset(let raw):
            return option(for: value)?.name ?? ColorPresetNames.name(for: raw)
        case .other(let reading, let temperature):
            // A temperature set by hand is not a preset of its own.
            if let temperature, temperature != 0 { return "Custom" }
            return otherNames[reading] ?? "Other"
        }
    }

    /// The MCCS presets a capabilities string lists. Each is assumed to read
    /// back as written, as MCCS says it should.
    public static func standard(listed values: [UInt8]) -> ColorPresets? {
        let options = values.filter { $0 != 0 }.map { value in
            ColorPresetOption(value: UInt16(value), name: ColorPresetNames.name(for: UInt16(value)), reading: UInt16(value))
        }
        // A single listed preset is no choice at all.
        guard options.count >= 2 else { return nil }
        return ColorPresets(options: options)
    }
}
