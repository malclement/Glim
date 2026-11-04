// audioprobe.swift — read-only CoreAudio inventory of audio devices: identity,
// transport, sample rates, physical/virtual stream formats, channel layout,
// data sources, clock, latency, and every volume / mute control per scope and
// channel together with whether macOS lets software set it.
//
// Only property *getters* and AudioObjectIsPropertySettable are called; no
// property is ever written, no IO proc is started, hog mode is not taken.
//
// Build:  swiftc -O audioprobe.swift -o audioprobe
// Run:    ./audioprobe            # all devices
//         ./audioprobe "HP E27m"  # only devices whose name contains the string

import CoreAudio
import Foundation

// MARK: - Generic property access

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
}

func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a
    return AudioObjectHasProperty(obj, &a)
}

func settable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a, s: DarwinBoolean = false
    return AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s.boolValue
}

/// Reads a fixed-size scalar property.
func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    guard has(obj, a) else { return nil }
    var a = a, v = initial, size = UInt32(MemoryLayout<T>.size)
    let err = withUnsafeMutableBytes(of: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!) }
    return err == noErr ? v : nil
}

/// Reads a variable-length array property.
func getArray<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> [T] {
    guard has(obj, a) else { return [] }
    var a = a, size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    let err = arr.withUnsafeMutableBytes { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!) }
    guard err == noErr else { return [] }
    return Array(arr.prefix(Int(size) / MemoryLayout<T>.stride))
}

func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    guard has(obj, a) else { return nil }
    var a = a, s: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr else { return nil }
    return s?.takeRetainedValue() as String?
}

func fourCC(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    return b.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? "'" + String(bytes: b, encoding: .ascii)! + "'" : String(format: "0x%08x", v)
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    return String(format: "%.0f Hz %u ch %u-bit %@ %@", f.mSampleRate, f.mChannelsPerFrame, f.mBitsPerChannel,
                  isFloat ? "float" : "int", fourCC(f.mFormatID))
}

// MARK: - Device sections

let scopes: [(String, AudioObjectPropertyScope)] = [("output", kAudioObjectPropertyScopeOutput), ("input", kAudioObjectPropertyScopeInput)]

func channelCount(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func printControls(_ d: AudioObjectID, _ name: String, _ scope: AudioObjectPropertyScope, channels: Int) {
    for el in 0...UInt32(channels) {
        let label = el == 0 ? "main" : "ch\(el)"
        var parts: [String] = []
        let vAddr = addr(kAudioDevicePropertyVolumeScalar, scope, el)
        if let v = get(d, vAddr, Float32(0)) {
            parts.append(String(format: "volume %.3f%@", v, settable(d, vAddr) ? " (settable)" : " (read-only)"))
            if let db = get(d, addr(kAudioDevicePropertyVolumeDecibels, scope, el), Float32(0)) { parts.append(String(format: "%.2f dB", db)) }
            if let r = get(d, addr(kAudioDevicePropertyVolumeRangeDecibels, scope, el), AudioValueRange()) {
                parts.append(String(format: "range %.2f…%.2f dB", r.mMinimum, r.mMaximum))
            }
        }
        let mAddr = addr(kAudioDevicePropertyMute, scope, el)
        if let m = get(d, mAddr, UInt32(0)) { parts.append("mute=\(m)\(settable(d, mAddr) ? " (settable)" : " (read-only)")") }
        let pAddr = addr(kAudioDevicePropertyPlayThru, scope, el)
        if let p = get(d, pAddr, UInt32(0)) { parts.append("playthru=\(p)") }
        if !parts.isEmpty { print("      \(name) \(label): " + parts.joined(separator: ", ")) }
    }
    let stereo = getArray(d, addr(kAudioDevicePropertyPreferredChannelsForStereo, scope), UInt32(0))
    if !stereo.isEmpty { print("      \(name) preferred stereo channels: \(stereo)") }
    let sources = getArray(d, addr(kAudioDevicePropertyDataSources, scope), UInt32(0))
    if !sources.isEmpty {
        let current = get(d, addr(kAudioDevicePropertyDataSource, scope), UInt32(0))
        print("      \(name) data sources: " + sources.map { fourCC($0) + ($0 == current ? "*" : "") }.joined(separator: " "))
    } else {
        print("      \(name) data sources: none exposed")
    }
}

func printStreams(_ d: AudioObjectID, _ name: String, _ scope: AudioObjectPropertyScope) {
    for s in getArray(d, addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0)) {
        let term = get(s, addr(kAudioStreamPropertyTerminalType), UInt32(0)).map { String(format: "0x%x", $0) } ?? "?"
        print("      \(name) stream \(s): terminal type \(term)")
        if let p = get(s, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) { print("        current physical: \(describe(p))") }
        if let v = get(s, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()) { print("        current virtual:  \(describe(v))") }
        let phys = getArray(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription())
        let uniq = Array(Set(phys.map { describe($0.mFormat) })).sorted()
        print("        available physical (\(uniq.count)): " + uniq.joined(separator: " | "))
    }
}

