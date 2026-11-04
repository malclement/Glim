@testable import GlimCore
import GlimTestSupport
import Testing

/// How a control turns user intent into device writes, and device reads
/// into what is shown.
@Suite @MainActor struct DeviceControlTests {
    private func level(_ device: ScriptedDevice<Double>, settle: Duration = .zero,
                       timeout: Duration = .seconds(5)) -> DeviceControl<Double> {
        DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: settle, operationTimeout: timeout),
                      quantize: quantizeToSteps)
    }

    private func idle(_ control: DeviceControl<Double>) async -> Bool {
        await eventually { !control.isWriting }
    }

    @Test func firstRefreshShowsTheDeviceValue() async {
        let device = ScriptedDevice(value: 80.0, range: 0...100)
        let control = level(device)
        #expect(control.value == nil)
        await control.refresh()
        #expect(control.value == 80)
        #expect(control.deviceValue == 80)
        #expect(control.range == 0...100)
        #expect(control.failure == nil)
    }

    @Test func changesBeforeTheFirstReadAreIgnored() async {
        let device = ScriptedDevice(value: 80.0, range: 0...100)
        let control = level(device)
        control.set(10)
        await settle()
        #expect(await device.attempts.isEmpty)
        #expect(control.value == nil)
    }

    @Test func aChangeIsShownBeforeTheDeviceHasIt() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 80.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.writeGate = gate }
        control.set(30)
        #expect(control.value == 30)
        #expect(control.deviceValue == 80)
        await gate.open()
    }

    /// A drag: the first value goes out at once, everything after it while
    /// the device is busy collapses into the last one.
    @Test func rapidChangesCoalesceToTheLatest() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.writeGate = gate }

        control.set(51)
        #expect(await eventually { await device.attempts == [51] })
        for value in 52...99 { control.set(Double(value)) }
        #expect(control.value == 99)

        await gate.open()
        #expect(await idle(control))
        #expect(await device.attempts == [51, 99])
        #expect(await eventually { control.deviceValue == 99 })
    }

    @Test func valuesAreQuantizedAndClamped() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        control.set(150.7)
        #expect(control.value == 100)
        control.set(-4)
        #expect(control.value == 0)
        #expect(await idle(control))
        #expect(await device.attempts.last == 0)
    }

    @Test func anUnchangedValueIsNotWrittenAgain() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        control.set(50.3)          // rounds to what the device already has
        await settle()
        #expect(await device.attempts.isEmpty)
        control.set(60)
        #expect(await idle(control))
        control.set(60.2)
        await settle()
        #expect(await device.attempts == [60])
    }

    /// A reply that was already on its way when the user moved the slider
    /// must not move it back.
    @Test func aStaleReadDoesNotOverwriteNewerIntent() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device, settle: .seconds(60))
        await control.refresh()
        await device.configure { $0.readGate = gate }

        let read = Task { await control.refresh() }
        #expect(await eventually { await gate.waiting == 1 })
        control.set(70)
        #expect(await eventually { await device.attempts == [70] })
        await gate.release()       // the read answers with the old 50
        await read.value
        #expect(control.value == 70)
        await gate.open()
    }

    /// After a burst of writes the control reads back, so it ends up showing
    /// what the device accepted.
    @Test func readBackReconcilesWithWhatTheDeviceAccepted() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        await device.configure { $0.accept = { min($0, 80) } }
        let control = level(device)
        await control.refresh()
        control.set(95)
        #expect(control.value == 95)
        #expect(await eventually { control.value == 80 })
        #expect(control.deviceValue == 80)
    }

    @Test func noReadBackWhileDragging() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        control.setEditing(true)
        control.set(60)
        #expect(await idle(control))
        await settle()
        #expect(await device.reads == 1)
        await control.refresh()    // also held off
        #expect(await device.reads == 1)
        control.setEditing(false)
        #expect(await eventually { await device.reads == 2 })
        #expect(control.deviceValue == 60)
    }

    @Test func aWriteFailureIsShownAndClearsOnSuccess() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device, settle: .seconds(60))
        await control.refresh()
        await device.configure { $0.writeError = DDCError.writeFailed(-1) }
        control.set(60)
        #expect(await idle(control))
        #expect(control.failure?.isTransient == true)
        #expect(control.value == 60)   // the user's intent stays visible
        await device.configure { $0.writeError = nil }
        control.set(61)
        #expect(await idle(control))
        #expect(control.failure == nil)
    }

    @Test func aReadFailureKeepsTheLastValue() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.readError = DDCError.noReply }
        await control.refresh()
        #expect(control.value == 50)
        #expect(control.failure?.message == DDCError.noReply.errorDescription)
    }

    @Test func anUnsupportedCodeIsNotTransient() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        await device.configure { $0.readError = DDCError.unsupported(.contrast) }
        let control = level(device)
        await control.refresh()
        #expect(control.failure?.isTransient == false)
    }

    @Test func aHungOperationTimesOut() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        await device.configure { $0.readGate = gate }
        let control = level(device, timeout: .milliseconds(50))
        await control.refresh()
        #expect(control.failure?.message == DDCError.timedOut.errorDescription)
        #expect(control.value == nil)
        await gate.open()
    }

    @Test func linkOutcomesAreReported() async {
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        var outcomes: [Bool] = []
        control.onLinkOutcome = { outcomes.append((try? $0.get()) != nil) }
        await control.refresh()
        await device.configure { $0.readError = DDCError.noReply }
        await control.refresh()
        #expect(outcomes == [true, false])
    }

    @Test func anInvalidatedControlStopsWriting() async {
        let gate = Gate()
        let device = ScriptedDevice(value: 50.0, range: 0...100)
        let control = level(device)
        await control.refresh()
        await device.configure { $0.writeGate = gate }
        control.set(60)
        #expect(await eventually { await device.attempts == [60] })
        control.set(70)
        control.invalidate()
        await gate.open()
        await settle()
        #expect(await device.attempts == [60])
        control.set(80)
        await settle()
        #expect(await device.attempts == [60])
    }

    @Test func percentQuantization() {
        #expect(quantizeToPercent(0.5049, in: 0...1) == 0.5)
        #expect(quantizeToPercent(1.2, in: 0...1) == 1)
        #expect(quantizeToSteps(41.6, in: 0...100) == 42)
    }
}

