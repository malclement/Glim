import AudioToolbox
import CoreAudio
import Foundation

/// An audio output whose level and mute Glim controls.
public protocol AudioOutput: Actor {
    nonisolated var deviceName: String { get }
    /// Volume, 0 to 1, on the device's own perceptual curve.
    func volume() throws -> Double
    func setVolume(_ value: Double) throws
    func isMuted() throws -> Bool
    func setMuted(_ muted: Bool) throws
}

public enum AudioError: Error, Equatable, Sendable {
    /// The device went away, for example because the monitor was unplugged.
    case deviceUnavailable
    /// The device has no such control.
    case notSupported
    case coreAudio(OSStatus)
}

extension AudioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "The display's speakers are no longer connected."
        case .notSupported: "The display's speakers don't support this control."
        case .coreAudio(let status): "Core Audio error \(status)."
        }
    }
}

/// A CoreAudio output device, as listed by the HAL.
public struct AudioDeviceInfo: Hashable, Sendable {
    public var id: AudioObjectID
    public var name: String
    public var isUSB: Bool

    public init(id: AudioObjectID, name: String, isUSB: Bool) {
        self.id = id
        self.name = name
        self.isUSB = isUSB
    }
}

public enum AudioDevices {
    /// Every device with output streams.
    public static func outputs() -> [AudioDeviceInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids: [AudioObjectID] = arrayProperty(system, kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            let streams: [AudioObjectID] = arrayProperty(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard !streams.isEmpty, let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32 = scalarProperty(id, kAudioDevicePropertyTransportType) ?? 0
            return AudioDeviceInfo(id: id, name: name, isUSB: transport == kAudioDeviceTransportTypeUSB)
        }
    }

    // MARK: Property helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalarProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func arrayProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// A CoreAudio output device's volume and mute.
///
/// Volume goes through the HAL's *virtual main volume*
/// (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, served by the
/// plain AudioObject API since the AudioHardwareService functions were
/// deprecated), which is what the macOS volume menu uses. It works for devices
/// that, like the HP E27m G4's USB Audio, have per-channel volume but no main
/// volume element, and it keeps the channel balance. Mute is the device's main
/// mute.
///
/// CoreAudio calls are IPC to the audio server, so they run on this actor's
/// own queue instead of the main thread.
public actor CoreAudioOutput: AudioOutput {
    public nonisolated let deviceName: String
    private let id: AudioObjectID
    private let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(device: AudioDeviceInfo) {
        self.id = device.id
        self.deviceName = device.name
        self.queue = DispatchSerialQueue(label: "glim.audio.\(device.id)", qos: .userInitiated)
    }

    public func volume() throws -> Double {
        var address = Self.volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try check(hasProperty: &address)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return Double(value)
    }

    public func setVolume(_ volume: Double) throws {
        var address = Self.volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        try check(hasProperty: &address)
        try check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value))
    }

    public func isMuted() throws -> Bool {
        var address = Self.muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(hasProperty: &address)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return value != 0
    }

    public func setMuted(_ muted: Bool) throws {
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        try check(hasProperty: &address)
        try check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private static let volumeAddress = AudioDevices.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput
    )
    private static let muteAddress = AudioDevices.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)

    private func check(hasProperty address: inout AudioObjectPropertyAddress) throws(AudioError) {
        try checkAlive()
        guard AudioObjectHasProperty(id, &address) else { throw .notSupported }
    }

    private func checkAlive() throws(AudioError) {
        let alive: UInt32? = AudioDevices.scalarProperty(id, kAudioDevicePropertyDeviceIsAlive)
        guard alive == 1 else { throw .deviceUnavailable }
    }

    private func check(_ status: OSStatus) throws(AudioError) {
        guard status == noErr else {
            throw status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
                ? .deviceUnavailable : .coreAudio(status)
        }
    }
}
