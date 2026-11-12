import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// What the app can find itself showing. Every surface is drawn in each.
enum Situation: String, CaseIterable, Sendable {
    /// An HP with its speakers, brightness at 72 and every value read.
    case hp
    case confirmInput = "confirm-input"
    case muted
    case notResponding = "not-responding"
    case connecting
    case untested
    case twoMonitors = "two-monitors"
    case empty
    /// Not started: the first scan has not finished.
    case looking
    case unavailable
    case controlFailed = "control-failed"
    /// DDC is silent but the USB speakers still answer: their row stays.
    case speakersWhileSilent = "not-responding-speakers"
    /// A monitor without a profile, still reading its capabilities: no
    /// controls yet.
    case readingCapabilities = "reading-capabilities"
    /// A monitor that answers, but offers nothing Glim supports.
    case noSupportedControls = "no-supported-controls"
    /// A display whose EDID was never matched: no name and no EDID row.
    case unidentified
    /// Mute and input writes refused at the bus: their warnings.
    case writesFailed = "writes-failed"
    /// The HP in sRGB: no temperature, so the slider names the preset.
    case srgb
    /// Two scenes, one active; the HP renamed "Desk", its input row hidden
    /// from the menu, at a warm custom temperature.
    case scenes
    /// Automatic brightness following a dim room (10 lux), with one
    /// learned point, and evening warmth on.
    case adaptive
    /// Three HP monitors: the menu is taller than a laptop screen leaves room for.
    case threeMonitors = "three-monitors"
    /// Display and scene names of 60 characters.
    case longNames = "long-names"
    /// Two monitors of one model and one USB audio device: nothing says whose
    /// it is, so neither gets a volume control.
    case ambiguousSpeakers = "ambiguous-speakers"
    /// Automatic brightness paused because the brightness was set by hand.
    case adaptivePaused = "adaptive-paused"
    /// A scene whose only display is away, shown in the menu.
    case sceneAway = "scene-away"
    /// Every display hidden from the menu in the window.
    case allHidden = "all-hidden"
}

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
    // MARK: Menu

    @Test(arguments: Situation.allCases)
    func menu(in situation: Situation) async throws {
        let setup = try await Setup.make(situation)
        try snapshot(MenuContentView(manager: setup.manager)
            .environment(\.glimStore, setup.store)
            .environment(\.adaptive, setup.adaptive), "menu-\(situation.rawValue)")
        await setup.finish()
    }

    // MARK: Window

    /// The whole window, title bar, toolbar and sidebar included.
    @Test(arguments: Situation.allCases)
    func window(in situation: Situation) async throws {
        let setup = try await Setup.make(situation)
        let controller = MainWindowController(manager: setup.manager, store: setup.store, adaptive: setup.adaptive,
                                              present: { _ in })
        try snapshot(controller.prepareWindow(), "window-\(situation.rawValue)")
        await setup.finish()
    }

    /// The second of two monitors' detail, drawn on its own.
    @Test func detailOfTheSecondMonitor() async throws {
        let setup = try await Setup.make(.twoMonitors)
        let second = try #require(setup.manager.monitors.last)
        let view = MonitorDetailView(manager: setup.manager, monitor: second)
            .frame(width: 540, height: 620)
        try snapshot(view, "window-detail-second-monitor", width: 540)
    }

    /// The whole detail pane with automatic brightness on, below the fold
    /// included.
    @Test func adaptiveDetail() async throws {
        let setup = try await Setup.make(.adaptive)
        let monitor = try #require(setup.manager.monitors.first)
        let view = MonitorDetailView(manager: setup.manager, monitor: monitor)
            .environment(\.adaptive, setup.adaptive)
            .environment(\.glimStore, setup.store)
            .frame(width: 560, height: 1900)
        try snapshot(view, "window-detail-adaptive", width: 560)
        await setup.finish()
    }

    /// The scenes' editors: "Day", which the display no longer shows (so
    /// each row says what it shows now), and "Evening", active, with one
    /// display away.
    @Test func sceneDetail() async throws {
        let setup = try await Setup.make(.scenes)
        let store = try #require(setup.store)
        for (scene, name) in zip(store.scenes, ["window-scene-detail-day", "window-scene-detail"]) {
            let view = SceneDetailView(store: store, manager: setup.manager, scene: scene)
                .frame(width: 540, height: 700)
            try snapshot(view, name, width: 540)
        }
        await setup.finish()
    }

    // MARK: Settings

    @Test func settingsPanes() throws {
        let defaults = try TestDefaults("settings")
        try snapshot(SettingsView().defaultAppStorage(defaults.store), "settings-general", width: 460)
        try snapshot(AboutPaneHarness(), "settings-about", width: 460)
        // Without the menu bar icon, the Dock switch is on and can't be turned off.
        defaults.store.set(false, forKey: Preferences.showMenuBarIcon)
        try snapshot(SettingsView().defaultAppStorage(defaults.store), "settings-general-no-menu-bar-icon", width: 460)
    }

    /// The login item in the states that need words: waiting for approval,
    /// and not found, from a disk image.
    @Test func settingsPaneLoginStates() throws {
        let defaults = try TestDefaults("settings-login")
        let approval = LaunchAtLogin(service: ScriptedLoginItem(.requiresApproval), bundlePath: "/Applications/Glim.app", events: EventLog())
        try snapshot(GeneralPaneHarness(login: approval).defaultAppStorage(defaults.store), "settings-general-login-approval", width: 460)
        let notFound = LaunchAtLogin(service: ScriptedLoginItem(.notFound), bundlePath: "/Volumes/Glim/Glim.app", events: EventLog())
        try snapshot(GeneralPaneHarness(login: notFound).defaultAppStorage(defaults.store), "settings-general-login-not-found", width: 460)
    }

    @Test func diagnosticsLeaveOutTheSerial() async throws {
        let setup = try await Setup.make(.hp)
        let report = setup.manager.diagnosticsReport(appVersion: "test")
        // The transport and the recent events are in it, and serial-free too.
        #expect(report.contains("DCPAVServiceProxy entries:"))
        #expect(report.contains("Recent events"))
        #expect(!setup.manager.events.entries.contains { $0.message.contains("TEST0000001") })
        #expect(report.contains("HP E27m G4"))
        #expect(report.contains("profile: hp-e27m-g4 (tested; untested: input)"))
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

    private func snapshot(_ window: NSWindow, _ name: String) throws {
        for dark in [false, true] {
            let image = try #require(OffscreenRenderer.render(window, dark: dark), "\(name) did not render")
            let size = MainWindowController.defaultContentSize
            #expect(image.pixelsWide >= Int(size.width) && image.pixelsHigh >= Int(size.height),
                    "\(name) is \(image.pixelsWide)×\(image.pixelsHigh) px")
            OffscreenRenderer.save(image, as: "\(name)-\(dark ? "dark" : "light")")
        }
    }
}

