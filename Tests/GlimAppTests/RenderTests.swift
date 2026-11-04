import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// Renders the app's real views, in every designed state, in an offscreen
/// window against simulated monitors.
///
/// These are not snapshot tests: nothing is compared with a stored image.
/// They evaluate every view body in every state, which catches a body that
/// traps, and with `GLIM_RENDER_DIR` set they write PNGs to look at:
///
///     GLIM_RENDER_DIR=/tmp/glim-renders swift test --filter RenderTests
///
/// An offscreen window is used because it draws real AppKit controls
/// (sliders, pickers) and needs no Screen Recording permission;
/// `ImageRenderer` draws those as placeholders. The window is never key, so
/// controls render in their inactive colours.
@Suite(.serialized) @MainActor struct RenderTests {
    private let hpAudio = AudioDeviceInfo(id: 97, name: "HP E27m G4 USB Audio", isUSB: true)

    private func hp(_ serviceID: UInt64 = 1, pipe: String = "dispext0") -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: pipe, identity: TestIdentity.hp)
    }

    private func started(_ platform: FakePlatform) async -> MonitorManager {
        let manager = MonitorManager(platform: platform)
        manager.start()
        _ = await eventually { !manager.isDiscovering }
        return manager
    }

    /// An HP with its speakers, brightness at 72 and every value read.
    private func readyHP() async throws -> (MonitorManager, Monitor) {
        let platform = FakePlatform()
        let simulated = platform.connect(hp())
        simulated.update { $0.values[0x10]?.current = 72 }
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        let loaded = await eventually {
            monitor.brightness?.value == 72 && monitor.contrast?.value != nil
                && monitor.volume?.value != nil && monitor.mute?.value != nil && monitor.input?.current != nil
        }
        #expect(loaded)
        return (manager, monitor)
    }

    // MARK: Menu

    @Test func menuWithTheHP() async throws {
        let (manager, _) = try await readyHP()
        try snapshot(MenuContentView(manager: manager), "menu-hp")
    }

    @Test func menuAskingToConfirmAnInputSwitch() async throws {
        let (manager, monitor) = try await readyHP()
        let hdmi = try #require(monitor.input?.options.first { $0.name == "HDMI" })
        monitor.input?.request(hdmi)
        try snapshot(MenuContentView(manager: manager), "menu-confirm-input")
    }

    @Test func menuWithTheSpeakersMuted() async throws {
        let (manager, monitor) = try await readyHP()
        monitor.mute?.set(true)
        _ = await eventually { monitor.mute?.value == true && monitor.mute?.isWriting == false }
        try snapshot(MenuContentView(manager: manager), "menu-muted")
    }

    @Test func menuWithAMonitorThatDoesNotAnswer() async throws {
        let platform = FakePlatform()
        platform.connect(hp(), simulated: SimulatedDisplay { $0.silent = true })
        let manager = await started(platform)
        _ = await eventually { manager.monitors.first?.status == .notResponding }
        try snapshot(MenuContentView(manager: manager), "menu-not-responding")
    }

    @Test func menuWhileConnecting() async throws {
        let platform = FakePlatform()
        let gate = Gate()
        platform.state.withLock { $0.devices[1] = StuckDevice(gate: gate) }
        platform.connect(hp())
        let manager = await started(platform)
        #expect(manager.monitors.first?.status == .connecting)
        try snapshot(MenuContentView(manager: manager), "menu-connecting")
        await gate.open()
    }

    @Test func menuWithAnUntestedMonitor() async throws {
        let platform = FakePlatform()
        let simulated = SimulatedDisplay { state in
            state.capabilities = Array("(prot(monitor)type(LCD)model(Example 27)cmds(01 02 03 F3)vcp(10 12 60(0F 11 12) 62))".utf8)
            state.values = [
                0x10: .init(current: 35, maximum: 100), 0x12: .init(current: 60, maximum: 100),
                0x60: .init(current: 0x11, maximum: 0), 0x62: .init(current: 20, maximum: 100),
            ]
        }
        platform.connect(DiscoveredDisplay(serviceID: 3, framebuffer: "dispext1",
                                           identity: DisplayIdentity(vendorID: 0x10AC, productID: 0x4242)), simulated: simulated)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        _ = await eventually { monitor.volume?.value != nil && monitor.input?.current != nil }
        try snapshot(MenuContentView(manager: manager), "menu-untested")
    }

    @Test func menuWithTwoMonitors() async throws {
        let platform = FakePlatform()
        platform.connect(hp())
        let second = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002", productName: "HP E27m G4")
        platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: second))
        let manager = await started(platform)
        _ = await eventually { manager.monitors.allSatisfy { $0.input?.current != nil } }
        try snapshot(MenuContentView(manager: manager), "menu-two-monitors")
    }

    @Test func menuWithNoMonitor() async throws {
        let manager = await started(FakePlatform())
        try snapshot(MenuContentView(manager: manager), "menu-empty")
    }

    @Test func menuWhileLooking() throws {
        // Not started: the first scan has not finished.
        try snapshot(MenuContentView(manager: MonitorManager(platform: FakePlatform())), "menu-looking")
    }

    @Test func menuWhenDDCIsUnavailable() throws {
        let platform = FakePlatform()
        platform.state.withLock { $0.available = false }
        let manager = MonitorManager(platform: platform)
        manager.start()
        try snapshot(MenuContentView(manager: manager), "menu-unavailable")
    }

    // MARK: Settings

    @Test func settingsPanes() async throws {
        let (manager, _) = try await readyHP()
        try snapshot(SettingsView(manager: manager), "settings-general", width: 460)
        try snapshot(DisplaysPaneHarness(manager: manager), "settings-displays", width: 460)
        try snapshot(AboutPaneHarness(), "settings-about", width: 460)
    }

    @Test func diagnosticsLeaveOutTheSerial() async throws {
        let (manager, _) = try await readyHP()
        let report = manager.diagnosticsReport(appVersion: "test")
        #expect(report.contains("HP E27m G4"))
        #expect(report.contains("profile: hp-e27m-g4 (verified)"))
        #expect(report.contains("serial present"))
        #expect(!report.contains("TEST0000001"))
    }

    // MARK: Rendering

    /// Renders light and dark, checks both drew something, and writes them
    /// out when GLIM_RENDER_DIR is set.
    private func snapshot(_ view: some View, _ name: String, width: CGFloat = 300) throws {
        for dark in [false, true] {
            let image = try #require(OffscreenRenderer.render(view, width: width, dark: dark), "\(name) did not render")
            #expect(image.pixelsWide >= Int(width), "\(name) is \(image.pixelsWide) px wide")
            #expect(image.pixelsHigh > 40, "\(name) is \(image.pixelsHigh) px high")
            OffscreenRenderer.save(image, as: "\(name)-\(dark ? "dark" : "light")")
        }
    }
}

/// TabView only builds its selected tab, so the other panes are rendered on
/// their own.
private struct DisplaysPaneHarness: View {
    let manager: MonitorManager
    var body: some View {
        TabView { DisplaysSettingsView(manager: manager).tabItem { Label("Displays", systemImage: "display") } }
    }
}

private struct AboutPaneHarness: View {
    var body: some View {
        TabView { AboutView().tabItem { Label("About", systemImage: "info.circle") } }
    }
}

@MainActor
enum OffscreenRenderer {
    static func render(_ view: some View, width: CGFloat, dark: Bool) -> NSBitmapImageRep? {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        // Let SwiftUI lay out and AppKit draw its controls.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }

    static func save(_ image: NSBitmapImageRep, as name: String) {
        guard let directory = ProcessInfo.processInfo.environment["GLIM_RENDER_DIR"],
              let data = image.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
