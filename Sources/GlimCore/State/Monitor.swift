import CoreAudio
import Foundation
import Observation

/// One connected monitor and its controls.
///
/// The controls present are the ones its profile offers and that answered a
/// read. A control that is nil is not offered.
@MainActor
@Observable
public final class Monitor: Identifiable {
    public enum Status: Equatable, Sendable {
        /// Reading the monitor for the first time.
        case connecting
        case ready
        /// DDC/CI reads fail. The monitor may be asleep, showing another
        /// input, or have DDC/CI turned off.
        case notResponding
    }

    /// Stable across reconnects: built from the EDID manufacturer, product and
    /// serial.
    public nonisolated let id: String
    public private(set) var name: String
    public private(set) var identity: DisplayIdentity?
    public private(set) var profile: MonitorProfile
    public private(set) var status: Status = .connecting

    public private(set) var brightness: DeviceControl<Double>?
    public private(set) var contrast: DeviceControl<Double>?
    public private(set) var volume: DeviceControl<Double>?
    public private(set) var mute: DeviceControl<Bool>?
    public private(set) var input: InputSelector?

    /// The raw capabilities string, read only for monitors without a profile.
    public private(set) var capabilitiesString: String?
    /// The audio device the volume controls drive, when it is a USB device.
    public private(set) var audioDeviceName: String?

    @ObservationIgnored private(set) var display: DiscoveredDisplay
    @ObservationIgnored private var device: any DDCDevice
    @ObservationIgnored private let timing: ControlTiming
    @ObservationIgnored private var configuration: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var audioDeviceID: AudioObjectID?
    @ObservationIgnored private var invalidated = false
    /// Set when a monitor without a profile was silent while being set up,
    /// so its capabilities are read again once it answers.
    @ObservationIgnored private var needsReconfiguration = false

    init(id: String, display: DiscoveredDisplay, device: any DDCDevice, timing: ControlTiming) {
        self.id = id
        self.display = display
        self.device = device
        self.timing = timing
        self.identity = display.identity
        self.name = display.identity?.productName ?? "External Display"
        self.profile = MonitorProfile.known(for: display.identity) ?? .generic(capabilities: nil)
    }

    // MARK: Lifecycle

    /// Builds the controls and reads them for the first time.
    func start() {
        configuration?.cancel()
        configuration = Task { [weak self] in await self?.configure() }
    }

    /// The same monitor came back with a new transport, after a replug or a
    /// sleep. Controls are rebuilt on the new channel.
    func reconnect(to display: DiscoveredDisplay, device: any DDCDevice) {
        Log.state.info("\(self.name, privacy: .public) reconnected")
        invalidateDDCControls()
        self.display = display
        self.device = device
        status = .connecting
        start()
    }

    /// The monitor is gone. Stops every task; the object is dead afterwards.
    func invalidate() {
        invalidated = true
        configuration?.cancel()
        invalidateDDCControls()
        volume?.invalidate()
        mute?.invalidate()
    }

    private func invalidateDDCControls() {
        brightness?.invalidate()
        contrast?.invalidate()
        input?.control.invalidate()
        if profile.volume == .ddc {
            volume?.invalidate()
            mute?.invalidate()
        }
    }

    private func configure() async {
        if let known = MonitorProfile.known(for: identity) {
            profile = known
            buildDDCControls(capabilities: nil)
        } else {
            // No profile: ask the monitor what it has.
            let capabilities = await readCapabilities()
            guard !invalidated, !Task.isCancelled else { return }
            profile = .generic(capabilities: capabilities)
            if identity?.productName == nil, let model = capabilities?.model, !model.isEmpty { name = model }
            buildDDCControls(capabilities: capabilities)
        }
        await refresh()
        dropUnsupportedControls()
        needsReconfiguration = profile.isGeneric && capabilitiesString == nil && status != .ready
    }

