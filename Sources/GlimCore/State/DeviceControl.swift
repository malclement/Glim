import Foundation
import Observation
import os

/// A reading from a device: a value and, for levels, the range it lives in.
public struct DeviceReading<Value: Sendable>: Sendable {
    public var value: Value
    public var range: ClosedRange<Double>?

    public init(value: Value, range: ClosedRange<Double>? = nil) {
        self.value = value
        self.range = range
    }
}

/// How a control reads and writes its device.
public struct ControlBackend<Value: Sendable>: Sendable {
    public var read: @Sendable () async throws -> DeviceReading<Value>
    public var write: @Sendable (Value) async throws -> Void
    /// Whether failures say something about the monitor's DDC/CI link (and
    /// so its status), as opposed to a separate device such as its speakers.
    public var reportsLinkStatus: Bool

    public init(read: @escaping @Sendable () async throws -> DeviceReading<Value>,
                write: @escaping @Sendable (Value) async throws -> Void,
                reportsLinkStatus: Bool = true) {
        self.read = read
        self.write = write
        self.reportsLinkStatus = reportsLinkStatus
    }
}

public struct ControlTiming: Sendable, Equatable {
    /// After the last write of a burst, how long to wait before reading the
    /// value back to reconcile what is shown with what the device did.
    public var settleDelay: Duration
    /// The longest a single read or write may take.
    public var operationTimeout: Duration

    public init(settleDelay: Duration = .milliseconds(800), operationTimeout: Duration = .seconds(5)) {
        self.settleDelay = settleDelay
        self.operationTimeout = operationTimeout
    }

    public static let standard = ControlTiming()
}

/// A failure shown next to a control.
public struct ControlFailure: Equatable, Sendable {
    public var message: String
    /// Whether retrying might help.
    public var isTransient: Bool
    /// What the message leaves out, for diagnostics: for example
    /// "readFailed 0xE00002C7". Not shown in the UI.
    public var detail: String?

    init(_ error: any Error) {
        message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        detail = (error as? DDCError)?.technicalDetail ?? String(describing: error)
        switch error {
        case let error as DDCError: isTransient = error.isTransient
        case AudioError.notSupported: isTransient = false
        default: isTransient = true
        }
    }
}

/// One control of a monitor (a slider, a toggle, a choice) and its
/// conversation with the device.
///
/// **What is shown.** ``value`` is what the UI displays. A user change sets
/// it immediately, before the device has seen anything. ``deviceValue`` is
/// the last value actually read from the device.
///
/// **Writes.** At most one write is in flight. While it is, further changes
/// only replace a single pending value, so a fast slider drag produces a
/// short series of writes ending in the final position, never an unbounded
/// queue. A value equal (after ``quantize``) to the last one written is not
/// sent again.
///
/// **Reads.** When writes stop, the value is read back after
/// ``ControlTiming/settleDelay`` so the display reflects what the device
/// accepted. A read only applies if nothing happened since it was issued (no
/// newer change, no pending write, no drag in progress), so a slow reply can
/// never overwrite newer intent.
@MainActor
@Observable
public final class DeviceControl<Value: Sendable & Equatable> {
    /// What the UI shows. nil until the first read succeeds.
    public private(set) var value: Value?
    /// The last value read from the device.
    public private(set) var deviceValue: Value?
    /// The range a level lives in, from the device.
    public private(set) var range: ClosedRange<Double>?
    public private(set) var failure: ControlFailure?
    /// True while the user is dragging.
    public private(set) var isEditing = false
    /// How many changes came from the user (a slider, a picker, a scene), as
    /// opposed to automatic adjustment. Automatic brightness watches it to
    /// know that someone took over.
    @ObservationIgnored public private(set) var userChanges = 0

    @ObservationIgnored private let backend: ControlBackend<Value>
    @ObservationIgnored private let timing: ControlTiming
    @ObservationIgnored private let quantize: @Sendable (Value, ClosedRange<Double>?) -> Value
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Value?
    @ObservationIgnored private var lastWritten: Value?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var reconciler: Task<Void, Never>?
    @ObservationIgnored private var invalidated = false
    /// The last write failed and nothing has succeeded since. The warning
    /// stays up even after a read-back shows the old value, so a rejected
    /// change never vanishes without a word.
    @ObservationIgnored private var lastWriteFailed = false
    /// Tells the owning monitor whether a read reached the device.
    @ObservationIgnored var onLinkOutcome: (@MainActor (Result<Void, any Error>) -> Void)?
    /// Whether a write was sent since the last read-back after writes.
    @ObservationIgnored private var wroteSinceSettled = false
    /// Called once the device has been read back after this control's own
    /// writes, for a control whose writes move another one (the color
    /// temperature and the color preset move together).
    @ObservationIgnored var onSettled: (@MainActor () -> Void)?

