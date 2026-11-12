import Darwin
import IOKit

/// Whether one of the private IOKit functions was found.
public struct SymbolStatus: Equatable, Sendable {
    public var name: String
    public var resolved: Bool
    public init(name: String, resolved: Bool) {
        self.name = name
        self.resolved = resolved
    }
}

/// The private IOKit functions behind DDC/CI on Apple silicon:
/// `IOAVServiceCreateWithService`, `IOAVServiceReadI2C` and
/// `IOAVServiceWriteI2C`. m1ddc, MonitorControl and BetterDisplay use the same
/// three.
///
/// They are looked up at run time instead of linked, so a macOS release that
/// removes them makes DDC unavailable, with a message, instead of keeping the
/// app from launching.
struct IOAVServiceAPI: Sendable {
    // IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
    typealias Create = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    // IOReturn IOAVService{Read,Write}I2C(IOAVServiceRef, uint32_t chip, uint32_t dataAddress, void *buffer, uint32_t length);
    typealias Transfer = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    let create: Create
    let readI2C: Transfer
    let writeI2C: Transfer

    /// nil when the functions are missing.
    static let shared: IOAVServiceAPI? = load()

    static let symbolNames = ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C"]

    /// Which of the three functions IOKit provides, for diagnostics. Logs
    /// nothing.
    static func symbolResolution() -> [SymbolStatus] {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        return symbolNames.map { name in
            SymbolStatus(name: name, resolved: handle.flatMap { dlsym($0, name) } != nil)
        }
    }

    private static func load() -> IOAVServiceAPI? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            Log.ddc.fault("IOKit could not be loaded")
            return nil
        }
        // The handle is kept open for the life of the process, like IOKit itself.
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else {
            Log.ddc.fault("IOAVService functions are missing from IOKit")
            return nil
        }
        return IOAVServiceAPI(
            create: unsafeBitCast(create, to: Create.self),
            readI2C: unsafeBitCast(read, to: Transfer.self),
            writeI2C: unsafeBitCast(write, to: Transfer.self)
        )
    }
}

/// A ``DDCBus`` over one display's IOAVService.
final class IOAVServiceBus: DDCBus {
    private let api: IOAVServiceAPI
    /// The IOAVService, a CoreFoundation object. ARC releases it.
    private let service: AnyObject

    /// Opens the IOAVService of the `DCPAVServiceProxy` registry entry with
    /// this ID.
    init(registryEntryID: UInt64) throws(DDCError) {
        guard let api = IOAVServiceAPI.shared else { throw .transportUnavailable }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard entry != IO_OBJECT_NULL else { throw .serviceUnavailable }
        defer { IOObjectRelease(entry) }
        guard let created = api.create(nil, entry) else { throw .serviceUnavailable }
        // A Create function returns a +1 reference.
        self.service = Unmanaged<AnyObject>.fromOpaque(created).takeRetainedValue()
        self.api = api
    }

    func write(_ frame: [UInt8]) throws(DDCError) {
        var buffer = frame
        let result = transfer(api.writeI2C, &buffer)
        guard result == KERN_SUCCESS else { throw .writeFailed(result) }
    }

    func read(length: Int) throws(DDCError) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        let result = transfer(api.readI2C, &buffer)
        guard result == KERN_SUCCESS else { throw .readFailed(result) }
        return buffer
    }

    private func transfer(_ function: IOAVServiceAPI.Transfer, _ buffer: inout [UInt8]) -> IOReturn {
        let serviceRef = Unmanaged.passUnretained(service).toOpaque()
        return buffer.withUnsafeMutableBytes { bytes -> IOReturn in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return Self.badArgument }
            return function(serviceRef, DDC.chipAddress, DDC.hostSubAddress, base, UInt32(bytes.count))
        }
    }

    /// kIOReturnBadArgument, which Swift does not import (it is built by a
    /// function-like macro).
    private static let badArgument = IOReturn(bitPattern: 0xE000_02C2)
}
