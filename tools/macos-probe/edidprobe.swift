// edidprobe.swift — read-only EDID reader/decoder for Apple Silicon Macs.
//
// Source of the EDID: the IORegistry property "EDID" on IOPortTransportStateDisplayPort
// (the USB-C/DP port transport the display is attached to). That is the copy the
// display pipeline already read at hot-plug; this tool only reads the registry
// property. It does not open any user client and never touches DDC/CI or IOAVService.
//
// Decodes: base block (identity, manufacture date, input, size, gamma, features,
// chromaticity, established/standard timings, detailed timings, range limits,
// name/serial descriptors) and CTA-861 extension blocks (flags, video/audio/speaker/
// vendor/extended data blocks, DTDs).
//
// Build:  swiftc -O edidprobe.swift -o edidprobe
// Run:    ./edidprobe                 # every display EDID found in the registry
//         ./edidprobe --hex 00ffff…   # decode a hex string instead
//         ./edidprobe --raw           # also print the raw hex

import Foundation
import IOKit

// MARK: - Registry access

/// Returns (product name, EDID bytes) for every DisplayPort transport that carries an EDID.
func registryEDIDs() -> [(String, [UInt8])] {
    var out: [(String, [UInt8])] = []
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateDisplayPort"), &iter) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        let edid = IORegistryEntryCreateCFProperty(svc, "EDID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        let name = IORegistryEntryCreateCFProperty(svc, "ProductName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if let e = edid, !e.isEmpty { out.append((name ?? "(unnamed)", [UInt8](e))) }
    }
    return out
}

// MARK: - Small helpers

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

/// 10-bit chromaticity fraction (0…1).
func chroma(_ hi: UInt8, _ lo2: UInt8) -> Double { Double(Int(hi) << 2 | Int(lo2)) / 1024 }

let cta861VICs: [Int: String] = [
    1: "640x480p60 4:3", 2: "720x480p60 4:3", 3: "720x480p60 16:9", 4: "1280x720p60", 5: "1920x1080i60",
    6: "720(1440)x480i60 4:3", 7: "720(1440)x480i60 16:9", 16: "1920x1080p60", 17: "720x576p50 4:3",
    18: "720x576p50 16:9", 19: "1280x720p50", 20: "1920x1080i50", 31: "1920x1080p50", 32: "1920x1080p24",
    33: "1920x1080p25", 34: "1920x1080p30", 63: "1920x1080p120", 64: "1920x1080p100",
    93: "3840x2160p24", 94: "3840x2160p25", 95: "3840x2160p30", 96: "3840x2160p50", 97: "3840x2160p60",
]

// MARK: - Detailed timing descriptor (18 bytes)

func decodeDTD(_ d: ArraySlice<UInt8>) -> String {
    let b = Array(d)
    let clock = Double(le16(b, 0)) * 10_000 // Hz
    let hA = Int(b[2]) | Int(b[4] & 0xF0) << 4, hB = Int(b[3]) | Int(b[4] & 0x0F) << 8
    let vA = Int(b[5]) | Int(b[7] & 0xF0) << 4, vB = Int(b[6]) | Int(b[7] & 0x0F) << 8
    let hFP = Int(b[8]) | Int(b[11] & 0xC0) << 2, hSW = Int(b[9]) | Int(b[11] & 0x30) << 4
    let vFP = Int(b[10] >> 4) | Int(b[11] & 0x0C) << 2, vSW = Int(b[10] & 0x0F) | Int(b[11] & 0x03) << 4
    let hMM = Int(b[12]) | Int(b[14] & 0xF0) << 4, vMM = Int(b[13]) | Int(b[14] & 0x0F) << 8
    let interlaced = b[17] & 0x80 != 0
    let refresh = clock / Double((hA + hB) * (vA + vB))
    let sync = b[17] & 0x18 == 0x18 ? "digital separate, H\(b[17] & 0x02 != 0 ? "+" : "-") V\(b[17] & 0x04 != 0 ? "+" : "-")" : "other (0x\(String(b[17], radix: 16)))"
    return String(format: "%dx%d%@ @ %.3f Hz, pixel clock %.2f MHz, H total %d (fp %d sync %d), V total %d (fp %d sync %d), image %dx%d mm, sync %@",
                  hA, vA, interlaced ? "i" : "p", refresh, clock / 1e6, hA + hB, hFP, hSW, vA + vB, vFP, vSW, hMM, vMM, sync)
}

// MARK: - Base block

