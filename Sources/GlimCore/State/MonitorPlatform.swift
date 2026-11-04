/// Everything ``MonitorManager`` needs from the system, so the manager can be
/// tested without a monitor.
public protocol MonitorPlatform: Sendable {
    /// Whether DDC/CI can work at all on this Mac.
    var isDDCAvailable: Bool { get }
    var controlTiming: ControlTiming { get }
    func discoverDisplays() async -> [DiscoveredDisplay]
    func makeDevice(for display: DiscoveredDisplay) -> any DDCDevice
    func audioOutputs() async -> [AudioDeviceInfo]
    func makeAudioOutput(for device: AudioDeviceInfo) -> any AudioOutput
    /// Calls `handler` when displays may have been connected or disconnected.
    /// Returns a function that stops observing.
    @MainActor
    func observeDisplayChanges(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

/// The real system: IOKit, IOAVService and CoreAudio.
public struct LivePlatform: MonitorPlatform {
    public init() {}

    public var isDDCAvailable: Bool { IOAVServiceAPI.shared != nil }

    public var controlTiming: ControlTiming { .standard }

    /// Reads the IORegistry. Being `nonisolated async`, it runs on the
    /// global executor, never on the caller's (main) actor.
    public func discoverDisplays() async -> [DiscoveredDisplay] {
        DisplayRegistry.externalDisplays()
    }

    public func makeDevice(for display: DiscoveredDisplay) -> any DDCDevice {
        let serviceID = display.serviceID
        return DDCChannel(label: display.framebuffer ?? "display-\(serviceID)") { () throws(DDCError) -> any DDCBus in
            try IOAVServiceBus(registryEntryID: serviceID)
        }
    }

    public func audioOutputs() async -> [AudioDeviceInfo] {
        AudioDevices.outputs()
    }

    public func makeAudioOutput(for device: AudioDeviceInfo) -> any AudioOutput {
        CoreAudioOutput(device: device)
    }

    @MainActor
    public func observeDisplayChanges(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let notifier = DisplayServiceNotifier(onChange: handler)
        notifier.start()
        return { notifier.stop() }
    }
}