    public init(backend: ControlBackend<Value>, timing: ControlTiming = .standard,
                quantize: @escaping @Sendable (Value, ClosedRange<Double>?) -> Value = { value, _ in value }) {
        self.backend = backend
        self.timing = timing
        self.quantize = quantize
    }

    /// Whether a write is in flight or waiting.
    public var isWriting: Bool { writer != nil }

    // MARK: User intent

    /// Applies a change: shown at once, written as soon as the device is
    /// free. Ignored until the device has been read once, because until then
    /// its range, and whether it answers at all, is unknown.
    ///
    /// - Parameter automatic: true for a change Glim makes on its own
    ///   (automatic brightness), which doesn't count in ``userChanges``.
    public func set(_ newValue: Value, automatic: Bool = false) {
        guard !invalidated, value != nil else { return }
        let target = quantize(newValue, range)
        if !automatic { userChanges &+= 1 }
        guard target != value || writer != nil else { return }
        value = target
        generation &+= 1
        reconciler?.cancel()
        reconciler = nil
        pending = target
        if writer == nil {
            writer = Task { [weak self] in await self?.drainWrites() }
        }
    }

    /// Call when a drag starts and ends. Reads are held off during a drag.
    public func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        // Grabbing the slider is taking over, even before it moves.
        if editing { userChanges &+= 1 }
        if !editing, writer == nil { scheduleReconcile() }
    }

    /// Ends a drag the UI can no longer finish, for example because the menu
    /// closed or the slider was removed mid-drag (SwiftUI then never sends the
    /// end of it). Without this, reads would stay held off for good.
    public func endInteraction() {
        setEditing(false)
    }

    // MARK: Device state

    /// Reads the device now, unless a write or a drag is in progress (their
    /// own reconciliation will follow).
    public func refresh() async {
        guard !invalidated, writer == nil, !isEditing else { return }
        await readBack(expecting: generation)
    }

    /// Stops all work. The control is dead afterwards.
    func invalidate() {
        invalidated = true
        pending = nil
        writer?.cancel()
        reconciler?.cancel()
    }

    // MARK: Internals

    private func drainWrites() async {
        while let target = pending, !invalidated {
            pending = nil
            if target == lastWritten { continue }
            // Even a write that seems to fail may have reached the device.
            wroteSinceSettled = true
            do {
                let write = backend.write
                try await withDeadline(timing.operationTimeout) { try await write(target) }
                // A DDC/CI write has no acknowledgement, so success here only
                // means the bus took the frame. Only a read reports the link as
                // healthy.
                lastWritten = target
                lastWriteFailed = false
                failure = nil
            } catch {
                // A dead control's late failure, from a transport that has
                // since been replaced, says nothing about the monitor now.
                guard !invalidated, !(error is CancellationError) else { continue }
                // Shown on this control only. Whether the monitor as a whole
                // answers is for the read-back to tell: a single dropped write
                // must not swap the controls out from under a drag.
                lastWriteFailed = true
                failure = ControlFailure(error)
            }
        }
        writer = nil
        if !isEditing { scheduleReconcile() }
    }

    private func scheduleReconcile() {
        guard !invalidated else { return }
        reconciler?.cancel()
        let expected = generation
        let delay = timing.settleDelay
        reconciler = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.reconcile(expecting: expected)
        }
    }

    private func reconcile(expecting expected: Int) async {
        reconciler = nil
        guard writer == nil, !isEditing else { return }
        await readBack(expecting: expected)
        // Only once nothing newer is under way; the next settle reports it.
        guard !invalidated, wroteSinceSettled, generation == expected, writer == nil, !isEditing else { return }
        wroteSinceSettled = false
        onSettled?()
    }

    private func readBack(expecting expected: Int) async {
        do {
            let read = backend.read
            let reading = try await withDeadline(timing.operationTimeout) { try await read() }
            // Anything the user did while the read was out wins over it.
            guard !invalidated, generation == expected, writer == nil, !isEditing else { return }
            if let range = reading.range { self.range = range }
            deviceValue = reading.value
            value = reading.value
            lastWritten = reading.value
            if !lastWriteFailed { failure = nil }
            if backend.reportsLinkStatus { onLinkOutcome?(.success(())) }
        } catch {
            // Same rule as a successful read: what happened since it was
            // issued wins, and a drag in progress is left alone.
            guard !invalidated, generation == expected, writer == nil, !isEditing,
                  !(error is CancellationError) else { return }
            failure = ControlFailure(error)
            if backend.reportsLinkStatus { onLinkOutcome?(.failure(error)) }
        }
    }
}

// MARK: - Backends