func decodeBase(_ e: [UInt8]) {
    let header = e[0..<8] == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    let sum = e[0..<128].reduce(0) { ($0 + Int($1)) & 0xFF }
    print("  base block: header \(header ? "ok" : "BAD"), checksum \(sum == 0 ? "ok" : "BAD")")
    let m = UInt16(e[8]) << 8 | UInt16(e[9])
    let pnp = String([(m >> 10) & 0x1F, (m >> 5) & 0x1F, m & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 64)) })
    let serial = UInt32(e[12]) | UInt32(e[13]) << 8 | UInt32(e[14]) << 16 | UInt32(e[15]) << 24
    print("    manufacturer      \(pnp) (0x\(String(m, radix: 16)))")
    print("    product code      0x\(String(le16(e, 10), radix: 16)) (\(le16(e, 10)))")
    print("    serial (binary)   \(serial) (0x\(String(serial, radix: 16)))")
    print("    manufactured      \(e[16] == 0xFF ? "model year" : "week \(e[16])") \(Int(e[17]) + 1990)")
    print("    EDID version      \(e[18]).\(e[19])")

    let input = e[20]
    if input & 0x80 != 0 {
        let depth = [0: "undefined", 1: "6", 2: "8", 3: "10", 4: "12", 5: "14", 6: "16"][Int(input >> 4 & 7)] ?? "reserved"
        let iface = [0: "undefined", 1: "DVI", 2: "HDMI-a", 3: "HDMI-b", 4: "MDDI", 5: "DisplayPort"][Int(input & 0x0F)] ?? "reserved"
        print("    input             digital, \(depth) bits/colour, interface \(iface)")
    } else {
        print("    input             analog")
    }
    print("    screen size       \(e[21]) x \(e[22]) cm")
    print("    gamma             \(e[23] == 0xFF ? "in extension" : String(format: "%.2f", (Double(e[23]) + 100) / 100))")
    let f = e[24]
    let colour = ["RGB 4:4:4", "RGB 4:4:4 + YCbCr 4:4:4", "RGB 4:4:4 + YCbCr 4:2:2", "RGB 4:4:4 + YCbCr 4:4:4 + 4:2:2"][Int(f >> 3 & 3)]
    print("    DPMS              standby=\(f & 0x80 != 0) suspend=\(f & 0x40 != 0) active-off=\(f & 0x20 != 0)")
    print("    features          \(colour); sRGB default=\(f & 0x04 != 0); preferred timing is native=\(f & 0x02 != 0); continuous frequency=\(f & 0x01 != 0)")

    let lo1 = e[25], lo2 = e[26]
    let pts = [("red", e[27], lo1 >> 6), ("green", e[29], lo1 >> 2), ("blue", e[31], lo2 >> 6), ("white", e[33], lo2 >> 2)]
    let pts2 = [(e[28], lo1 >> 4), (e[30], lo1), (e[32], lo2 >> 4), (e[34], lo2)]
    let chrom = zip(pts, pts2).map { a, b in String(format: "%@ (%.4f, %.4f)", a.0, chroma(a.1, a.2 & 3), chroma(b.0, b.1 & 3)) }
    print("    chromaticity      " + chrom.joined(separator: ", "))

    let establishedTable: [(Int, UInt8, String)] = [
        (0x23, 0x80, "720x400@70"), (0x23, 0x40, "720x400@88"), (0x23, 0x20, "640x480@60"), (0x23, 0x10, "640x480@67"),
        (0x23, 0x08, "640x480@72"), (0x23, 0x04, "640x480@75"), (0x23, 0x02, "800x600@56"), (0x23, 0x01, "800x600@60"),
        (0x24, 0x80, "800x600@72"), (0x24, 0x40, "800x600@75"), (0x24, 0x20, "832x624@75"), (0x24, 0x10, "1024x768i@87"),
        (0x24, 0x08, "1024x768@60"), (0x24, 0x04, "1024x768@70"), (0x24, 0x02, "1024x768@75"), (0x24, 0x01, "1280x1024@75"),
        (0x25, 0x80, "1152x870@75"),
    ]
    let est = establishedTable.filter { e[$0.0] & $0.1 != 0 }.map(\.2)
    print("    established       " + (est.isEmpty ? "none" : est.joined(separator: " ")))

    var std: [String] = []
    for i in stride(from: 38, to: 54, by: 2) where !(e[i] == 0x01 && e[i + 1] == 0x01) {
        let w = (Int(e[i]) + 31) * 8
        let ratio = [(16, 10), (4, 3), (5, 4), (16, 9)][Int(e[i + 1] >> 6)]
        std.append("\(w)x\(w * ratio.1 / ratio.0)@\(Int(e[i + 1] & 0x3F) + 60)")
    }
    print("    standard          " + (std.isEmpty ? "none" : std.joined(separator: " ")))

    for slot in 0..<4 {
        let o = 54 + slot * 18
        let d = e[o..<o + 18]
        if e[o] != 0 || e[o + 1] != 0 { print("    descriptor \(slot + 1)      DTD \(slot == 0 ? "(preferred) " : "")" + decodeDTD(d)); continue }
        let text = String(bytes: e[o + 5..<o + 18].prefix { $0 != 0x0A }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch e[o + 3] {
        case 0xFF: print("    descriptor \(slot + 1)      serial string '\(text)'")
        case 0xFE: print("    descriptor \(slot + 1)      text '\(text)'")
        case 0xFC: print("    descriptor \(slot + 1)      name '\(text)'")
        case 0xFD:
            let vMin = Int(e[o + 5]), vMax = Int(e[o + 6]), hMin = Int(e[o + 7]), hMax = Int(e[o + 8])
            let kind = [0: "default GTF", 1: "range limits only", 2: "secondary GTF", 4: "CVT"][Int(e[o + 10])] ?? "0x\(String(e[o + 10], radix: 16))"
            print("    descriptor \(slot + 1)      range limits: V \(vMin)–\(vMax) Hz, H \(hMin)–\(hMax) kHz, max pixel clock \(Int(e[o + 9]) * 10) MHz, \(kind)")
        default: print("    descriptor \(slot + 1)      type 0x\(String(e[o + 3], radix: 16))")
        }
    }
    print("    extension blocks  \(e[126])")
}

