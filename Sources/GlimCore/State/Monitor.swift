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
    /// In 0x0C steps; ``MonitorProfile/colorTemperature`` turns them into
    /// kelvin.
    public private(set) var colorTemperature: DeviceControl<Double>?
    public private(set) var colorPreset: ColorPresetSelector?
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
    /// Set when a monitor without a profile has no capabilities string yet,
    /// so it is set up again, up to ``maxCapabilityAttempts`` times, the next
    /// time it answers.
    @ObservationIgnored private var needsReconfiguration = false
    @ObservationIgnored private var capabilityAttempts = 0
    /// 0x0B, needed for a temperature in kelvin, did not answer.
    @ObservationIgnored private var temperatureIncrementMissed = false
    private static let maxCapabilityAttempts = 3
    /// Whether ``volume`` and ``mute`` go over DDC/CI (rebuilt with the other
    /// DDC controls) rather than to a USB Audio device (attached separately).
    @ObservationIgnored private var volumeIsDDC = false

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
    /// sleep. Its DDC controls are removed at once, so none that is dead
    /// stays on screen, and rebuilt on the new channel. USB speakers are a
    /// separate device and stay.
    func reconnect(to display: DiscoveredDisplay, device: any DDCDevice) {
        Log.state.info("\(self.name, privacy: .public) reconnected")
        removeDDCControls()
        self.display = display
        self.device = device
        capabilitiesString = nil
        needsReconfiguration = false
        capabilityAttempts = 0
        temperatureIncrementMissed = false
        status = .connecting
        start()
    }

    /// The monitor is gone. Stops every task; the object is dead afterwards.
    func invalidate() {
        invalidated = true
        configuration?.cancel()
        removeDDCControls()
        volume?.invalidate()
        mute?.invalidate()
    }

    private func removeDDCControls() {
        brightness?.invalidate()
        contrast?.invalidate()
        colorTemperature?.invalidate()
        colorPreset?.control.invalidate()
        input?.control.invalidate()
        brightness = nil
        contrast = nil
        colorTemperature = nil
        colorPreset = nil
        input = nil
        if volumeIsDDC {
            volume?.invalidate()
            mute?.invalidate()
            volume = nil
            mute = nil
            volumeIsDDC = false
        }
    }

    /// Ends whatever the user left half done when the menu closed: a drag
    /// SwiftUI will never finish, or an input switch never confirmed.
    public func endInteractions() {
        brightness?.endInteraction()
        contrast?.endInteraction()
        colorTemperature?.endInteraction()
        volume?.endInteraction()
        input?.cancel()
    }

    private func configure() async {
        if let known = MonitorProfile.known(for: identity) {
            profile = known
            buildDDCControls(capabilities: nil)
        } else {
            // No profile: ask the monitor what it has.
            // A string that parses to no VCP list says nothing about the
            // monitor; treat it as absent rather than as "offers nothing".
            let capabilities = await readCapabilities().flatMap { $0.vcp.isEmpty ? nil : $0 }
            guard !invalidated, !Task.isCancelled else { return }
            var increment: UInt16?
            if capabilities?.lists(.colorTemperature) == true {
                let reading = await readTemperatureIncrement()
                increment = reading.value
                // A read lost on a busy bus must not cost the temperature for
                // the whole session: set up again, as for the capabilities.
                temperatureIncrementMissed = reading.missed
            }
            guard !invalidated, !Task.isCancelled else { return }
            profile = .generic(capabilities: capabilities, temperatureIncrement: increment)
            if identity?.productName == nil, let model = capabilities?.model, !model.isEmpty { name = model }
            buildDDCControls(capabilities: capabilities)
        }
        await readAll()
        dropUnsupportedControls()
        guard !invalidated, !Task.isCancelled else { return }
        if status == .connecting {
            // Nothing was left to read. A monitor that sent its capabilities
            // is reachable; one that sent nothing is not.
            status = capabilitiesString != nil ? .ready : .notResponding
        }
        // Read the capabilities again later if they did not come through,
        // whether the monitor was silent or just would not send them, but
        // not forever: some monitors never do.
        needsReconfiguration = profile.isGeneric && (capabilitiesString == nil || temperatureIncrementMissed)
            && capabilityAttempts < Self.maxCapabilityAttempts
    }

    /// Whether any control is offered.
    public var hasControls: Bool {
        brightness != nil || contrast != nil || colorTemperature != nil || colorPreset != nil
            || volume != nil || mute != nil || input != nil
    }

    /// 0x0B, which a temperature in kelvin needs. `missed` when the read
    /// failed in a way a later attempt may not (no reply, a timeout), as
    /// opposed to the monitor saying it has no such code.
    private func readTemperatureIncrement() async -> (value: UInt16?, missed: Bool) {
        let device = self.device
        do {
            let value = try await withDeadline(timing.operationTimeout) {
                try await device.read(.colorTemperatureIncrement).current
            }
            return (value, false)
        } catch {
            Log.state.notice("\(self.name, privacy: .public): no color temperature increment: \(String(describing: error), privacy: .public)")
            return (nil, (error as? DDCError)?.isTransient ?? true)
        }
    }

    private func readCapabilities() async -> MonitorCapabilities? {
        capabilityAttempts += 1
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
        // Whatever this replaces must stop, or it keeps writing to the device
        // behind the controls on screen.
        removeDDCControls()
        let device = self.device
        brightness = profile.brightness ? makeControl(.vcpLevel(.brightness, on: device), quantize: quantizeToSteps) : nil
        contrast = profile.contrast ? makeControl(.vcpLevel(.contrast, on: device), quantize: quantizeToSteps) : nil
        buildColorControls()
        if profile.volume == .ddc {
            volume = makeControl(.vcpLevel(.audioVolume, on: device), quantize: quantizeToSteps)
            mute = capabilities?.lists(.audioMute) == true ? makeControl(.vcpMute(on: device)) : nil
            volumeIsDDC = true
        }
        input = profile.inputs.map { options in
            // A switch takes a moment, and the monitor may stop answering
            // during it, so its read-back waits longer.
            let timing = ControlTiming(settleDelay: .seconds(2), operationTimeout: self.timing.operationTimeout)
            return InputSelector(options: options, control: makeControl(.vcpChoice(.inputSource, on: device), timing: timing))
        }
    }

    /// The temperature and the preset move together on the monitor: setting
    /// one changes what the other reads. So once either has settled after a
    /// write, the other is read again.
    private func buildColorControls() {
        let device = self.device
        let temperature = profile.colorTemperature.map { scale in
            makeControl(.colorTemperature(on: device, scale: scale), quantize: quantizeToSteps)
        }
        let preset = profile.colorPresets.map { presets in
            // Never longer than the settle delay, which tests shorten.
            let verifyDelay = min(timing.settleDelay, .milliseconds(300))
            return ColorPresetSelector(presets: presets,
                                       control: makeControl(.colorPreset(on: device, presets: presets, verifyDelay: verifyDelay)))
        }
        temperature?.onSettled = { [weak preset] in
            Task { await preset?.refresh() }
        }
        preset?.control.onSettled = { [weak temperature] in
            Task { await temperature?.refresh() }
        }
        colorTemperature = temperature
        colorPreset = preset
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
        if unsupported(colorTemperature) { colorTemperature?.invalidate(); colorTemperature = nil }
        if unsupported(colorPreset?.control) { colorPreset?.control.invalidate(); colorPreset = nil }
        if unsupported(input?.control) { input?.control.invalidate(); input = nil }
        // USB mute that the device lacks is just as unsupported.
        if unsupported(volume) { volume?.invalidate(); volume = nil }
        if unsupported(mute) { mute?.invalidate(); mute = nil }
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
        guard case .usbAudio = profile.volume, !volumeIsDDC, !invalidated, info?.id != audioDeviceID else { return }
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
        Task { [weak self] in
            await volume.refresh()
            await mute.refresh()
            self?.dropUnsupportedControls()
        }
    }

    // MARK: Refresh

    /// Reads every control again. A monitor without a profile that was
    /// silent when it was set up, and now answers, is set up again so that
    /// its capabilities get read.
    public func refresh() async {
        guard !invalidated else { return }
        await readAll()
        if needsReconfiguration, status == .ready {
            needsReconfiguration = false
            start()
        }
    }

    private func readAll() async {
        lastRefresh = .now
        // USB speakers are their own device: read them whatever DDC does.
        if !volumeIsDDC {
            await volume?.refresh()
            await mute?.refresh()
        }
        if let brightness {
            await brightness.refresh()
            // If the monitor did not answer the first read, the others
            // would only spend their retries finding the same thing.
            if status == .notResponding, brightness.failure != nil { return }
        }
        await contrast?.refresh()
        await colorTemperature?.refresh()
        await colorPreset?.refresh()
        await input?.control.refresh()
        if volumeIsDDC {
            await volume?.refresh()
            await mute?.refresh()
        }
    }

    /// Whether the volume controls drive a USB device, which keeps working
    /// when DDC/CI does not.
    public var hasUSBSpeakers: Bool { !volumeIsDDC && volume != nil }

    /// Reads every control again unless that happened in the last `maxAge`.
    func refreshIfStale(maxAge: Duration = .seconds(2)) async {
        if let lastRefresh, lastRefresh.duration(to: .now) < maxAge { return }
        await refresh()
    }
}
