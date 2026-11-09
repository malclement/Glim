/// A VESA MCCS virtual control panel (VCP) code.
public struct VCPCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// 0x0B, the color temperature increment in kelvin. Read only.
    public static let colorTemperatureIncrement = VCPCode(0x0B)
    /// 0x0C, the color temperature: 3000 K plus this many increments
    /// (``colorTemperatureIncrement``). 0 means no Kelvin preset is active.
    public static let colorTemperature = VCPCode(0x0C)
    /// 0x14, the color preset. Writes use the MCCS values; some monitors (the
    /// HP E27m G4) read back in their own numbering.
    public static let colorPreset = VCPCode(0x14)
    /// 0x10, backlight luminance.
    public static let brightness = VCPCode(0x10)
    /// 0x12.
    public static let contrast = VCPCode(0x12)
    /// 0x60, the active video input.
    public static let inputSource = VCPCode(0x60)
    /// 0x62, speaker volume. On some monitors (the HP E27m G4) only a
    /// read-only mirror of a USB Audio level.
    public static let audioVolume = VCPCode(0x62)
    /// 0x8D, speaker mute: 1 mutes, 2 unmutes.
    public static let audioMute = VCPCode(0x8D)

    public var description: String {
        "0x" + String(rawValue, radix: 16, uppercase: true).leftPadded(to: 2)
    }
}

/// The MCCS 2.2a names for VCP 0x60 values. Values from 0x13 up are reserved by
/// the standard, and vendors use them for USB-C and Thunderbolt.
public enum InputSourceNames {
    public static func standardName(for value: UInt16) -> String? {
        switch value {
        case 0x01: "VGA 1"
        case 0x02: "VGA 2"
        case 0x03: "DVI 1"
        case 0x04: "DVI 2"
        case 0x05: "Composite 1"
        case 0x06: "Composite 2"
        case 0x07: "S-Video 1"
        case 0x08: "S-Video 2"
        case 0x09: "Tuner 1"
        case 0x0A: "Tuner 2"
        case 0x0B: "Tuner 3"
        case 0x0C: "Component 1"
        case 0x0D: "Component 2"
        case 0x0E: "Component 3"
        case 0x0F: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        default: nil
        }
    }

    public static func name(for value: UInt16) -> String {
        standardName(for: value) ?? "Input 0x" + String(value, radix: 16, uppercase: true).leftPadded(to: 2)
    }
}

/// The MCCS 2.2a names for VCP 0x14 values.
public enum ColorPresetNames {
    public static func standardName(for value: UInt16) -> String? {
        switch value {
        case 0x01: "sRGB"
        case 0x02: "Native"
        case 0x03: "4000 K"
        case 0x04: "5000 K"
        case 0x05: "6500 K"
        case 0x06: "7500 K"
        case 0x07: "8200 K"
        case 0x08: "9300 K"
        case 0x09: "10000 K"
        case 0x0A: "11500 K"
        case 0x0B: "User 1"
        case 0x0C: "User 2"
        case 0x0D: "User 3"
        default: nil
        }
    }

    public static func name(for value: UInt16) -> String {
        standardName(for: value) ?? "Preset 0x" + String(value, radix: 16, uppercase: true).leftPadded(to: 2)
    }
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}
