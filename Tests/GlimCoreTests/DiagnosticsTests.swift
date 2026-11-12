import Foundation
@testable import GlimCore
import GlimTestSupport
import Testing

/// A device whose every read and write fails at the bus with one IOReturn.
private actor BrokenBus: DDCDevice {
    let error: DDCError
    init(_ error: DDCError) { self.error = error }
    func read(_ code: VCPCode) async throws -> VCPReading { throw error }
    func write(_ code: VCPCode, value: UInt16) async throws { throw error }
    func capabilitiesFragment(at offset: UInt16) async throws -> [UInt8] { throw error }
}

/// The report a user pastes into a bug report, the event ring behind it and
/// the hint for a display Glim cannot use.
@Suite @MainActor struct DiagnosticsTests {
    private let kIOReturnNotResponding = Int32(bitPattern: 0xE000_02ED)
    private let kIOReturnNoDevice = Int32(bitPattern: 0xE000_02C0)

    private func hp(_ serviceID: UInt64 = 1, pipe: String = "dispext0") -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: pipe, identity: Fixtures.hpIdentity)
    }

    private func started(_ platform: FakePlatform, events: EventLog = EventLog()) async -> MonitorManager {
        let manager = MonitorManager(platform: platform, events: events)
        manager.start()
        _ = await eventually { !manager.isDiscovering }
        return manager
    }

    // MARK: The report

    @Test func theReportKeepsTheIOReturnOfAFailedRead() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.state.withLock { $0.devices[1] = BrokenBus(.readFailed(Int32(bitPattern: 0xE000_02C7))) }
        platform.transportSummary = TransportSummary(
            symbols: [SymbolStatus(name: "IOAVServiceReadI2C", resolved: true)],
            proxies: [.init(location: "External", parent: "dispext0:dcpav-service-epic:0")],
            framebuffers: [.init(pipe: "dispext0", isExternal: true, identity: "HPN 3753"),
                           .init(pipe: "disp0", isExternal: false, identity: nil)]
        )
        let events = EventLog()
        let manager = await started(platform, events: events)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.brightness?.failure != nil })

        let report = manager.diagnosticsReport(appVersion: "test", context: DiagnosticsContext(launchedAtLogin: true, loginItemStatus: "enabled"))
        // The user message is unchanged; the IOReturn rides along.
        #expect(monitor.brightness?.failure?.message == "The display didn't accept the command.")
        #expect(report.contains("The display didn't accept the command. (readFailed 0xE00002C7)"))
        #expect(report.contains("IOAVService symbols: IOAVServiceReadI2C ok"))
        #expect(report.contains("DCPAVServiceProxy entries: 1"))
        #expect(report.contains("Location=External, parent dispext0:dcpav-service-epic:0"))
        #expect(report.contains("Framebuffers: 1 external, 1 built-in"))
        #expect(report.contains("dispext0: EDID HPN 3753"))
        #expect(report.contains("Launched at login: yes"))
        #expect(report.contains("Login item: enabled"))
        #expect(report.contains("Recent events"))
        #expect(report.contains("[discovery] monitor connected: HP E27m G4"))
        #expect(report.contains("[control] HP E27m G4 brightness read failed: The display didn't accept the command. [readFailed 0xE00002C7]"))
        #expect(report.contains("inputs offered: DisplayPort (0x"))
        // Neither the report nor the ring knows the serial.
        #expect(!report.contains("TEST0000001"))
        #expect(!events.entries.contains { $0.message.contains("TEST0000001") })
        manager.stop()
    }

    @Test func theReportOfTwoMonitorsHasNoSerial() async throws {
        let platform = FakePlatform()
        platform.connect(hp(1, pipe: "dispext0"))
        platform.connect(hp(2, pipe: "dispext1"))
        let manager = await started(platform)
        #expect(await eventually { manager.monitors.count == 2 && manager.monitors.allSatisfy { $0.brightness?.value != nil } })
        let report = manager.diagnosticsReport(appVersion: "test")
        #expect(report.contains("Monitors 2"))
        #expect(!report.contains("TEST0000001"))
        manager.stop()
    }

    @Test func repeatedFailuresAreOneCountedEvent() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.state.withLock { $0.devices[1] = BrokenBus(.noReply) }
        let events = EventLog()
        let manager = await started(platform, events: events)
        let monitor = try #require(manager.monitors.first)
        #expect(await eventually { monitor.brightness?.failure != nil })
        await monitor.refresh()
        await monitor.refresh()
        let failures = events.entries.filter { $0.message.contains("brightness read failed") }
        #expect(failures.count == 1)
        #expect((failures.first?.count ?? 0) >= 2)
        #expect(failures.first?.message.hasSuffix("[noReply]") == true)
        manager.stop()
    }

    @Test func aWriteTheAllowListRefusesIsRecorded() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        platform.state.withLock { $0.devices[1] = BrokenBus(.refused(.brightness)) }
        let events = EventLog()
        let manager = await started(platform, events: events)
        let monitor = try #require(manager.monitors.first)
        monitor.brightness?.set(40)
        #expect(await eventually { events.entries.contains { $0.message.contains("write refused by the allow-list") } })
        manager.stop()
    }

    @Test func theLaunchLoginAndRelativeTimesAreInTheReport() async throws {
        let events = EventLog()
        let now = Date()
        events.record("app", "launch", at: now.addingTimeInterval(-12))
        let manager = MonitorManager(platform: FakePlatform(), events: events)
        let report = manager.diagnosticsReport(appVersion: "1.0", now: now)
        #expect(report.contains("12 s ago  [app] launch"))
        #expect(report.contains("Launched at login: unknown"))
        #expect(report.contains("macOS "))
    }

    // MARK: The event ring

    @Test func theRingKeepsTheLastForty() {
        let log = EventLog()
        for index in 0..<100 { log.record("t", "event \(index)") }
        #expect(log.entries.count == EventLog.capacity)
        #expect(log.entries.first?.message == "event 60")
        #expect(log.entries.last?.message == "event 99")
    }

    @Test func theRingMergesAnImmediateRepeat() {
        let log = EventLog()
        log.record("a", "same")
        log.record("a", "same")
        log.record("b", "same")
        log.record("a", "same")
        #expect(log.entries.map(\.count) == [2, 1, 1])
        #expect(log.lines().first?.hasSuffix("(x2)") == true)
    }

    @Test func theRingTakesEventsFromManyTasks() async {
        let log = EventLog()
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask { for index in 0..<50 { log.record("t\(task)", "event \(index)") } }
            }
        }
        #expect(log.entries.count == EventLog.capacity)
        #expect(log.entries.allSatisfy { $0.count == 1 })
    }

    @Test func relativeTimes() {
        let now = Date()
        #expect(EventLog.relative(now.addingTimeInterval(-12), to: now) == "12 s ago")
        #expect(EventLog.relative(now.addingTimeInterval(-125), to: now) == "2 min ago")
        #expect(EventLog.relative(now.addingTimeInterval(-3 * 3600 - 600), to: now) == "3 h 10 min ago")
        #expect(EventLog.relative(now.addingTimeInterval(5), to: now) == "0 s ago")
    }

    @Test func technicalDetailNamesTheIOReturn() {
        #expect(DDCError.readFailed(kIOReturnNotResponding).technicalDetail == "readFailed 0xE00002ED")
        #expect(DDCError.writeFailed(kIOReturnNoDevice).technicalDetail == "writeFailed 0xE00002C0")
        #expect(DDCError.timedOut.technicalDetail == "timedOut")
        #expect(DDCError.noReply.technicalDetail == "noReply")
    }

    // MARK: Availability

    @Test func missingSymbolsOnAppleSiliconDoNotBlameTheHardware() {
        let text = MonitorManager.unavailableMessage(isAppleSilicon: true)
        #expect(text.contains("This version of macOS no longer provides the interface Glim uses"))
        #expect(text.contains("Check for a Glim update"))
        #expect(!text.contains("needs a Mac with Apple silicon"))
        #expect(MonitorManager.unavailableMessage(isAppleSilicon: false).contains("needs a Mac with Apple silicon"))
    }

    @Test func unavailableDDCSaysWhyAndIsRecorded() {
        let platform = FakePlatform()
        platform.state.withLock { $0.available = false }
        let manager = MonitorManager(platform: platform)
        manager.start()
        #expect(manager.availability == .unavailable(MonitorManager.unavailableMessage()))
        let report = manager.diagnosticsReport(appVersion: "test")
        #expect(report.contains("DDC/CI unavailable because: "))
        #expect(manager.events.entries.contains { $0.message.contains("DDC/CI unavailable") })
        #if arch(arm64)
        #expect(MonitorManager.unavailableMessage().contains("Check for a Glim update"))
        #endif
    }

    // MARK: Discovery hint

    private let unusable = TransportSummary(
        proxies: [.init(location: "External", parent: "dispext0:dcpav-service-epic:0")],
        framebuffers: [.init(pipe: "dispext0", isExternal: true, identity: "HPN 3753")]
    )

    @Test func theHintAppearsWhenTheRegistryShowsADisplayTheScanMissed() async {
        let platform = FakePlatform()
        platform.transportSummary = unusable
        let manager = await started(platform)
        #expect(manager.discoveryHint == "A display is connected, but Glim can't reach it on this version of macOS.")
        #expect(manager.diagnosticsReport(appVersion: "t").contains("Discovery: A display is connected"))
    }

    @Test func theHintStaysNilWithNothingConnected() async {
        let platform = FakePlatform()
        platform.transportSummary = TransportSummary(
            proxies: [.init(location: "Embedded", parent: "disp0:dcpav-service-epic:0")],
            framebuffers: [.init(pipe: "disp0", isExternal: false, identity: nil)]
        )
        let manager = await started(platform)
        #expect(manager.discoveryHint == nil)
    }

    @Test func theHintClearsWhenADisplayIsFound() async {
        let platform = FakePlatform()
        platform.transportSummary = unusable
        let manager = await started(platform)
        #expect(manager.discoveryHint != nil)
        platform.connect(hp())
        await manager.rescan()
        #expect(manager.monitors.count == 1)
        #expect(manager.discoveryHint == nil)
        manager.stop()
    }

    @Test func discoveryCountChangesAreRecordedOnce() async {
        let platform = FakePlatform()
        let manager = await started(platform)
        await manager.rescan()
        platform.connect(hp())
        await manager.rescan()
        let counts = manager.events.entries.filter { $0.message.hasPrefix("scan found") }.map(\.message)
        #expect(counts == ["scan found 0 external display(s)", "scan found 1 external display(s)"])
        manager.stop()
    }

    @Test func theTransportSummaryIsPlainLines() {
        let summary = TransportSummary(
            symbols: [SymbolStatus(name: "A", resolved: true), SymbolStatus(name: "B", resolved: false)],
            proxies: [.init(location: nil, parent: nil)],
            framebuffers: [.init(pipe: "dispext0", isExternal: true, identity: nil)]
        )
        #expect(summary.lines == [
            "IOAVService symbols: A ok, B MISSING",
            "DCPAVServiceProxy entries: 1",
            "  Location=?, parent ?",
            "Framebuffers: 1 external, 0 built-in",
            "  dispext0: EDID absent",
        ])
        #expect(summary.suggestsUnusableDisplay)
    }
}
