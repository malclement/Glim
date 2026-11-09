/// One choice of a discrete control, such as an input.
public struct InputOption: Hashable, Sendable, Identifiable {
    public var value: UInt16
    public var name: String
    public var id: UInt16 { value }

    public init(value: UInt16, name: String) {
        self.value = value
        self.name = name
    }
}

/// What Glim knows about a monitor model: which controls it offers and how
/// each one is reached.
public struct MonitorProfile: Sendable, Equatable {
    public enum VolumeRoute: Sendable, Equatable {
        /// VCP 0x62 for the level and 0x8D for mute.
        case ddc
        /// The monitor's USB Audio device, found by the start of its name.
        case usbAudio(deviceNamePrefix: String)
    }

    /// A control a profile can offer.
    public enum Control: Sendable, Hashable {
        case brightness, contrast, colorTemperature, colorPreset, volume, mute, input
    }

    public var id: String
    /// True when the profile was built by testing the model on real
    /// hardware. ``untested`` lists the controls that still were not.
    /// False for monitors described only by their own capabilities string.
    public var isTested: Bool
    /// Controls offered without having been exercised on the hardware.
    public var untested: Set<Control>
    public var brightness: Bool
    public var contrast: Bool
    /// The color temperature (0x0C), or nil to offer none.
    public var colorTemperature: ColorTemperatureScale?
    /// The color presets (0x14), or nil to offer none.
    public var colorPresets: ColorPresets?
    public var volume: VolumeRoute?
    /// The inputs offered, or nil to offer none.
    public var inputs: [InputOption]?
    /// What to check when the monitor stops answering, phrased as a
    /// condition: DDC/CI being off is one cause among several.
    public var ddcHelp: String

    public init(id: String, isTested: Bool, untested: Set<Control> = [], brightness: Bool, contrast: Bool,
                colorTemperature: ColorTemperatureScale? = nil, colorPresets: ColorPresets? = nil,
                volume: VolumeRoute?, inputs: [InputOption]?, ddcHelp: String) {
        self.id = id
        self.isTested = isTested
        self.untested = untested
        self.brightness = brightness
        self.contrast = contrast
        self.colorTemperature = colorTemperature
        self.colorPresets = colorPresets
        self.volume = volume
        self.inputs = inputs
        self.ddcHelp = ddcHelp
    }

    /// True for a monitor Glim has no profile for.
    public var isGeneric: Bool { id == Self.genericID }

    /// Whether this control was exercised on this model's hardware.
    public func isTested(_ control: Control) -> Bool {
        isTested && !untested.contains(control)
    }

    private static let genericID = "generic"

    /// The profile for a known model, if this is one.
    public static func known(for identity: DisplayIdentity?) -> MonitorProfile? {
        guard let identity else { return nil }
        return knownProfiles.first { $0.matches(identity) }?.profile
    }

    private static let knownProfiles: [(matches: @Sendable (DisplayIdentity) -> Bool, profile: MonitorProfile)] = [
        ({ $0.vendorID == 0x220E && $0.productID == 0x3753 }, .hpE27mG4),
    ]

