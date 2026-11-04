// hpvolume — read or set the HP monitor's USB Audio output volume (CoreAudio scalar, per channel).
// Works on a non-default output device, unlike `osascript set volume`.
// Build: swiftc -O hpvolume.swift -o hpvolume
// Usage: hpvolume            -> prints "ch1 ch2" scalars (0.0–1.0) and ch1 dB
//        hpvolume <0.0-1.0>  -> sets both channels by scalar
//        hpvolume db <dB>    -> sets both channels in decibels (-74…0); finer than the scalar
// The monitor mirrors this level into DDC VCP 0x62, which is read-only over DDC.
import CoreAudio
import Foundation

func devices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func name(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return "" }
    return s.takeRetainedValue() as String
}

func hasOutput(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    return size > 0
}

func volume(_ id: AudioObjectID, _ ch: UInt32) -> Float32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: kAudioDevicePropertyScopeOutput, mElement: ch)
    var v: Float32 = -1
    var size = UInt32(MemoryLayout<Float32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
    return v
}

func setVolume(_ id: AudioObjectID, _ ch: UInt32, _ value: Float32) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: kAudioDevicePropertyScopeOutput, mElement: ch)
    var v = value
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

guard let dev = devices().first(where: { name($0).contains("HP E27m G4") && hasOutput($0) }) else {
    FileHandle.standardError.write("HP E27m G4 USB Audio output not found\n".data(using: .utf8)!)
    exit(1)
}
func decibels(_ id: AudioObjectID, _ ch: UInt32, set value: Float32? = nil) -> Float32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                          mScope: kAudioDevicePropertyScopeOutput, mElement: ch)
    var size = UInt32(MemoryLayout<Float32>.size)
    if var v = value { AudioObjectSetPropertyData(id, &addr, 0, nil, size, &v) }
    var out: Float32 = 0
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &out)
    return out
}

let args = CommandLine.arguments
if args.count > 2, args[1] == "db", let db = Float32(args[2]) {
    // Scalar steps are coarse; decibels reach every hardware step.
    _ = decibels(dev, 1, set: db); _ = decibels(dev, 2, set: db)
} else if args.count > 1, let v = Float32(args[1]) {
    setVolume(dev, 1, v); setVolume(dev, 2, v)
}
print(String(format: "%.4f %.4f (%.2f dB)", volume(dev, 1), volume(dev, 2), decibels(dev, 1)))