/// A manager in one ``Situation``, against simulated monitors.
@MainActor
struct Setup {
    let manager: MonitorManager
    let platform: FakePlatform
    /// Scenes and display choices, in memory; nil where they don't matter.
    var store: GlimStore?
    /// Automatic brightness on a scripted sensor; nil where it doesn't matter.
    var adaptive: AdaptiveController?
    private var cleanup: (@MainActor () async -> Void)?

    static let hpAudio = AudioDeviceInfo(id: 97, name: "HP E27m G4 USB Audio", isUSB: true)

    /// 60 characters, past any row's width.
    static func longName(_ prefix: String) -> String {
        String((prefix + " " + String(repeating: "wide name ", count: 8)).prefix(60))
    }

    static func hp(_ serviceID: UInt64 = 1, pipe: String = "dispext0") -> DiscoveredDisplay {
        DiscoveredDisplay(serviceID: serviceID, framebuffer: pipe, identity: TestIdentity.hp)
    }

    /// Releases whatever the situation holds open.
    func finish() async {
        await cleanup?()
    }

    static func started(_ platform: FakePlatform) async -> MonitorManager {
        let manager = MonitorManager(platform: platform)
        manager.start()
        #expect(await eventually { !manager.isDiscovering })
        return manager
    }

    /// The HP, ready: speakers attached, brightness at 72 and every value read.
    static func readyHP() async throws -> (Setup, Monitor, SimulatedDisplay) {
        let platform = FakePlatform()
        let simulated = platform.connect(hp())
        simulated.update { $0.values[0x10]?.current = 72 }
        platform.addAudio(hpAudio)
        let manager = await started(platform)
        let monitor = try #require(manager.monitors.first)
        let loaded = await eventually {
            monitor.brightness?.value == 72 && monitor.contrast?.value != nil
                && monitor.volume?.value != nil && monitor.mute?.value != nil && monitor.input?.current != nil
                && monitor.colorTemperature?.value != nil && monitor.colorPreset?.current != nil
        }
        #expect(loaded)
        return (Setup(manager: manager, platform: platform), monitor, simulated)
    }