// MARK: - CTA-861 extension

func decodeCTA(_ x: [UInt8], index: Int) {
    let sum = x.reduce(0) { ($0 + Int($1)) & 0xFF }
    print("  extension \(index): CTA-861 revision \(x[1]), checksum \(sum == 0 ? "ok" : "BAD")")
    let dtdStart = Int(x[2])
    if x[1] >= 2 {
        let f = x[3]
        print("    flags             underscan=\(f & 0x80 != 0) basicAudio=\(f & 0x40 != 0) YCbCr444=\(f & 0x20 != 0) YCbCr422=\(f & 0x10 != 0) nativeDTDs=\(f & 0x0F)")
    }
    var i = 4
    while i < dtdStart, i < 127 {
        let tag = Int(x[i] >> 5), len = Int(x[i] & 0x1F)
        let body = Array(x[(i + 1)..<min(i + 1 + len, 127)])
        switch tag {
        case 1:
            var sads: [String] = []
            for s in stride(from: 0, to: body.count - 2, by: 3) {
                let fmt = Int(body[s] >> 3 & 0x0F), ch = Int(body[s] & 7) + 1
                let rates = zip([32, 44.1, 48, 88.2, 96, 176.4, 192] as [Double], 0...).filter { body[s + 1] & UInt8(1 << $0.1) != 0 }.map { "\($0.0)" }
                sads.append("format \(fmt) \(ch)ch @ \(rates.joined(separator: "/")) kHz")
            }
            print("    audio block       " + sads.joined(separator: "; "))
        case 2:
            let vics = body.map { b -> String in
                let vic = Int(b & 0x7F) == 0 ? Int(b) : (b >= 129 && b <= 192 ? Int(b & 0x7F) : Int(b))
                let native = b >= 129 && b <= 192 ? " (native)" : ""
                return "VIC \(vic) \(cta861VICs[vic] ?? "?")\(native)"
            }
            print("    video block       " + vics.joined(separator: ", "))
        case 3:
            let oui = body.count >= 3 ? String(format: "%02X-%02X-%02X", body[2], body[1], body[0]) : "?"
            print("    vendor block      OUI \(oui) (\(oui == "00-0C-03" ? "HDMI 1.x" : oui == "C4-5D-D8" ? "HDMI Forum" : "other")) payload \(hex(body))")
        case 4: print("    speaker alloc     0x\(hex(body))")
        case 7:
            let ext = body.first ?? 0xFF
            let rest = Array(body.dropFirst())
            switch ext {
            case 0:
                let v = rest.first ?? 0
                print("    video capability  QY(RGB quant selectable)=\(v & 0x80 != 0) QS(YCC quant selectable)=\(v & 0x40 != 0) S_PT=\(v >> 4 & 3) S_IT=\(v >> 2 & 3) S_CE=\(v & 3)")
            case 5: print("    colorimetry       0x\(hex(rest))")
            case 6: print("    HDR static meta   EOTFs 0x\(String(rest.first ?? 0, radix: 16)) payload \(hex(rest))")
            default: print("    extended tag \(ext)    \(hex(rest))")
            }
        default: print("    block tag \(tag)       \(hex(body))")
        }
        i += 1 + len
    }
    var o = dtdStart
    while dtdStart > 0, o + 18 <= 127, x[o] != 0 || x[o + 1] != 0 {
        print("    DTD               " + decodeDTD(x[o..<o + 18]))
        o += 18
    }
}

func decode(_ name: String, _ e: [UInt8], raw: Bool) {
    print("== \(name): \(e.count) bytes")
    if raw { print("  raw \(hex(e))") }
    guard e.count >= 128 else { print("  too short"); return }
    decodeBase(e)
    for n in 1..<(e.count / 128) {
        let block = Array(e[(n * 128)..<(n * 128 + 128)])
        if block[0] == 0x02 { decodeCTA(block, index: n) } else { print("  extension \(n): tag 0x\(String(block[0], radix: 16)) (not decoded)") }
    }
}

// MARK: - Main

let argv = Array(CommandLine.arguments.dropFirst())
let raw = argv.contains("--raw")
if let h = argv.firstIndex(of: "--hex"), h + 1 < argv.count {
    let s = argv[h + 1].filter(\.isHexDigit)
    let bytes = stride(from: 0, to: s.count - 1, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! }
    decode("hex input", bytes, raw: raw)
} else {
    let found = registryEDIDs()
    if found.isEmpty { print("no EDID found on any IOPortTransportStateDisplayPort") }
    for (name, e) in found { decode(name, e, raw: raw) }
}