func printDevice(_ d: AudioObjectID, defaults: [String: AudioObjectID]) {
    let name = getString(d, addr(kAudioObjectPropertyName)) ?? "?"
    print("\n== device \(d): \(name)")
    print("    manufacturer   \(getString(d, addr(kAudioObjectPropertyManufacturer)) ?? "?")")
    print("    UID            \(getString(d, addr(kAudioDevicePropertyDeviceUID)) ?? "?")")
    print("    model UID      \(getString(d, addr(kAudioDevicePropertyModelUID)) ?? "?")")
    print("    transport      \(get(d, addr(kAudioDevicePropertyTransportType), UInt32(0)).map(fourCC) ?? "?")")
    let flags = defaults.filter { $0.value == d }.map(\.key).sorted()
    print("    default for    \(flags.isEmpty ? "nothing" : flags.joined(separator: ", "))")
    print("    alive=\(get(d, addr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) running=\(get(d, addr(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) hogPID=\(get(d, addr(kAudioDevicePropertyHogMode), pid_t(0)) ?? -1)")
    let srAddr = addr(kAudioDevicePropertyNominalSampleRate)
    if let sr = get(d, srAddr, Float64(0)) { print("    nominal rate   \(sr) Hz\(settable(d, srAddr) ? " (settable)" : "")") }
    let rates = getArray(d, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
    print("    available      " + rates.map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))–\(Int($0.mMaximum))" }.joined(separator: ", ") + " Hz")
    if let r = get(d, addr(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange()),
       let b = get(d, addr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) {
        print("    buffer frames  \(b) (range \(Int(r.mMinimum))–\(Int(r.mMaximum)))")
    }
    if let cs = get(d, addr(kAudioDevicePropertyClockSource), UInt32(0)) { print("    clock source   \(fourCC(cs))") }
    for (sname, scope) in scopes {
        let ch = channelCount(d, scope)
        guard ch > 0 else { continue }
        let lat = get(d, addr(kAudioDevicePropertyLatency, scope), UInt32(0)) ?? 0
        let safety = get(d, addr(kAudioDevicePropertySafetyOffset, scope), UInt32(0)) ?? 0
        print("    \(sname): \(ch) channel(s), latency \(lat) frames, safety offset \(safety) frames")
        printStreams(d, sname, scope)
        printControls(d, sname, scope, channels: ch)
    }
    // Control objects the HAL plug-in publishes (volume, mute, selector, …), independent of the device-level shortcuts above.
    let owned = getArray(d, addr(kAudioObjectPropertyOwnedObjects), AudioObjectID(0))
    for o in owned {
        guard let cls = get(o, addr(kAudioObjectPropertyClass), AudioClassID(0)), cls != kAudioStreamClassID else { continue }
        let base = get(o, addr(kAudioObjectPropertyBaseClass), AudioClassID(0)) ?? 0
        let sc = get(o, addr(kAudioControlPropertyScope), AudioObjectPropertyScope(0)) ?? 0
        let el = get(o, addr(kAudioControlPropertyElement), AudioObjectPropertyElement(0)) ?? 0
        print("    control object \(o): class \(fourCC(cls)) base \(fourCC(base)) scope \(fourCC(sc)) element \(el)")
    }
}

// MARK: - Main

let filter = CommandLine.arguments.dropFirst().first
let system = AudioObjectID(kAudioObjectSystemObject)
let defaults: [String: AudioObjectID] = [
    "default output": get(system, addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0,
    "default input": get(system, addr(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0)) ?? 0,
    "system sounds": get(system, addr(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioObjectID(0)) ?? 0,
]
let devices = getArray(system, addr(kAudioHardwarePropertyDevices), AudioObjectID(0))
print("audioprobe — \(devices.count) device(s)")
for d in devices {
    let name = getString(d, addr(kAudioObjectPropertyName)) ?? ""
    if let f = filter, !name.localizedCaseInsensitiveContains(f) { continue }
    printDevice(d, defaults: defaults)
}
