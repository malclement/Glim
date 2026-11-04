import IOKit

/// Calls back on the main actor whenever a `DCPAVServiceProxy` (a display's
/// DDC/CI transport) appears or goes away, which is what plugging or
/// unplugging a display does.
@MainActor
final class DisplayServiceNotifier {
    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// Registers for notifications. The notifier must stay alive, and be
    /// stopped with ``stop()``, while registered: IOKit holds an unretained
    /// pointer to it.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        // Callbacks arrive on the main queue, which is what lets the callback
        // below assume main-actor isolation.
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, kind, IOServiceMatching("DCPAVServiceProxy"), serviceChanged, context, &iterator
            )
            guard result == KERN_SUCCESS else {
                Log.discovery.error("IOServiceAddMatchingNotification failed: \(result)")
                continue
            }
            // A notification is armed only once its iterator has been drained.
            drain(iterator)
            iterators.append(iterator)
        }
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    fileprivate func fire() {
        onChange()
    }
}

private func serviceChanged(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    drain(iterator)
    // The pointer crosses into the main actor as a plain integer: the notifier
    // it points to is main-actor isolated and is only dereferenced there.
    guard let address = context.map({ UInt(bitPattern: $0) }) else { return }
    MainActor.assumeIsolated {
        guard let context = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<DisplayServiceNotifier>.fromOpaque(context).takeUnretainedValue().fire()
    }
}

private func drain(_ iterator: io_iterator_t) {
    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
        IOObjectRelease(entry)
    }
}