    static func make(_ situation: Situation) async throws -> Setup {
        switch situation {
        case .hp:
            return try await readyHP().0

        case .srgb:
            let (setup, monitor, _) = try await readyHP()
            let srgb = try #require(monitor.colorPreset?.options.first { $0.name == "sRGB" })
            monitor.colorPreset?.select(srgb)
            #expect(await eventually { monitor.colorTemperature?.value == 0 && monitor.colorPreset?.isWriting == false })
            #expect(MonitorText.colorTemperature(of: monitor) == "sRGB")
            return setup

        case .adaptive:
            var (setup, monitor, _) = try await readyHP()
            var timing = AdaptiveTiming()
            timing.interval = nil
            timing.fadeDuration = .zero
            let environment = ScriptedEnvironment(hour: 14)
            environment.currentLux = 10
            let adaptive = AdaptiveController(manager: setup.manager, environment: environment, timing: timing)
            adaptive.update(monitor.id) { settings in
                settings.isEnabled = true
                settings.lightCurve.learn(x: BrightnessCurve.lightReading(lux: 100), y: 0.55)
                settings.warmsInEvening = true
            }
            let curve = adaptive.settings(for: monitor.id).lightCurve
            let target = (curve.brightness(at: BrightnessCurve.lightReading(lux: 10)) * 100).rounded()
            #expect(await eventually { monitor.brightness?.value == target && monitor.brightness?.isWriting == false })
            adaptive.tick()
            setup.store = GlimStore(defaults: nil)
            setup.adaptive = adaptive
            return setup

        case .adaptivePaused:
            let setup = try await make(.adaptive)
            let monitor = try #require(setup.manager.monitors.first)
            let adaptive = try #require(setup.adaptive)
            monitor.brightness?.set(20)
            #expect(await eventually { monitor.brightness?.value == 20 && monitor.brightness?.isWriting == false })
            adaptive.tick()
            #expect(await eventually { adaptive.statuses[monitor.id] == .paused })
            return setup

        case .threeMonitors:
            let platform = FakePlatform()
            platform.connect(hp())
            for (index, serial) in ["TEST0000002", "TEST0000003"].enumerated() {
                let identity = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: serial, productName: "HP E27m G4")
                platform.connect(DiscoveredDisplay(serviceID: UInt64(index + 2), framebuffer: "dispext\(index + 1)", identity: identity))
            }
            let manager = await started(platform)
            #expect(await eventually { manager.monitors.count == 3 && manager.monitors.allSatisfy { $0.input?.current != nil && $0.colorPreset?.current != nil } })
            return Setup(manager: manager, platform: platform)

        case .longNames:
            var (setup, monitor, _) = try await readyHP()
            let store = GlimStore(defaults: nil)
            let scene = store.addScene(capturing: setup.manager.monitors)
            store.rename(scene.id, to: Self.longName("Scene"))
            store.setName(Self.longName("Display"), for: monitor.id)
            setup.store = store
            return setup

        case .ambiguousSpeakers:
            let platform = FakePlatform()
            platform.connect(hp())
            let second = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002", productName: "HP E27m G4")
            platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: second))
            platform.addAudio(hpAudio)
            let manager = await started(platform)
            #expect(await eventually { manager.monitors.count == 2 && manager.monitors.allSatisfy { $0.input?.current != nil } })
            #expect(manager.monitors.allSatisfy { $0.volume == nil && $0.audioUnattachedReason == .ambiguous })
            return Setup(manager: manager, platform: platform)

        case .sceneAway:
            var (setup, monitor, _) = try await readyHP()
            let store = GlimStore(defaults: nil)
            let scene = store.addScene(capturing: setup.manager.monitors)
            store.rename(scene.id, to: "Office")
            store.updateScene(scene.id) { scene in
                scene.monitors = ["AOC-U34G2G4R3": .init(monitorName: "U34G2G4R3", brightness: .init(value: 40, maximum: 100))]
            }
            #expect(store.scene(scene.id)?.connected(in: [monitor]).isEmpty == true)
            setup.store = store
            return setup

        case .allHidden:
            var (setup, monitor, _) = try await readyHP()
            let store = GlimStore(defaults: nil)
            store.updateDisplay(monitor.id) { $0.showsInMenu = false }
            setup.store = store
            return setup

        case .scenes:
            var (setup, monitor, _) = try await readyHP()
            let store = GlimStore(defaults: nil)
            let day = store.addScene(capturing: setup.manager.monitors)
            store.rename(day.id, to: "Day")
            store.updateScene(day.id) { $0.symbol = "sun.max" }
            monitor.brightness?.set(30)
            monitor.colorTemperature?.set(40)
            #expect(await eventually { monitor.colorPreset?.current?.name == "5000 K" && monitor.brightness?.isWriting == false })
            let evening = store.addScene(capturing: setup.manager.monitors)
            store.rename(evening.id, to: "Evening")
            store.updateScene(evening.id) { scene in
                scene.includes = [.brightness, .color]
                scene.symbol = "moon.stars"
                scene.monitors["AOC-U34G2G4R3"] = .init(monitorName: "U34G2G4R3", brightness: .init(value: 40, maximum: 100),
                                                        color: .temperature(steps: 25, kelvin: 5500))
            }
            store.setName("Desk", for: monitor.id)
            store.setShows(.input, false, for: monitor.id)
            setup.store = store
            return setup

        case .confirmInput:
            let (setup, monitor, _) = try await readyHP()
            let hdmi = try #require(monitor.input?.options.first { $0.name == "HDMI" })
            monitor.input?.request(hdmi)
            return setup

        case .muted:
            let (setup, monitor, _) = try await readyHP()
            monitor.mute?.set(true)
            #expect(await eventually { monitor.mute?.value == true && monitor.mute?.isWriting == false })
            return setup

        case .notResponding:
            let platform = FakePlatform()
            platform.connect(hp(), simulated: SimulatedDisplay { $0.silent = true })
            let manager = await started(platform)
            #expect(await eventually { manager.monitors.first?.status == .notResponding })
            return Setup(manager: manager, platform: platform)

        case .connecting:
            let platform = FakePlatform()
            let gate = Gate()
            platform.state.withLock { $0.devices[1] = StuckDevice(gate: gate) }
            platform.connect(hp())
            let manager = await started(platform)
            #expect(manager.monitors.first?.status == .connecting)
            return Setup(manager: manager, platform: platform, cleanup: { await gate.open() })

        case .untested:
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
            #expect(await eventually { monitor.volume?.value != nil && monitor.input?.current != nil })
            return Setup(manager: manager, platform: platform)

        case .twoMonitors:
            let platform = FakePlatform()
            platform.connect(hp())
            let second = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002", productName: "HP E27m G4")
            platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: second))
            let manager = await started(platform)
            #expect(await eventually { manager.monitors.count == 2 && manager.monitors.allSatisfy { $0.input?.current != nil } })
            return Setup(manager: manager, platform: platform)

        case .empty:
            let platform = FakePlatform()
            return Setup(manager: await started(platform), platform: platform)

        case .looking:
            let platform = FakePlatform()
            return Setup(manager: MonitorManager(platform: platform), platform: platform)

        case .unavailable:
            let platform = FakePlatform()
            platform.state.withLock { $0.available = false }
            let manager = MonitorManager(platform: platform)
            manager.start()
            return Setup(manager: manager, platform: platform)

        case .controlFailed:
            let platform = FakePlatform()
            let simulated = platform.connect(hp())
            platform.addAudio(hpAudio)
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(await eventually { monitor.brightness?.value != nil && monitor.input?.current != nil })
            simulated.update { $0.failNextWrites = 2 }
            monitor.brightness?.set(40)
            #expect(await eventually { monitor.brightness?.failure != nil && monitor.brightness?.isWriting == false })
            return Setup(manager: manager, platform: platform)

        case .speakersWhileSilent:
            let platform = FakePlatform()
            platform.connect(hp(), simulated: SimulatedDisplay { $0.silent = true })
            platform.addAudio(hpAudio)
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(await eventually { monitor.status == .notResponding && monitor.volume?.value != nil })
            return Setup(manager: manager, platform: platform)

        case .readingCapabilities:
            let platform = FakePlatform()
            let gate = Gate()
            platform.state.withLock { $0.devices[4] = StuckDevice(gate: gate) }
            platform.connect(DiscoveredDisplay(serviceID: 4, framebuffer: "dispext1",
                                               identity: DisplayIdentity(vendorID: 0x10AC, productID: 0x4242)))
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(monitor.status == .connecting && !monitor.hasControls)
            return Setup(manager: manager, platform: platform, cleanup: { await gate.open() })

        case .noSupportedControls:
            let platform = FakePlatform()
            // Brightness and contrast are always tried; this one answers
            // "unsupported" to both, so both go.
            let simulated = SimulatedDisplay { state in
                state.capabilities = Array("(prot(monitor)type(LCD)model(Plain 24)cmds(01 02 03 F3)vcp(14 16))".utf8)
            }
            platform.connect(DiscoveredDisplay(serviceID: 5, framebuffer: "dispext1",
                                               identity: DisplayIdentity(vendorID: 0x10AC, productID: 0x2424)), simulated: simulated)
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(await eventually { monitor.status == .ready && !monitor.hasControls })
            return Setup(manager: manager, platform: platform)

        case .unidentified:
            let platform = FakePlatform()
            platform.connect(DiscoveredDisplay(serviceID: 6, framebuffer: "dispext1", identity: nil))
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(await eventually { monitor.brightness?.value != nil && monitor.contrast?.value != nil })
            #expect(monitor.identity == nil && monitor.name == "External Display")
            return Setup(manager: manager, platform: platform)

        case .writesFailed:
            let platform = FakePlatform()
            let simulated = SimulatedDisplay { state in
                state.capabilities = Array("(prot(monitor)type(LCD)model(Example 27)cmds(01 02 03 F3)vcp(10 12 60(0F 11) 62 8D))".utf8)
                state.values = [
                    0x10: .init(current: 50, maximum: 100), 0x12: .init(current: 50, maximum: 100),
                    0x60: .init(current: 0x0F, maximum: 0), 0x62: .init(current: 30, maximum: 100),
                    0x8D: .init(current: 2, maximum: 2),
                ]
            }
            platform.connect(DiscoveredDisplay(serviceID: 7, framebuffer: "dispext1",
                                               identity: DisplayIdentity(vendorID: 0x10AC, productID: 0x4243)), simulated: simulated)
            let manager = await started(platform)
            let monitor = try #require(manager.monitors.first)
            #expect(await eventually { monitor.mute?.value != nil && monitor.input?.current != nil })
            // A simulated display: the bus refuses both writes, nothing real.
            simulated.update { $0.failNextWrites = 6 }
            monitor.mute?.set(true)
            let other = try #require(monitor.input?.options.first { $0.value == 0x11 })
            monitor.input?.request(other)
            monitor.input?.confirm()
            #expect(await eventually {
                monitor.mute?.failure != nil && monitor.input?.failure != nil
                    && monitor.mute?.isWriting == false && monitor.input?.isWriting == false
            })
            return Setup(manager: manager, platform: platform)
        }
    }

    private init(manager: MonitorManager, platform: FakePlatform, cleanup: (@MainActor () async -> Void)? = nil) {
        self.manager = manager
        self.platform = platform
        self.cleanup = cleanup
    }
}

