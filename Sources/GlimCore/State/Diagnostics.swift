import Foundation

extension Monitor {
    /// The display pipe its transport belongs to, for example "dispext0".
    public var displayPipe: String? { display.framebuffer }
}

extension MonitorManager {
    /// A plain-text report for bug reports: what Glim found and what each
    /// control reads. Serial numbers are left out.
    public func diagnosticsReport(appVersion: String) -> String {
        var lines = [
            "Glim \(appVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware \(Self.hardwareModel())",
            "DDC/CI \(availability == .available ? "available" : "unavailable")",
            "Monitors \(monitors.count)",
        ]
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
            lines.append("  volume: \(Self.describe(monitor.volume))\(monitor.audioDeviceName.map { " via \($0)" } ?? "")")
            lines.append("  mute: \(Self.describe(monitor.mute))")
            lines.append("  input: \(Self.describe(monitor.input?.control))\(monitor.input?.currentName.map { " (\($0))" } ?? "")")
            if let caps = monitor.capabilitiesString {
                lines.append("  capabilities: \(caps)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe<Value>(_ control: DeviceControl<Value>?) -> String {
        guard let control else { return "not offered" }
        var text = control.value.map { "\($0)" } ?? "unknown"
        if let range = control.range { text += " of \(range.lowerBound)…\(range.upperBound)" }
        if let failure = control.failure { text += " [\(failure.message)]" }
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
