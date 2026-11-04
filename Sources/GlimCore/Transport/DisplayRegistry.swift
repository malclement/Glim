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
        var proxies: [Proxy] = []
        forEachService(matching: "DCPAVServiceProxy") { proxy in
            guard property("Location", of: proxy) as? String == "External" else { return }
            let pipe = parentName(of: proxy)?.split(separator: ":").first.map(String.init)
            proxies.append(Proxy(serviceID: registryID(of: proxy), pipe: pipe))
        }
        let displays = pair(proxies, with: externalFramebuffers())
        Log.discovery.info("found \(displays.count) external DDC display(s)")
        return displays
    }

    /// A `DCPAVServiceProxy` and the display pipe its parent's name points to.
    struct Proxy: Equatable {
        var serviceID: UInt64
        var pipe: String?
    }

    /// Joins transports to framebuffers by display pipe.
    ///
    /// `framebuffers` maps every *external* pipe to its EDID identity, nil
    /// while the EDID is not published yet. A proxy whose pipe is known gets
    /// that pipe's identity, even nil: the next rescan fills it in. Only a
    /// proxy whose name matches no framebuffer at all (the naming convention
    /// broke) is paired by elimination, and only when exactly one such proxy
    /// and one unclaimed framebuffer with an identity are left.
    static func pair(_ proxies: [Proxy], with framebuffers: [String: DisplayIdentity?]) -> [DiscoveredDisplay] {
        var displays = proxies.map { proxy -> DiscoveredDisplay in
            guard let pipe = proxy.pipe, let identity = framebuffers[pipe] else {
                return DiscoveredDisplay(serviceID: proxy.serviceID)
            }
            return DiscoveredDisplay(serviceID: proxy.serviceID, framebuffer: pipe, identity: identity)
        }
        let orphans = displays.indices.filter { displays[$0].framebuffer == nil }
        let claimed = Set(displays.compactMap(\.framebuffer))
        let spare = framebuffers.compactMap { pipe, identity -> (String, DisplayIdentity)? in
            guard !claimed.contains(pipe), let identity else { return nil }
            return (pipe, identity)
        }
        if orphans.count == 1, spare.count == 1, let index = orphans.first, let (pipe, identity) = spare.first {
            Log.discovery.notice("paired \(pipe, privacy: .public) with a proxy by elimination")
            displays[index].framebuffer = pipe
            displays[index].identity = identity
        }
        return displays.sorted { ($0.framebuffer ?? "~", $0.serviceID) < ($1.framebuffer ?? "~", $1.serviceID) }
    }

    /// Every external display pipe (for example "dispext0") and the EDID
    /// identity of its framebuffer, nil when it has none yet. The built-in
    /// panel's pipe (`disp0`) is left out.
    static func externalFramebuffers() -> [String: DisplayIdentity?] {
        var result: [String: DisplayIdentity?] = [:]
        var seen = Set<UInt64>()
        // IOMobileFramebuffer matches its subclasses: IOMobileFramebufferShim
        // on current macOS, AppleCLCD2 on older releases.
        for className in ["IOMobileFramebuffer", "AppleCLCD2"] {
            forEachService(matching: className) { framebuffer in
                guard seen.insert(registryID(of: framebuffer)).inserted,
                      let pipe = parentName(of: framebuffer) else { return }
                // Two independent signs of an external pipe, so that either
                // one changing in a future release is not enough to let the
                // built-in panel in.
                let flagged = (property("external", of: framebuffer) as? NSNumber)?.boolValue == true
                guard flagged || pipe.hasPrefix("dispext") else { return }
                let attributes = property("DisplayAttributes", of: framebuffer) as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                result[pipe] = product.flatMap(identity(from:))
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
