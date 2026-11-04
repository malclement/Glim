import Foundation
import IOKit

/// How a display identifies itself: the EDID fields macOS decoded into the
/// framebuffer's `DisplayAttributes`.
public struct DisplayIdentity: Hashable, Sendable, Codable {
    /// EDID manufacturer ID, the three-letter PnP code packed into 16 bits
    /// (0x220E is "HPN").
    public var vendorID: UInt32
    /// EDID product code (0x3753 for the HP E27m G4).
    public var productID: UInt32
    /// EDID binary serial number. Often a placeholder such as 0x01010101.
    public var serialNumber: UInt32
    /// The EDID serial-number string, when there is one. Unique per unit.
    public var alphanumericSerial: String?
    /// The EDID display name, for example "HP E27m G4".
    public var productName: String?

    public init(vendorID: UInt32, productID: UInt32, serialNumber: UInt32 = 0,
                alphanumericSerial: String? = nil, productName: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.alphanumericSerial = alphanumericSerial
        self.productName = productName
    }

    /// The three-letter PnP manufacturer code, for example "HPN".
    public var manufacturerCode: String {
        let packed = UInt16(truncatingIfNeeded: vendorID)
        let letters = [(packed >> 10) & 0x1F, (packed >> 5) & 0x1F, packed & 0x1F].map { code -> Character in
            (1...26).contains(code) ? Character(UnicodeScalar(UInt8(code) + 64)) : "?"
        }
        return String(letters)
    }

    /// Identifies the unit across reconnects and reboots: manufacturer,
    /// product and serial. When the EDID carries no usable serial, two
    /// identical monitors share a key; ``MonitorManager`` disambiguates those.
    public var stableKey: String {
        let product = String(productID, radix: 16, uppercase: true).leftPadded(to: 4)
        var parts = [manufacturerCode, product]
        if let serial = alphanumericSerial?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
            parts.append(serial)
        } else if !Self.placeholderSerials.contains(serialNumber) {
            parts.append(String(serialNumber, radix: 16, uppercase: true))
        }
        return parts.joined(separator: "-")
    }

    /// Binary serials that manufacturers ship instead of a real one.
    static let placeholderSerials: Set<UInt32> = [0, 0x0101_0101, 0xFFFF_FFFF]
}

/// An external display that macOS exposes a DDC/CI transport for.
public struct DiscoveredDisplay: Hashable, Sendable {
    /// Registry entry ID of the display's `DCPAVServiceProxy`. It changes when
    /// the display is reconnected.
    public var serviceID: UInt64
    /// The display pipe the proxy belongs to, for example "dispext0".
    public var framebuffer: String?
    /// nil when the proxy could not be tied to a framebuffer's EDID.
    public var identity: DisplayIdentity?

    public init(serviceID: UInt64, framebuffer: String? = nil, identity: DisplayIdentity? = nil) {
        self.serviceID = serviceID
        self.framebuffer = framebuffer
        self.identity = identity
    }
}

/// Finds external displays in the IORegistry. Only reads registry
/// properties; it opens nothing and sends nothing to a display.
///
/// On Apple silicon each external display pipe `dispextN` has a framebuffer
/// (`IOMobileFramebufferShim`, a child of the `dispextN` device) whose
/// `DisplayAttributes` hold the decoded EDID, and a `DCPAVServiceProxy` with
/// `Location = External` that carries DDC/CI. The proxy hangs under the DCP
/// coprocessor (`dcpextN`), not under the framebuffer, but its parent is
/// named `dispextN:dcpav-service-epic:0`, so the two are joined on that
/// prefix rather than on enumeration order. Verified on macOS 26.5, M4.
public enum DisplayRegistry {
    public static func externalDisplays() -> [DiscoveredDisplay] {
        let framebuffers = externalFramebuffers()
        var displays: [DiscoveredDisplay] = []
        forEachService(matching: "DCPAVServiceProxy") { proxy in
            guard property("Location", of: proxy) as? String == "External" else { return }
            let pipe = parentName(of: proxy)?.split(separator: ":").first.map(String.init)
            displays.append(DiscoveredDisplay(
                serviceID: registryID(of: proxy),
                framebuffer: pipe,
                identity: pipe.flatMap { framebuffers[$0] }
            ))
        }
        pairByElimination(&displays, framebuffers: framebuffers)
        Log.discovery.info("found \(displays.count) external DDC display(s)")
        return displays.sorted { ($0.framebuffer ?? "~", $0.serviceID) < ($1.framebuffer ?? "~", $1.serviceID) }
    }

    /// If the naming convention ever changes, one unmatched proxy and one
    /// unmatched framebuffer can still only belong together.
    private static func pairByElimination(_ displays: inout [DiscoveredDisplay], framebuffers: [String: DisplayIdentity]) {
        let unmatched = displays.indices.filter { displays[$0].identity == nil }
        let used = Set(displays.compactMap(\.framebuffer))
        let spare = framebuffers.filter { !used.contains($0.key) }
        guard unmatched.count == 1, spare.count == 1, let (pipe, identity) = spare.first,
              let index = unmatched.first else { return }
        Log.discovery.notice("paired \(pipe, privacy: .public) with a proxy by elimination")
        displays[index].framebuffer = pipe
        displays[index].identity = identity
    }

    /// Display-pipe name (for example "dispext0") to EDID identity, for every
    /// framebuffer that has one.
    static func externalFramebuffers() -> [String: DisplayIdentity] {
        var result: [String: DisplayIdentity] = [:]
        var seen = Set<UInt64>()
        // IOMobileFramebuffer matches its subclasses: IOMobileFramebufferShim
        // on current macOS, AppleCLCD2 on older releases.
        for className in ["IOMobileFramebuffer", "AppleCLCD2"] {
            forEachService(matching: className) { framebuffer in
                guard seen.insert(registryID(of: framebuffer)).inserted,
                      let pipe = parentName(of: framebuffer),
                      let attributes = property("DisplayAttributes", of: framebuffer) as? [String: Any],
                      let product = attributes["ProductAttributes"] as? [String: Any],
                      let identity = identity(from: product) else { return }
                result[pipe] = identity
            }
        }
        return result
    }

    static func identity(from product: [String: Any]) -> DisplayIdentity? {
        func number(_ key: String) -> UInt32? {
            (product[key] as? NSNumber).flatMap { UInt32(exactly: $0.uint64Value) }
        }
        guard let vendor = number("LegacyManufacturerID") ?? (product["ManufacturerID"] as? String).flatMap(packedPnP),
              let productID = number("ProductID") else { return nil }
        return DisplayIdentity(
            vendorID: vendor,
            productID: productID,
            serialNumber: number("SerialNumber") ?? 0,
            alphanumericSerial: product["AlphanumericSerialNumber"] as? String,
            productName: product["ProductName"] as? String
        )
    }

    /// "HPN" to 0x220E.
    static func packedPnP(_ code: String) -> UInt32? {
        let letters = Array(code.uppercased().unicodeScalars)
        guard letters.count == 3, letters.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return letters.reduce(0) { $0 << 5 | (UInt32($1.value) - 64) }
    }

    // MARK: IORegistry helpers

    private static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func registryID(of entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func parentName(of entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return name(of: parent)
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        // io_name_t is a 128-byte C string.
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
