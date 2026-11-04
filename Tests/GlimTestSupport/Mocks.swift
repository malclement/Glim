import CoreAudio
import os
import GlimCore

/// A device behind one control, scripted by the test. Each operation can be
/// held at a gate, so a test can act while it is in flight.
package actor ScriptedDevice<Value: Sendable & Equatable> {
    package var value: Value
    package var range: ClosedRange<Double>?
    /// Writes as they start, in order.
    package private(set) var attempts: [Value] = []
    package private(set) var reads = 0
    package var writeGate: Gate?
    package var readGate: Gate?
    package var writeError: (any Error)?
    package var readError: (any Error)?
    /// What the device stores for a written value, e.g. a clamp.
    package var accept: @Sendable (Value) -> Value = { $0 }

    package init(value: Value, range: ClosedRange<Double>? = nil) {
        self.value = value
        self.range = range
    }

    package func configure(_ change: @Sendable (isolated ScriptedDevice) -> Void) {
        change(self)
    }

    package func read() async throws -> DeviceReading<Value> {
        reads += 1
        // The answer is what the device held when the request arrived.
        let snapshot = value
        if let readGate { await readGate.wait() }
        if let readError { throw readError }
        return DeviceReading(value: snapshot, range: range)
    }

    package func write(_ newValue: Value) async throws {
        attempts.append(newValue)
        if let writeGate { await writeGate.wait() }
        if let writeError { throw writeError }
        value = accept(newValue)
    }

    package nonisolated var backend: ControlBackend<Value> {
        ControlBackend(read: { try await self.read() }, write: { try await self.write($0) })
    }
}

/// An audio output that only remembers what it was told.
package actor MockAudioOutput: AudioOutput {
    package nonisolated let deviceName: String
    package var level: Double
    package var muted = false
    package private(set) var volumeWrites: [Double] = []

    package init(name: String, level: Double = 0.5) {
        self.deviceName = name
        self.level = level
    }

    package func volume() throws -> Double { level }

    package func setVolume(_ value: Double) throws {
        volumeWrites.append(value)
        level = value
    }

    package func isMuted() throws -> Bool { muted }

    package func setMuted(_ muted: Bool) throws {
        self.muted = muted
    }
}

/// The system, as far as ``MonitorManager`` can tell: displays to discover,
/// each backed by a simulated display, and audio devices.
package final class FakePlatform: MonitorPlatform {
    package struct State {
        package var available = true
        package var displays: [DiscoveredDisplay] = []
        package var simulated: [UInt64: SimulatedDisplay] = [:]
        package var audio: [AudioDeviceInfo] = []
        package var outputs: [AudioObjectID: MockAudioOutput] = [:]
        package var onChange: (@MainActor () -> Void)?
        /// Devices to use instead of a simulated display, by service ID.
        package var devices: [UInt64: any DDCDevice] = [:]
        package var discoveries = 0
        package var devicesMade = 0
    }

    package let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package var isDDCAvailable: Bool { state.withLock(\.available) }

    package var controlTiming: ControlTiming { ControlTiming(settleDelay: .zero, operationTimeout: .seconds(5)) }

    /// Connects a display. It appears at the next rescan.
    @discardableResult
    package func connect(_ display: DiscoveredDisplay, simulated: SimulatedDisplay = .hp()) -> SimulatedDisplay {
        state.withLock {
            $0.displays.append(display)
            $0.simulated[display.serviceID] = simulated
        }
        return simulated
    }

    package func disconnectAll() {
        state.withLock { $0.displays.removeAll() }
    }

    package func addAudio(_ device: AudioDeviceInfo) {
        state.withLock { $0.audio.append(device) }
    }

    package func output(_ id: AudioObjectID) -> MockAudioOutput? {
        state.withLock { $0.outputs[id] }
    }

    /// What IOKit does when a display comes or goes.
    @MainActor
    package func fireChange() {
        state.withLock(\.onChange)?()
    }

    package func discoverDisplays() async -> [DiscoveredDisplay] {
        state.withLock { state in
            state.discoveries += 1
            return state.displays
        }
    }

    package func makeDevice(for display: DiscoveredDisplay) -> any DDCDevice {
        state.withLock { $0.devicesMade += 1 }
        if let device = state.withLock({ $0.devices[display.serviceID] }) { return device }
        let simulated = state.withLock { $0.simulated[display.serviceID] } ?? SimulatedDisplay { $0.silent = true }
        return DDCChannel.simulated(simulated)
    }

    package func audioOutputs() async -> [AudioDeviceInfo] {
        state.withLock(\.audio)
    }

    package func makeAudioOutput(for device: AudioDeviceInfo) -> any AudioOutput {
        state.withLock { state in
            if let existing = state.outputs[device.id] { return existing }
            let output = MockAudioOutput(name: device.name)
            state.outputs[device.id] = output
            return output
        }
    }

    @MainActor
    package func observeDisplayChanges(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        state.withLock { $0.onChange = handler }
        return { [state] in state.withLock { $0.onChange = nil } }
    }
}

/// A display that never answers until its gate opens: an operation in
/// flight, frozen.
package actor StuckDevice: DDCDevice {
    private let gate: Gate

    package init(gate: Gate = Gate()) {
        self.gate = gate
    }

    package func read(_ code: VCPCode) async throws -> VCPReading {
        await gate.wait()
        throw DDCError.noReply
    }

    package func write(_ code: VCPCode, value: UInt16) async throws {
        await gate.wait()
    }

    package func capabilitiesFragment(at offset: UInt16) async throws -> [UInt8] {
        await gate.wait()
        return []
    }
}

package enum TestIdentity {
    /// The HP E27m G4 as macOS describes it, with a made-up serial.
    package static let hp = DisplayIdentity(
        vendorID: 0x220E, productID: 0x3753, serialNumber: 0x0101_0101,
        alphanumericSerial: "TEST0000001", productName: "HP E27m G4"
    )
}