    /// HP E27m G4, tested on firmware 1.0 over USB-C (docs/controls.md).
    ///
    /// - Brightness 0x10 and contrast 0x12: written and read back.
    /// - Volume and mute: the speakers are a USB Audio device, set and read
    ///   back. DDC 0x62 accepts writes and ignores them; it only mirrors the
    ///   USB level.
    /// - Color temperature 0x0C and preset 0x14: written and read back by the
    ///   CLI (docs/controls.md, "0x14 color-preset mapping"), but not yet by
    ///   the app's controls, so they stay untested until `make
    ///   hardware-test` passes with the monitor attached. 0x14 reads back in
    ///   HP's numbering, and one reading can stand for several presets, so a
    ///   preset is recognized by 0x14 and 0x0C together. Only the presets
    ///   whose effect the measurements pin down are offered; 03, 06, 07, 0A
    ///   and the user presets wait for someone to look at the screen.
    /// - Inputs: the three values in the monitor's capabilities string, with
    ///   HP's names (0x13 is HP's USB-C value; MCCS reserves it). **Never
    ///   written to the hardware**: the owner deferred input switching, and
    ///   whether DDC still answers afterwards is unknown.
    public static let hpE27mG4 = MonitorProfile(
        id: "hp-e27m-g4",
        isTested: true,
        untested: [.input, .colorTemperature, .colorPreset],
        brightness: true,
        contrast: true,
        // 0x0B reads 50. Leaving sRGB or native for a temperature goes
        // through 6500 K, a preset that has one.
        colorTemperature: ColorTemperatureScale(increment: 50, kelvinPreset: 0x05),
        colorPresets: ColorPresets(
            options: [
                ColorPresetOption(value: 0x01, name: "sRGB", reading: 1, temperature: 0),
                ColorPresetOption(value: 0x02, name: "Native", reading: 10, temperature: 0),
                ColorPresetOption(value: 0x04, name: "5000 K", reading: 5, temperature: 40),
                ColorPresetOption(value: 0x05, name: "6500 K (factory)", reading: 8, temperature: 70),
                ColorPresetOption(value: 0x08, name: "9300 K", reading: 2, temperature: 126),
            ],
            factory: 0x05,
            readsTemperature: true,
            // Any RGB gain write, user 1, and 0x0C = 0 all read 15.
            otherNames: [15: "Custom RGB"]
        ),
        volume: .usbAudio(deviceNamePrefix: "HP E27m G4"),
        inputs: [
            InputOption(value: 0x0F, name: "DisplayPort"),
            InputOption(value: 0x11, name: "HDMI"),
            InputOption(value: 0x13, name: "USB-C"),
        ],
        ddcHelp: "If DDC/CI is off, turn it on in the monitor's menu under Management › DDC/CI."
    )

    /// A monitor Glim has no profile for. Brightness and contrast are always
    /// tried, since nearly every DDC/CI monitor has them and a capabilities
    /// string can omit codes the monitor answers; volume, inputs and color
    /// need the capabilities string, which gives the input and preset values.
    /// The color temperature also needs the increment the monitor reports in
    /// 0x0B (`temperatureIncrement`), without which there is no kelvin value
    /// to show. A control is only shown once it answers a read.
    public static func generic(capabilities: MonitorCapabilities?, temperatureIncrement: UInt16? = nil) -> MonitorProfile {
        let inputs = capabilities.map { caps in
            caps.values(for: .inputSource).map { InputOption(value: UInt16($0), name: InputSourceNames.name(for: UInt16($0))) }
        }
        return MonitorProfile(
            id: genericID,
            isTested: false,
            brightness: true,
            contrast: true,
            colorTemperature: colorTemperature(capabilities: capabilities, increment: temperatureIncrement),
            colorPresets: capabilities.flatMap { ColorPresets.standard(listed: $0.values(for: .colorPreset)) },
            volume: capabilities?.lists(.audioVolume) == true ? .ddc : nil,
            // A single listed input is no choice at all.
            inputs: (inputs?.count ?? 0) >= 2 ? inputs : nil,
            ddcHelp: "If DDC/CI is off, turn it on in the display's own menu."
        )
    }

    private static func colorTemperature(capabilities: MonitorCapabilities?, increment: UInt16?) -> ColorTemperatureScale? {
        guard let capabilities, capabilities.lists(.colorTemperature), let increment, increment > 0 else { return nil }
        // Leave a preset without a temperature through 6500 K, if the
        // monitor lists it.
        let kelvinPreset: UInt16? = capabilities.values(for: .colorPreset).contains(0x05) ? 0x05 : nil
        return ColorTemperatureScale(increment: increment, kelvinPreset: kelvinPreset)
    }
}