    private func readCapabilities() async -> MonitorCapabilities? {
        let device = self.device
        do {
            let raw = try await withDeadline(.seconds(20)) { try await GlimCore.readCapabilities(from: device) }
            capabilitiesString = raw
            return MonitorCapabilities(parsing: raw)
        } catch {
            Log.state.error("\(self.name, privacy: .public): no capabilities string: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func buildDDCControls(capabilities: MonitorCapabilities?) {
        let device = self.device
        brightness = profile.brightness ? makeControl(.vcpLevel(.brightness, on: device), quantize: quantizeToSteps) : nil
        contrast = profile.contrast ? makeControl(.vcpLevel(.contrast, on: device), quantize: quantizeToSteps) : nil
        if profile.volume == .ddc {
            volume = makeControl(.vcpLevel(.audioVolume, on: device), quantize: quantizeToSteps)
            mute = capabilities?.lists(.audioMute) == true ? makeControl(.vcpMute(on: device)) : nil
        }
        input = profile.inputs.map { options in
            // A switch takes a moment, and the monitor may stop answering
            // during it, so its read-back waits longer.
            let timing = ControlTiming(settleDelay: .seconds(2), operationTimeout: self.timing.operationTimeout)
            return InputSelector(options: options, control: makeControl(.vcpChoice(.inputSource, on: device), timing: timing))
        }
    }

    private func makeControl<Value>(
        _ backend: ControlBackend<Value>,
        timing: ControlTiming? = nil,
        quantize: @escaping @Sendable (Value, ClosedRange<Double>?) -> Value = { value, _ in value }
    ) -> DeviceControl<Value> {
        let control = DeviceControl(backend: backend, timing: timing ?? self.timing, quantize: quantize)
        control.onLinkOutcome = { [weak self] outcome in self?.record(outcome) }
        return control
    }

    /// A control the monitor reports as unsupported is not shown.
    private func dropUnsupportedControls() {
        func unsupported<Value>(_ control: DeviceControl<Value>?) -> Bool {
            control?.failure.map { !$0.isTransient } ?? false
        }
        if unsupported(brightness) { brightness?.invalidate(); brightness = nil }
        if unsupported(contrast) { contrast?.invalidate(); contrast = nil }
        if unsupported(input?.control) { input?.control.invalidate(); input = nil }
        if profile.volume == .ddc {
            if unsupported(volume) { volume?.invalidate(); volume = nil }
            if unsupported(mute) { mute?.invalidate(); mute = nil }
        }
    }

    private func record(_ outcome: Result<Void, any Error>) {
        switch outcome {
        case .success:
            status = .ready
        case .failure(let error):
            // "Unsupported code" proves the link works.
            if let error = error as? DDCError, !error.isTransient {
                status = .ready
            } else {
                status = .notResponding
            }
        }
    }

    // MARK: Audio

    /// Points the volume controls at the monitor's USB Audio device, or
    /// removes them (nil).
    func attachAudio(_ info: AudioDeviceInfo?, make: (AudioDeviceInfo) -> any AudioOutput) {
        guard case .usbAudio = profile.volume, !invalidated, info?.id != audioDeviceID else { return }
        volume?.invalidate()
        mute?.invalidate()
        audioDeviceID = info?.id
        audioDeviceName = info?.name
        guard let info else {
            Log.audio.info("\(self.name, privacy: .public): no USB audio device")
            volume = nil
            mute = nil
            return
        }
        Log.audio.info("\(self.name, privacy: .public): volume on \(info.name, privacy: .public)")
        let output = make(info)
        let volume = makeControl(.volume(of: output), quantize: quantizeToPercent)
        let mute = makeControl(.mute(of: output))
        self.volume = volume
        self.mute = mute
        Task {
            await volume.refresh()
            await mute.refresh()
        }
    }

    // MARK: Refresh

    /// Reads every control again.
    public func refresh() async {
        guard !invalidated else { return }
        lastRefresh = .now
        defer {
            if needsReconfiguration, status == .ready {
                needsReconfiguration = false
                start()
            }
        }
        if let brightness {
            await brightness.refresh()
            // If the monitor did not answer the first read, the others
            // would only spend their retries finding the same thing.
            if status == .notResponding, brightness.failure != nil { return }
        }
        await contrast?.refresh()
        await input?.control.refresh()
        await volume?.refresh()
        await mute?.refresh()
    }

    /// Reads every control again unless that happened in the last `maxAge`.
    func refreshIfStale(maxAge: Duration = .seconds(2)) async {
        if let lastRefresh, lastRefresh.duration(to: .now) < maxAge { return }
        await refresh()
    }
}
