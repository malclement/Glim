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

    public var id: String
    /// True when every control below was exercised on the real monitor and
    /// read back. False for monitors described only by their own
    /// capabilities string.
    public var isVerified: Bool
    public var brightness: Bool
    public var contrast: Bool
    public var volume: VolumeRoute?
    /// The inputs offered, or nil to offer none.
    public var inputs: [InputOption]?
    /// How to turn DDC/CI back on when the monitor stops answering.
    public var ddcHelp: String

    public init(id: String, isVerified: Bool, brightness: Bool, contrast: Bool,
                volume: VolumeRoute?, inputs: [InputOption]?, ddcHelp: String) {
        self.id = id
        self.isVerified = isVerified
        self.brightness = brightness
        self.contrast = contrast
        self.volume = volume
        self.inputs = inputs
        self.ddcHelp = ddcHelp
    }

    /// True for a monitor Glim has no profile for.
    public var isGeneric: Bool { id == Self.genericID }

    private static let genericID = "generic"

    /// The profile for a known model, if this is one.
    public static func known(for identity: DisplayIdentity?) -> MonitorProfile? {
        guard let identity else { return nil }
        return knownProfiles.first { $0.matches(identity) }?.profile
    }

    private static let knownProfiles: [(matches: @Sendable (DisplayIdentity) -> Bool, profile: MonitorProfile)] = [
        ({ $0.vendorID == 0x220E && $0.productID == 0x3753 }, .hpE27mG4),
    ]

    /// HP E27m G4, verified on firmware 1.0 over USB-C (docs/controls.md).
    ///
    /// - Brightness 0x10 and contrast 0x12: written and read back.
    /// - Volume: the speakers are a USB Audio device. DDC 0x62 accepts writes
    ///   and ignores them; it only mirrors the USB level.
    /// - Inputs: the three values in the monitor's capabilities string, with
    ///   HP's names (0x13 is HP's USB-C value; MCCS reserves it).
    public static let hpE27mG4 = MonitorProfile(
        id: "hp-e27m-g4",
        isVerified: true,
        brightness: true,
        contrast: true,
        volume: .usbAudio(deviceNamePrefix: "HP E27m G4"),
        inputs: [
            InputOption(value: 0x0F, name: "DisplayPort"),
            InputOption(value: 0x11, name: "HDMI"),
            InputOption(value: 0x13, name: "USB-C"),
        ],
        ddcHelp: "Turn DDC/CI back on in the monitor's menu: Management › DDC/CI."
    )

    /// A monitor Glim has no profile for. Controls come from its
    /// capabilities string, and each one is only shown once it answers a read.
    public static func generic(capabilities: MonitorCapabilities?) -> MonitorProfile {
        let inputs = capabilities.map { caps in
            caps.values(for: .inputSource).map { InputOption(value: UInt16($0), name: InputSourceNames.name(for: UInt16($0))) }
        }
        return MonitorProfile(
            id: genericID,
            isVerified: false,
            brightness: capabilities?.lists(.brightness) ?? true,
            contrast: capabilities?.lists(.contrast) ?? true,
            volume: capabilities?.lists(.audioVolume) == true ? .ddc : nil,
            // A single listed input is no choice at all.
            inputs: (inputs?.count ?? 0) >= 2 ? inputs : nil,
            ddcHelp: "Check that DDC/CI is turned on in the monitor's own menu."
        )
    }
}
