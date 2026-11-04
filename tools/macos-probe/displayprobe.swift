// displayprobe.swift — read-only dump of everything macOS's display layer knows
// about each online display: identity, arrangement, mirroring, rotation, every
// display mode (including duplicate low-resolution / HiDPI variants), gamma
// transfer, ColorSync profile, EDR/HDR, and the private DisplayServices
// software-brightness hooks, plus the system-wide Night Shift / True Tone state
// (private CoreBrightness).
//
// It NEVER changes anything: no mode switch, no gamma write, no brightness
// write, no configuration transaction. Every API it calls is a getter.
// It does not touch DDC/CI or IOAVService.
//
// Build:  swiftc -O displayprobe.swift -o displayprobe
// Run:    ./displayprobe            # all displays
//         ./displayprobe --external # skip built-in panels
//         ./displayprobe --no-modes # skip the (long) mode table

import AppKit
import ColorSync
import CoreGraphics
import Foundation

// MARK: - IOGraphicsTypes.h mode flags (defined locally so the file has no IOKit.graphics dependency)

let modeFlagNames: [(UInt32, String)] = [
    (0x0000_0002, "safe"),
    (0x0000_0004, "default"),
    (0x0000_0008, "alwaysShow"),
    (0x0000_0040, "interlaced"),
    (0x0000_0080, "neverShow"),
    (0x0000_0200, "notPreset"),
    (0x0000_0800, "stretched"),
    (0x0020_0000, "mirror"),
    (0x0080_0000, "validForHiRes"),
    (0x0200_0000, "native"),
]

func flagString(_ f: UInt32) -> String {
    modeFlagNames.filter { f & $0.0 != 0 }.map(\.1).joined(separator: ",")
}

// MARK: - Private-framework getters, resolved lazily with dlsym (absent symbol -> "n/a")

/// Opens a framework and looks a symbol up, returning nil rather than crashing if either is missing.
func privateSymbol(_ framework: String, _ name: String) -> UnsafeMutableRawPointer? {
    guard let handle = dlopen(framework, RTLD_LAZY) else { return nil }
    return dlsym(handle, name)
}

let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

typealias BoolOfDisplay = @convention(c) (CGDirectDisplayID) -> Bool
typealias FloatOutOfDisplay = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

func callBool(_ fw: String, _ name: String, _ d: CGDirectDisplayID) -> String {
    guard let p = privateSymbol(fw, name) else { return "n/a (symbol missing)" }
    return unsafeBitCast(p, to: BoolOfDisplay.self)(d) ? "yes" : "no"
}

func callFloat(_ fw: String, _ name: String, _ d: CGDirectDisplayID) -> String {
    guard let p = privateSymbol(fw, name) else { return "n/a (symbol missing)" }
    var v: Float = -1
    let err = unsafeBitCast(p, to: FloatOutOfDisplay.self)(d, &v)
    return err == 0 ? String(format: "%.4f", v) : "error \(err) (not supported for this display)"
}

// MARK: - Helpers

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08x", v)
}

/// EDID manufacturer ID is three 5-bit letters packed big-endian into 16 bits.
func pnpID(_ vendor: UInt32) -> String {
    let v = UInt16(truncatingIfNeeded: vendor)
    let letters = [(v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 64)) }
    return String(letters)
}

func screen(for d: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d
    }
}

// MARK: - Sections