extension ControlBackend where Value == Double {
    /// A continuous VCP code. The range is 0 to the maximum the display
    /// reports with every read.
    public static func vcpLevel(_ code: VCPCode, on device: any DDCDevice) -> ControlBackend<Double> {
        ControlBackend(
            read: {
                let reading = try await device.read(code)
                return DeviceReading(value: Double(reading.current), range: 0...Double(max(reading.maximum, 1)))
            },
            write: { value in
                try await device.write(code, value: UInt16(clamping: Int(value.rounded())))
            }
        )
    }

    /// An audio output's volume, 0 to 1.
    public static func volume(of output: any AudioOutput) -> ControlBackend<Double> {
        ControlBackend(
            read: { DeviceReading(value: try await output.volume(), range: 0...1) },
            write: { try await output.setVolume($0) },
            reportsLinkStatus: false
        )
    }
}

extension ControlBackend where Value == Double {
    /// VCP 0x0C, in steps of the scale's increment. The range starts at 1:
    /// 0 is not a temperature but "the active preset has none".
    ///
    /// While 0x0C reads 0, the first write selects the scale's Kelvin preset
    /// first, so the new temperature lands in a preset that has one whatever
    /// the monitor makes of a lone 0x0C write in sRGB or native.
    public static func colorTemperature(on device: any DDCDevice, scale: ColorTemperatureScale) -> ControlBackend<Double> {
        let withoutTemperature = OSAllocatedUnfairLock(initialState: false)
        return ControlBackend(
            read: {
                let reading = try await device.read(.colorTemperature)
                withoutTemperature.withLock { $0 = reading.current == 0 }
                return DeviceReading(value: Double(reading.current), range: 1...Double(max(reading.maximum, 1)))
            },
            write: { value in
                if let preset = scale.kelvinPreset, withoutTemperature.withLock({ $0 }) {
                    try await device.write(.colorPreset, value: preset)
                    withoutTemperature.withLock { $0 = false }
                }
                try await device.write(.colorTemperature, value: UInt16(clamping: max(1, Int(value.rounded()))))
            }
        )
    }
}

extension ControlBackend where Value == ColorPresetValue {
    /// VCP 0x14, translated through the monitor's preset table. Reads 0x0C
    /// too when the table needs it to tell presets apart.
    public static func colorPreset(on device: any DDCDevice, presets: ColorPresets) -> ControlBackend<ColorPresetValue> {
        ControlBackend(
            read: {
                let reading = try await device.read(.colorPreset).current & 0xFF
                let temperature = presets.readsTemperature ? try await device.read(.colorTemperature).current : nil
                return DeviceReading(value: presets.value(reading: reading, temperature: temperature))
            },
            write: { value in
                // Only offered presets are ever picked; anything else is
                // what was read, and there is nothing to send.
                guard case .preset(let raw) = value else { return }
                try await device.write(.colorPreset, value: raw)
            }
        )
    }
}

extension ControlBackend where Value == Bool {
    /// VCP 0x8D: 1 mutes, 2 unmutes, in the low byte (MCCS uses the high
    /// byte for screen blanking).
    public static func vcpMute(on device: any DDCDevice) -> ControlBackend<Bool> {
        ControlBackend(
            read: { DeviceReading(value: try await device.read(.audioMute).current & 0xFF == 1) },
            write: { try await device.write(.audioMute, value: $0 ? 1 : 2) }
        )
    }

    public static func mute(of output: any AudioOutput) -> ControlBackend<Bool> {
        ControlBackend(
            read: { DeviceReading(value: try await output.isMuted()) },
            write: { try await output.setMuted($0) },
            reportsLinkStatus: false
        )
    }
}

extension ControlBackend where Value == UInt16 {
    /// A non-continuous VCP code, such as the input source. MCCS puts its
    /// value in the low byte; some displays use the high byte for something
    /// else, so it is ignored.
    public static func vcpChoice(_ code: VCPCode, on device: any DDCDevice) -> ControlBackend<UInt16> {
        ControlBackend(
            read: { DeviceReading(value: try await device.read(code).current & 0xFF) },
            write: { try await device.write(code, value: $0) }
        )
    }
}

/// Rounds a level to whole device steps and keeps it in range.
@Sendable
public func quantizeToSteps(_ value: Double, in range: ClosedRange<Double>?) -> Double {
    let rounded = value.rounded()
    guard let range else { return rounded }
    return min(max(rounded, range.lowerBound), range.upperBound)
}

/// Rounds a 0–1 level to hundredths, so a drag sends at most 100 distinct
/// values.
@Sendable
public func quantizeToPercent(_ value: Double, in range: ClosedRange<Double>?) -> Double {
    min(max((value * 100).rounded() / 100, range?.lowerBound ?? 0), range?.upperBound ?? 1)
}