@Suite @MainActor struct InputSelectorTests {
    private func selector(current: UInt16 = 0x13) async -> (InputSelector, ScriptedDevice<UInt16>) {
        let device = ScriptedDevice<UInt16>(value: current)
        let control = DeviceControl(backend: device.backend, timing: ControlTiming(settleDelay: .zero))
        let selector = InputSelector(options: MonitorProfile.hpE27mG4.inputs ?? [], control: control)
        await control.refresh()
        return (selector, device)
    }

    @Test func showsTheActiveInput() async {
        let (selector, _) = await selector()
        #expect(selector.current?.name == "USB-C")
        #expect(selector.currentName == "USB-C")
    }

    @Test func aSwitchIsOnlySentOnConfirmation() async {
        let (selector, device) = await selector()
        let hdmi = InputOption(value: 0x11, name: "HDMI")
        selector.request(hdmi)
        #expect(selector.pendingSelection == hdmi)
        await settle()
        #expect(await device.attempts.isEmpty)
        #expect(selector.current?.name == "USB-C")

        selector.confirm()
        #expect(selector.pendingSelection == nil)
        #expect(await eventually { await device.attempts == [0x11] })
    }

    @Test func cancellingSendsNothing() async {
        let (selector, device) = await selector()
        selector.request(InputOption(value: 0x0F, name: "DisplayPort"))
        selector.cancel()
        selector.confirm()
        await settle()
        #expect(selector.pendingSelection == nil)
        #expect(await device.attempts.isEmpty)
    }

    @Test func pickingTheActiveInputStagesNothing() async {
        let (selector, _) = await selector()
        selector.request(InputOption(value: 0x13, name: "USB-C"))
        #expect(selector.pendingSelection == nil)
    }

    @Test func anInputOutsideTheOptionsIsStillNamed() async {
        let (selector, _) = await selector(current: 0x03)
        #expect(selector.current == nil)
        #expect(selector.currentName == "DVI 1")
    }
}
