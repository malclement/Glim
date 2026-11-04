import CoreAudio
import os
@testable import GlimCore

/// A device behind one control, scripted by the test. Each operation can be
/// held at a gate, so a test can act while it is in flight.
actor ScriptedDevice<Value: Sendable & Equatable> {
    var value: Value
    var range: ClosedRange<Double>?
    /// Writes as they start, in order.
    private(set) var attempts: [Value] = []
    private(set) var reads = 0
    var writeGate: Gate?
    var readGate: Gate?
    var writeError: (any Error)?
    var readError: (any Error)?
    /// What the device stores for a written value, e.g. a clamp.
    var accept: @Sendable (Value) -> Value = { $0 }

    init(value: Value, range: ClosedRange<Double>? = nil) {
        self.value = value
        self.range = range
    }

    func configure(_ change: @Sendable (isolated ScriptedDevice) -> Void) {
        change(self)
    }

    func read() async throws -> DeviceReading<Value> {
        reads += 1
        // The answer is what the device held when the request arrived.
        let snapshot = value
        if let readGate { await readGate.wait() }
        if let readError { throw readError }
        return DeviceReading(value: snapshot, range: range)
    }

    func write(_ newValue: Value) async throws {
        attempts.append(newValue)
        if let writeGate { await writeGate.wait() }
        if let writeError { throw writeError }
        value = accept(newValue)
    }

    nonisolated var backend: ControlBackend<Value> {
        ControlBackend(read: { try await self.read() }, write: { try await self.write($0) })
    }
}

/// An audio output that only remembers what it was told.
actor MockAudioOutput: AudioOutput {
    nonisolated let deviceName: String
    var level: Double
    var muted = false
    private(set) var volumeWrites: [Double] = []

    init(name: String, level: Double = 0.5) {
        self.deviceName = name
        self.level = level
    }

    func volume() throws -> Double { level }

    func setVolume(_ value: Double) throws {
        volumeWrites.append(value)
        level = value
    }

    func isMuted() throws -> Bool { muted }

    func setMuted(_ muted: Bool) throws {
        self.muted = muted
    }
}

/// The system, as far as ``MonitorManager`` can tell: displays to discover,
/// each backed by a simulated display, and audio devices.
final class FakePlatform: MonitorPlatform {
    struct State {
        var available = true
        var displays: [DiscoveredDisplay] = []
        var simulated: [UInt64: SimulatedDisplay] = [:]
        var audio: [AudioDeviceInfo] = []
        var outputs: [AudioObjectID: MockAudioOutput] = [:]
        var onChange: (@MainActor () -> Void)?
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    var isDDCAvailable: Bool { state.withLock(\.available) }

    var controlTiming: ControlTiming { ControlTiming(settleDelay: .zero, operationTimeout: .seconds(5)) }

    /// Connects a display. It appears at the next rescan.
    @discardableResult
    func connect(_ display: DiscoveredDisplay, simulated: SimulatedDisplay = .hp()) -> SimulatedDisplay {
        state.withLock {
            $0.displays.append(display)
            $0.simulated[display.serviceID] = simulated
        }
        return simulated
    }

    func disconnectAll() {
        state.withLock { $0.displays.removeAll() }
    }

    func addAudio(_ device: AudioDeviceInfo) {
        state.withLock { $0.audio.append(device) }
    }

    func output(_ id: AudioObjectID) -> MockAudioOutput? {
        state.withLock { $0.outputs[id] }
    }

    /// What IOKit does when a display comes or goes.
    @MainActor
    func fireChange() {
        state.withLock(\.onChange)?()
    }

    func discoverDisplays() async -> [DiscoveredDisplay] {
        state.withLock(\.displays)
    }

    func makeDevice(for display: DiscoveredDisplay) -> any DDCDevice {
        let simulated = state.withLock { $0.simulated[display.serviceID] } ?? SimulatedDisplay { $0.silent = true }
        return DDCChannel.simulated(simulated)
    }

    func audioOutputs() async -> [AudioDeviceInfo] {
        state.withLock(\.audio)
    }

    func makeAudioOutput(for device: AudioDeviceInfo) -> any AudioOutput {
        state.withLock { state in
            if let existing = state.outputs[device.id] { return existing }
            let output = MockAudioOutput(name: device.name)
            state.outputs[device.id] = output
            return output
        }
    }

    @MainActor
    func observeDisplayChanges(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        state.withLock { $0.onChange = handler }
        return { [state] in state.withLock { $0.onChange = nil } }
    }
}