func printIdentity(_ d: CGDirectDisplayID) {
    let vendor = CGDisplayVendorNumber(d), model = CGDisplayModelNumber(d)
    print("  identity")
    print("    vendor            0x\(String(vendor, radix: 16)) (\(vendor)) PnP '\(pnpID(vendor))'")
    print("    model/product     0x\(String(model, radix: 16)) (\(model))")
    print("    serial (EDID bin) \(CGDisplaySerialNumber(d))")
    print("    unit number       \(CGDisplayUnitNumber(d))")
    if let uuid = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() {
        print("    display UUID      \(CFUUIDCreateString(nil, uuid)! as String)")
    }
    if let s = screen(for: d) { print("    localizedName     \(s.localizedName)") }
    let mm = CGDisplayScreenSize(d)
    print(String(format: "    physical size     %.0f x %.0f mm (%.1f\" diagonal)", mm.width, mm.height,
                 (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4))
}

func printState(_ d: CGDirectDisplayID) {
    let b = CGDisplayBounds(d)
    print("  state / arrangement")
    print("    builtin=\(CGDisplayIsBuiltin(d) != 0) main=\(CGDisplayIsMain(d) != 0) active=\(CGDisplayIsActive(d) != 0) online=\(CGDisplayIsOnline(d) != 0) asleep=\(CGDisplayIsAsleep(d) != 0) stereo=\(CGDisplayIsStereo(d) != 0)")
    print("    origin            (\(Int(b.origin.x)), \(Int(b.origin.y)))  size \(Int(b.width))x\(Int(b.height)) pt (global coords, main display at 0,0)")
    print("    pixels            \(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d)) (legacy, = points)")
    print("    rotation          \(CGDisplayRotation(d))°")
    let mirrors = CGDisplayMirrorsDisplay(d)
    print("    mirroring         inMirrorSet=\(CGDisplayIsInMirrorSet(d) != 0) alwaysInMirrorSet=\(CGDisplayIsAlwaysInMirrorSet(d) != 0) mirrorsDisplay=\(mirrors == kCGNullDirectDisplay ? "none" : String(mirrors)) primaryOfSet=\(CGDisplayPrimaryDisplay(d))")
    if let s = screen(for: d) {
        print("    NSScreen          backingScale=\(s.backingScaleFactor) frame=\(NSStringFromRect(s.frame)) visible=\(NSStringFromRect(s.visibleFrame))")
        print("    EDR headroom      potential=\(s.maximumPotentialExtendedDynamicRangeColorComponentValue) current=\(s.maximumExtendedDynamicRangeColorComponentValue) reference=\(s.maximumReferenceExtendedDynamicRangeColorComponentValue)  (1.0 = SDR only)")
    }
    print("    SkyLight HDR      supportsHDRMode=\(callBool(skyLight, "SLSDisplaySupportsHDRMode", d)) hdrEnabled=\(callBool(skyLight, "SLSDisplayIsHDRModeEnabled", d))")
}

func printBrightness(_ d: CGDirectDisplayID) {
    print("  software brightness (private DisplayServices — read only)")
    print("    canChangeBrightness        \(callBool(displayServices, "DisplayServicesCanChangeBrightness", d))")
    print("    getBrightness              \(callFloat(displayServices, "DisplayServicesGetBrightness", d))")
    print("    getLinearBrightness        \(callFloat(displayServices, "DisplayServicesGetLinearBrightness", d))")
    print("    hasAmbientLightCompensation \(callBool(displayServices, "DisplayServicesHasAmbientLightCompensation", d))")
    print("    isSmartDisplay             \(callBool(displayServices, "DisplayServicesIsSmartDisplay", d))")
    print("    isBuiltInDisplay           \(callBool(displayServices, "DisplayServicesIsBuiltInDisplay", d))")
}

func printGamma(_ d: CGDirectDisplayID) {
    print("  gamma / transfer (CoreGraphics — read only)")
    let cap = CGDisplayGammaTableCapacity(d)
    print("    table capacity    \(cap) entries per channel")
    var rMin: CGGammaValue = 0, rMax: CGGammaValue = 0, rG: CGGammaValue = 0
    var gMin: CGGammaValue = 0, gMax: CGGammaValue = 0, gG: CGGammaValue = 0
    var bMin: CGGammaValue = 0, bMax: CGGammaValue = 0, bG: CGGammaValue = 0
    let fErr = CGGetDisplayTransferByFormula(d, &rMin, &rMax, &rG, &gMin, &gMax, &gG, &bMin, &bMax, &bG)
    if fErr == .success {
        print(String(format: "    formula           R min %.3f max %.3f γ %.3f | G %.3f %.3f %.3f | B %.3f %.3f %.3f",
                     rMin, rMax, rG, gMin, gMax, gG, bMin, bMax, bG))
    } else {
        print("    formula           error \(fErr.rawValue)")
    }
    guard cap > 0 else { return }
    var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
    var n: UInt32 = 0
    let tErr = CGGetDisplayTransferByTable(d, cap, &r, &g, &b, &n)
    guard tErr == .success, n > 0 else { print("    table             error \(tErr.rawValue)"); return }
    let idx = [0, Int(n) / 4, Int(n) / 2, 3 * Int(n) / 4, Int(n) - 1]
    let sample = idx.map { String(format: "[%d]=%.3f/%.3f/%.3f", $0, r[$0], g[$0], b[$0]) }.joined(separator: " ")
    // An untouched table is a straight 0→1 ramp, identical on all three channels.
    var identity = true
    for i in 0..<Int(n) {
        let expected = Float(i) / Float(n - 1)
        if abs(r[i] - expected) > 0.002 || r[i] != g[i] || g[i] != b[i] { identity = false; break }
    }
    print("    table (\(n))       \(sample)")
    print("    table is identity ramp: \(identity)")
}

func printColor(_ d: CGDirectDisplayID) {
    print("  color (ColorSync)")
    let cs = CGDisplayCopyColorSpace(d)
    print("    CG color space    name=\(cs.name.map { $0 as String } ?? "(unnamed)") model=\(cs.model.rawValue) components=\(cs.numberOfComponents)")
    if let icc = cs.copyICCData(),
       let prof = ColorSyncProfileCreate(icc, nil)?.takeRetainedValue() {
        let desc = ColorSyncProfileCopyDescriptionString(prof)?.takeRetainedValue() as String? ?? "?"
        print("    active profile    '\(desc)' (\(CFDataGetLength(icc)) bytes ICC)")
    }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue(),
          let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
              .takeRetainedValue() as? [String: Any] else { return }
    for key in ["FactoryProfiles", "CustomProfiles"] {
        guard let profiles = info[key] as? [String: Any] else { continue }
        for (pid, value) in profiles {
            if let p = value as? [String: Any] {
                let url = (p["DeviceProfileURL"] as? URL)?.path ?? (p["DeviceProfileURL"].map { "\($0)" } ?? "-")
                print("    \(key) [\(pid)] \(url)")
            } else {
                print("    \(key) [\(pid)] \(value)")
            }
        }
    }
    if let def = (info["FactoryProfiles"] as? [String: Any])?["DeviceDefaultProfileID"] { print("    default profile id \(def)") }
}

func printModes(_ d: CGDirectDisplayID) {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] else { return }
    let current = CGDisplayCopyDisplayMode(d)
    print("  display modes (\(modes.count), incl. duplicate low-res; * = current)")
    print("        id   points       pixels       Hz      HiDPI  GUI   flags")
    // Sort by pixel size, then refresh rate, then point size — all descending.
    let sorted = modes.sorted { (a: CGDisplayMode, b: CGDisplayMode) -> Bool in
        if a.pixelWidth != b.pixelWidth { return a.pixelWidth > b.pixelWidth }
        if a.pixelHeight != b.pixelHeight { return a.pixelHeight > b.pixelHeight }
        if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
        return a.width > b.width
    }
    for m in sorted {
        let cur = (current?.ioDisplayModeID == m.ioDisplayModeID) ? "*" : " "
        let hidpi = m.pixelWidth > m.width ? "yes" : "no"
        print(String(format: "    %@ %5d %5zux%-5zu  %5zux%-5zu  %6.2f  %-5@  %-5@ %@",
                     cur, m.ioDisplayModeID, m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate,
                     hidpi, m.isUsableForDesktopGUI() ? "yes" : "no", flagString(m.ioFlags)))
    }
    if let c = current {
        print("  current mode       \(c.width)x\(c.height) pt, \(c.pixelWidth)x\(c.pixelHeight) px @ \(c.refreshRate) Hz, id \(c.ioDisplayModeID), flags [\(flagString(c.ioFlags))]")
    }
}

