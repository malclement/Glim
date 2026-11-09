import CoreGraphics
import Foundation
import IOKit

/// What automatic brightness reads from the Mac: the light in the room, the
/// built-in display's own brightness, the lid, and the time. Tests script it.
@MainActor
public protocol AdaptiveEnvironment: AnyObject {
    /// Whether the light sensor can be read on this Mac at all.
    var hasLightSensor: Bool { get }
    /// Whether the built-in display's brightness can be read on this Mac.
    var hasBuiltInBrightness: Bool { get }
    /// The light in the room, in lux, or nil if it can't be read now.
    func lux() -> Double?
    /// The built-in display's brightness, 0 to 1, or nil if it is off or
    /// can't be read now.
    func builtInBrightness() -> Double?
    /// The lid is closed: the sensor, which sits in it, is covered, and the
    /// built-in display is off.
    func isLidClosed() -> Bool
    func now() -> Date
}

/// The real Mac. Both readers are private APIs, resolved at run time: a
/// macOS without them leaves the feature without those sources instead of
/// failing to launch.
@MainActor
public final class LiveAdaptiveEnvironment: AdaptiveEnvironment {
    private let sensor = AmbientLightSensor.make()
    private let builtIn = BuiltInBrightness.make()

    public init() {}

    public var hasLightSensor: Bool { sensor != nil }
    public var hasBuiltInBrightness: Bool { builtIn != nil }

    public func lux() -> Double? { sensor?.read() }

    public func builtInBrightness() -> Double? {
        guard let builtIn, let display = Self.builtInDisplay() else { return nil }
        return builtIn.read(display)
    }

    public func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        guard root != 0 else { return false }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return state ?? false
    }

    public func now() -> Date { Date() }

    /// The built-in display, while it is online.
    static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// The ambient light sensor, through the private HID event system: the
/// service with primary usage page 0xFF00 and usage 4, read as an event of
/// type 12 (ambient light). Needs no permission (✅ M4 MacBook Air, macOS
/// 26.5).
final class AmbientLightSensor {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private static let ambientLightEvent: Int64 = 12

    private let client: CFTypeRef
    private let service: CFTypeRef
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat

    private init(client: CFTypeRef, service: CFTypeRef, copyEvent: CopyEvent, getFloat: GetFloat) {
        self.client = client
        self.service = service
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    /// nil when a function is missing or the Mac has no such sensor.
    static func make() -> AmbientLightSensor? {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = symbol(iokit, "IOHIDEventSystemClientCreate", CreateClient.self),
              let copyServices = symbol(iokit, "IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol(iokit, "IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol(iokit, "IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = symbol(iokit, "IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            Log.state.notice("no ambient light sensor interface")
            return nil
        }
        let services = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let service = services.first { service in
            func number(_ key: String) -> Int? {
                copyProperty(service, key as CFString)?.takeRetainedValue() as? Int
            }
            return number("PrimaryUsagePage") == 0xFF00 && number("PrimaryUsage") == 4
        }
        guard let service else {
            Log.state.notice("no ambient light sensor on this Mac")
            return nil
        }
        return AmbientLightSensor(client: client, service: service, copyEvent: copyEvent, getFloat: getFloat)
    }

    func read() -> Double? {
        guard let event = copyEvent(service, Self.ambientLightEvent, 0, 0)?.takeRetainedValue() else { return nil }
        let lux = getFloat(event, Int32(Self.ambientLightEvent << 16))
        return lux.isFinite && lux >= 0 ? lux : nil
    }
}

/// The built-in display's brightness, through the private
/// `DisplayServicesGetBrightness`. It already follows macOS's own automatic
/// brightness, which is what "follow the MacBook screen" inherits.
final class BuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let get: GetBrightness

    private init(get: GetBrightness) {
        self.get = get
    }

    static func make() -> BuiltInBrightness? {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = symbol(framework, "DisplayServicesGetBrightness", GetBrightness.self) else {
            Log.state.notice("no DisplayServices brightness interface")
            return nil
        }
        return BuiltInBrightness(get: get)
    }

    func read(_ display: CGDirectDisplayID) -> Double? {
        var brightness: Float = -1
        guard get(display, &brightness) == 0, (0...1).contains(brightness) else { return nil }
        return Double(brightness)
    }
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
    dlsym(handle, name).map { unsafeBitCast($0, to: type) }
}
