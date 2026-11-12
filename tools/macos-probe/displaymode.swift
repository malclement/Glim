// displaymode — list or set the mode of the external display with the given EDID vendor/product.
// usage: displaymode list | current | set <width> <height> <hz>   (non-HiDPI modes only)
import CoreGraphics
import Foundation

let vendor: UInt32 = 0x220E, product: UInt32 = 0x3753
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
guard let display = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product }) else {
    print("display not found"); exit(1)
}
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []
func describe(_ m: CGDisplayMode) -> String {
    "\(m.width)x\(m.height) pt, \(m.pixelWidth)x\(m.pixelHeight) px @ \(String(format: "%.2f", m.refreshRate)) Hz, id \(m.ioDisplayModeID)"
}
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "current":
    if let m = CGDisplayCopyDisplayMode(display) { print(describe(m)) }
case "set":
    let a = Array(args.dropFirst())
    guard a.count == 3, let w = Int(a[0]), let h = Int(a[1]), let hz = Double(a[2]),
          let m = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == w && $0.pixelHeight == h && abs($0.refreshRate - hz) < 0.6 }) else {
        print("no such non-HiDPI mode"); exit(1)
    }
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, display, m, nil)
    let rc = CGCompleteDisplayConfiguration(config, .forSession)
    print(rc == .success ? "set \(describe(m))" : "failed \(rc.rawValue)")
default:
    for m in modes where m.pixelWidth == m.width { print(describe(m)) }
}