// MARK: - Night Shift / True Tone (private CoreBrightness, system-wide — not per display)

typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
typealias PtrGetter = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

/// Calls a no-argument BOOL-returning Objective-C getter, if the object responds to it.
func objcBool(_ obj: AnyObject, _ sel: String) -> String {
    let s = NSSelectorFromString(sel)
    guard obj.responds(to: s), let imp = (obj as? NSObject)?.method(for: s) else { return "n/a" }
    return unsafeBitCast(imp, to: BoolGetter.self)(obj, s) ? "yes" : "no"
}

func printNightShiftAndTrueTone() {
    print("\n== system-wide colour adaptation (private CoreBrightness — read only)")
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else {
        print("  CoreBrightness not loadable"); return
    }
    if let blue = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
        let client = blue.init()
        // getBlueLightStatus: fills a C struct {BOOL active, enabled, sunSchedulePermitted; int mode;
        // {int h,m} from, to; uint64 disableFlags; BOOL available} — read it by offset, not by Swift layout.
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        let sel = NSSelectorFromString("getBlueLightStatus:")
        if client.responds(to: sel), unsafeBitCast(client.method(for: sel), to: PtrGetter.self)(client, sel, buf) {
            let b = { (o: Int) in buf.load(fromByteOffset: o, as: UInt8.self) != 0 }
            let i = { (o: Int) in buf.load(fromByteOffset: o, as: Int32.self) }
            let modes = [0: "off/manual", 1: "sunset-to-sunrise", 2: "custom schedule"]
            print("  Night Shift   active=\(b(0)) enabled=\(b(1)) sunSchedulePermitted=\(b(2)) mode=\(modes[Int(i(4))] ?? String(i(4)))")
            print(String(format: "                schedule %02d:%02d -> %02d:%02d  disableFlags=0x%llx available=%@",
                         i(8), i(12), i(16), i(20), buf.load(fromByteOffset: 24, as: UInt64.self), b(32) ? "yes" : "no"))
        }
        let cctSel = NSSelectorFromString("getCCT:")
        var cct: Float = 0
        if client.responds(to: cctSel), unsafeBitCast(client.method(for: cctSel), to: PtrGetter.self)(client, cctSel, &cct) {
            print("                getCCT (colour temperature target, K) = \(cct)")
        }
    }
    if let tt = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
        let client = tt.init()
        print("  True Tone     supported=\(objcBool(client, "supported")) available=\(objcBool(client, "available")) enabled=\(objcBool(client, "enabled"))")
    }
    print("  (Neither API is per-display. Night Shift is applied by the display pipeline to every display it")
    print("   drives; True Tone only adapts displays with Apple's ambient-sensor integration.)")
}

// MARK: - Main

let args = Set(CommandLine.arguments.dropFirst())
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

print("displayprobe — \(count) online display(s); main display id \(CGMainDisplayID())")
for d in ids {
    if args.contains("--external"), CGDisplayIsBuiltin(d) != 0 { continue }
    print("\n== display \(d)\(CGDisplayIsBuiltin(d) != 0 ? " (built-in)" : "")")
    printIdentity(d)
    printState(d)
    printBrightness(d)
    printGamma(d)
    printColor(d)
    if !args.contains("--no-modes") { printModes(d) }
}
printNightShiftAndTrueTone()
