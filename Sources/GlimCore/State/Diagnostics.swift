import Foundation

extension Monitor {
    /// The display pipe its transport belongs to, for example "dispext0".
    public var displayPipe: String? { display.framebuffer }
}

/// What the app knows about itself that GlimCore cannot, for the report.
public struct DiagnosticsContext: Sendable {
    /// Whether macOS started Glim as a login item. nil when unknown.
    public var launchedAtLogin: Bool?
    /// The login item's status in words, for example "enabled".
    public var loginItemStatus: String?

    public init(launchedAtLogin: Bool? = nil, loginItemStatus: String? = nil) {
        self.launchedAtLogin = launchedAtLogin
        self.loginItemStatus = loginItemStatus
    }
}

extension MonitorManager {
    /// A plain-text report for bug reports: what Glim found, why DDC/CI is or
    /// isn't available, what each control reads, and the last events. Serial
    /// numbers, display UUIDs and audio device UIDs are left out.
    public func diagnosticsReport(appVersion: String, context: DiagnosticsContext = DiagnosticsContext(),
                                  now: Date = Date()) -> String {
        func yesNo(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
        var lines = [
            "Glim \(appVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware \(Self.hardwareModel())",
            "DDC/CI \(availability == .available ? "available" : "unavailable")",
            "Launched at login: \(yesNo(context.launchedAtLogin))",
            "Login item: \(context.loginItemStatus ?? "unknown")",
        ]
        if case .unavailable(let reason) = availability { lines.append("DDC/CI unavailable because: \(reason)") }
        if let discoveryHint { lines.append("Discovery: \(discoveryHint)") }
        lines.append(contentsOf: platform.transportSummary.lines)
        lines.append("Monitors \(monitors.count)")
        for monitor in monitors {
            lines.append("")
            lines.append("\(monitor.name)")
            if let identity = monitor.identity {
                let product = String(identity.productID, radix: 16, uppercase: true).leftPadded(to: 4)
                lines.append("  EDID: \(identity.manufacturerCode) \(product), serial \(identity.alphanumericSerial == nil ? "absent" : "present")")
            } else {
                lines.append("  EDID: not matched to its transport")
            }
            lines.append("  pipe: \(monitor.displayPipe ?? "?")")
            let untested = monitor.profile.untested.map { "\($0)" }.sorted()
            let tested = monitor.profile.isTested ? " (tested\(untested.isEmpty ? "" : "; untested: \(untested.joined(separator: ", "))"))" : ""
            lines.append("  profile: \(monitor.profile.id)\(tested)")
            lines.append("  status: \(monitor.status)")
            lines.append("  brightness: \(Self.describe(monitor.brightness))")
            lines.append("  contrast: \(Self.describe(monitor.contrast))")
            let kelvin = monitor.colorTemperature?.value.flatMap { monitor.profile.colorTemperature?.kelvin(for: $0) }
            lines.append("  color temperature: \(Self.describe(monitor.colorTemperature))\(kelvin.map { " (\($0) K)" } ?? "")")
            lines.append("  color preset: \(Self.describe(monitor.colorPreset?.control))\(monitor.colorPreset?.currentName.map { " (\($0))" } ?? "")")
            lines.append("  volume: \(Self.describe(monitor.volume))\(monitor.audioDeviceName.map { " via \($0)" } ?? "")")
            lines.append("  mute: \(Self.describe(monitor.mute))")
            lines.append("  input: \(Self.describe(monitor.input?.control))\(monitor.input?.currentName.map { " (\($0))" } ?? "")")
            if let presets = monitor.colorPreset?.options, !presets.isEmpty {
                lines.append("  color presets offered: " + presets.map { "\($0.name) (0x\(String($0.value, radix: 16)))" }.joined(separator: ", "))
            }
            if let inputs = monitor.input?.options, !inputs.isEmpty {
                lines.append("  inputs offered: " + inputs.map { "\($0.name) (0x\(String($0.value, radix: 16)))" }.joined(separator: ", "))
            }
            if let caps = monitor.capabilitiesString {
                lines.append("  capabilities: \(caps)")
            }
        }
        lines.append("")
        lines.append("Recent events (newest last)")
        let recent = events.lines(now: now)
        lines.append(contentsOf: recent.isEmpty ? ["  none"] : recent.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    private static func describe<Value>(_ control: DeviceControl<Value>?) -> String {
        guard let control else { return "not offered" }
        var text = control.value.map { "\($0)" } ?? "unknown"
        if let range = control.range { text += " of \(range.lowerBound)…\(range.upperBound)" }
        if let failure = control.failure {
            text += " [\(failure.message)\(failure.detail.map { " (\($0))" } ?? "")]"
        }
        return text
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
