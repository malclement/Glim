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
        case brightness, contrast, volume, mute, input
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
    public var volume: VolumeRoute?
    /// The inputs offered, or nil to offer none.
    public var inputs: [InputOption]?
    /// What to check when the monitor stops answering, phrased as a
    /// condition: DDC/CI being off is one cause among several.
    public var ddcHelp: String

    public init(id: String, isTested: Bool, untested: Set<Control> = [], brightness: Bool, contrast: Bool,
                volume: VolumeRoute?, inputs: [InputOption]?, ddcHelp: String) {
        self.id = id
        self.isTested = isTested
        self.untested = untested
        self.brightness = brightness
        self.contrast = contrast
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
    /// - Inputs: the three values in the monitor's capabilities string, with
    ///   HP's names (0x13 is HP's USB-C value; MCCS reserves it). **Never
    ///   written to the hardware**: the owner deferred input switching, and
    ///   whether DDC still answers afterwards is unknown.
    public static let hpE27mG4 = MonitorProfile(
        id: "hp-e27m-g4",
        isTested: true,
        untested: [.input],
        brightness: true,
        contrast: true,
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
    /// string can omit codes the monitor answers; volume and inputs need the
    /// capabilities string, which gives the input values. A control is only
    /// shown once it answers a read.
    public static func generic(capabilities: MonitorCapabilities?) -> MonitorProfile {
        let inputs = capabilities.map { caps in
            caps.values(for: .inputSource).map { InputOption(value: UInt16($0), name: InputSourceNames.name(for: UInt16($0))) }
        }
        return MonitorProfile(
            id: genericID,
            isTested: false,
            brightness: true,
            contrast: true,
            volume: capabilities?.lists(.audioVolume) == true ? .ddc : nil,
            // A single listed input is no choice at all.
            inputs: (inputs?.count ?? 0) >= 2 ? inputs : nil,
            ddcHelp: "If DDC/CI is off, turn it on in the display's own menu."
        )
    }
}