/// A defaults suite of a test's own, emptied before and after, so a test
/// never reads or writes the test runner's own defaults.
final class TestDefaults {
    let store: UserDefaults
    /// The suite's name, to reach the same defaults from another thread.
    let name: String

    init(_ name: String) throws {
        self.name = "io.github.malclement.Glim.tests.\(name)"
        store = try #require(UserDefaults(suiteName: self.name))
        store.removePersistentDomain(forName: self.name)
    }

    deinit {
        store.removePersistentDomain(forName: name)
    }
}

/// TabView only builds its selected tab, so the other panes are rendered on
/// their own.
private struct GeneralPaneHarness: View {
    let login: LaunchAtLogin
    var body: some View {
        TabView { GeneralSettingsView(login: login).tabItem { Label("General", systemImage: "gearshape") } }
    }
}

private struct AboutPaneHarness: View {
    var body: some View {
        TabView { AboutView().tabItem { Label("About", systemImage: "info.circle") } }
    }
}

@MainActor
enum OffscreenRenderer {
    /// Puts `view` in a borderless window far off screen, and draws it.
    static func host(_ view: some View, width: CGFloat, dark: Bool) -> NSWindow {
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
        // Let SwiftUI lay out and AppKit draw its controls.
        spin(0.15)
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    static func render(_ view: some View, width: CGFloat, dark: Bool) -> NSBitmapImageRep? {
        let window = host(view, width: width, dark: dark)
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let hosting = window.contentView else { return nil }
        return draw(hosting)
    }

    /// Draws a titled window, frame and toolbar included. It is never ordered
    /// in: AppKit moves a titled window onto a screen when it is, and this one
    /// draws all the same.
    static func render(_ window: NSWindow, dark: Bool) -> NSBitmapImageRep? {
        NSApplication.shared.setActivationPolicy(.prohibited)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        spin(0.2)
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        return draw(frame)
    }

    /// Runs the main run loop, so SwiftUI can update and AppKit can draw.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs the main run loop until `condition` holds, for at most `timeout`.
    /// The budget is generous on purpose: it is there to fail a hung test on a
    /// slow runner, not to time a fast one.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            spin(0.02)
        }
        return true
    }

    private static func draw(_ view: NSView) -> NSBitmapImageRep? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
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
