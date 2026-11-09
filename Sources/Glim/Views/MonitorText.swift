import GlimCore

/// How the app puts a monitor's state into words.
enum MonitorText {
    static func status(_ status: Monitor.Status) -> String {
        switch status {
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .notResponding: "Not responding"
        }
    }

    /// Whether Glim was tested with this model, and which controls weren't.
    static func profile(_ profile: MonitorProfile) -> String {
        guard profile.isTested else { return "Untested: controls from the display's own description" }
        let untested = controlOrder.filter(profile.untested.contains).map(name(of:))
        guard !untested.isEmpty else { return "Tested with Glim" }
        return "Tested with Glim, except \(list(untested))"
    }

    /// The EDID manufacturer and product codes, as in "HWP 3753".
    static func edid(_ identity: DisplayIdentity) -> String {
        "\(identity.manufacturerCode) \(String(identity.productID, radix: 16, uppercase: true))"
    }

    /// Which speakers the volume controls drive.
    @MainActor
    static func speakers(of monitor: Monitor) -> String {
        monitor.audioDeviceName ?? (monitor.volume == nil ? "Not controlled" : "Over DDC/CI")
    }

    /// A color temperature as shown: kelvin, or, when the active preset has
    /// none, that preset's name.
    @MainActor
    static func colorTemperature(of monitor: Monitor) -> String {
        guard let value = monitor.colorTemperature?.value else { return "–" }
        if let kelvin = monitor.profile.colorTemperature?.kelvin(for: value) { return "\(kelvin) K" }
        return monitor.colorPreset?.currentName ?? "Custom"
    }

    private static let controlOrder: [MonitorProfile.Control] = [
        .brightness, .contrast, .colorTemperature, .colorPreset, .volume, .mute, .input,
    ]

    private static func name(of control: MonitorProfile.Control) -> String {
        switch control {
        case .brightness: "brightness"
        case .contrast: "contrast"
        case .colorTemperature: "color temperature"
        case .colorPreset: "color presets"
        case .volume: "volume"
        case .mute: "mute"
        case .input: "input switching"
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        let rest = items.dropLast()
        return rest.isEmpty ? last : "\(rest.joined(separator: ", ")) and \(last)"
    }
}
