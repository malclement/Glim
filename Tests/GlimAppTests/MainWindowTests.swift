import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// The main window's lifecycle, and how it stays in step with the menu. No
/// window here comes on screen and no policy reaches the test process:
/// `present` and the policy setter are recorders, and views are drawn
/// offscreen.
@Suite(.serialized) @MainActor struct MainWindowTests {
    /// Records, in order, what was presented and which policies were set.
    @MainActor final class Log {
        var events: [String] = []
        var windows: [NSWindow] = []
        var policies: [NSApplication.ActivationPolicy] = []

        var present: @MainActor (NSWindow) -> Void {
            { [unowned self] in
                windows.append($0)
                events.append("present")
            }
        }

        var setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void {
            { [unowned self] in policies.append($0) }
        }
    }

    /// Sees whether a window was closed.
    @MainActor final class CloseWatcher: NSObject, NSWindowDelegate {
        var closed = false
        func windowWillClose(_ notification: Notification) { closed = true }
    }

    // MARK: One window

    @Test func thereIsOnlyEverOneWindow() {
        let log = Log()
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()), present: log.present)
        controller.show()
        controller.show()
        #expect(log.windows.count == 2)
        #expect(log.windows.first === log.windows.last)
        #expect(controller.prepareWindow() === log.windows.first)
    }

    @Test func theWindowIsOneMacOSDoesNotBringBackByItself() {
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()))
        let window = controller.prepareWindow()
        #expect(window.title == "Glim")
        #expect(!window.isRestorable)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(OffscreenRenderer.spin(until: { window.contentMinSize.width >= 620 && window.contentMinSize.height >= 440 }))
    }

    /// The toolbar's button is the window's way to look for displays again,
    /// and it is off while DDC/CI isn't available at all.
    @Test(arguments: [Situation.hp, .unavailable])
    func lookForDisplaysIsInTheToolbar(in situation: Situation) async throws {
        let setup = try await Setup.make(situation)
        let window = MainWindowController(manager: setup.manager, present: { _ in }).prepareWindow()
        var button: NSControl?
        #expect(OffscreenRenderer.spin(until: {
            button = lookForDisplays(in: window)
            return button != nil
        }))
        #expect(OffscreenRenderer.spin(until: { button?.isEnabled == (situation == .hp) }))
    }

    // MARK: Dock

    /// Glim is in the Dock while the window is open, every time it opens, and
    /// it is in the Dock before the window is brought forward.
    @Test func everyOpeningPutsGlimInTheDockFirst() throws {
        let defaults = try TestDefaults("window-dock")
        let log = Log()
        let presence = AppPresence(defaults: defaults.store, setPolicy: log.setPolicy)
        presence.start()
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()), present: log.present) { isOpen in
            log.events.append(isOpen ? "open" : "closed")
            presence.isWindowOpen = isOpen
        }
        controller.show()
        controller.window?.close()
        #expect(!controller.isOpen)
        controller.show()
        controller.show()
        #expect(controller.isOpen)
        #expect(log.events == ["open", "present", "closed", "open", "present", "present"])
        #expect(log.windows.count == 3 && log.windows.allSatisfy { $0 === log.windows[0] }, "the window is kept")
        #expect(log.policies == [.accessory, .regular, .accessory, .regular])
    }

    // MARK: Interactions

    // `confirm()` clears `pendingSelection` too, so each test also checks,
    // synchronously, that the input kept its value and that nothing is being
    // written: a confirmed switch changes the value and starts its write at
    // once.

    @Test func closingTheWindowDropsAnUnconfirmedInputSwitch() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        controller.show()
        let hdmi = try #require(monitor.input?.options.first { $0.name == "HDMI" })
        monitor.input?.request(hdmi)
        #expect(monitor.input?.pendingSelection == hdmi)
        controller.window?.close()
        #expect(monitor.input?.pendingSelection == nil)
        #expect(monitor.input?.value == 0x13)
        #expect(monitor.input?.isWriting == false)
        await settle()
        #expect(simulated.value(0x60) == 0x13, "nothing was switched")
    }

    @Test func minimisingTheWindowDropsAnUnconfirmedInputSwitch() async throws {
        let (setup, monitor, _) = try await Setup.readyHP()
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        controller.show()
        let window = try #require(controller.window)
        let hdmi = try #require(monitor.input?.options.first { $0.name == "HDMI" })
        monitor.input?.request(hdmi)
        controller.windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: window))
        #expect(monitor.input?.pendingSelection == nil)
        #expect(monitor.input?.value == 0x13)
        #expect(monitor.input?.isWriting == false)
        #expect(controller.isOpen, "a minimised window is still open")
    }

    /// Picking another monitor in the sidebar drops a switch staged on the one
    /// that left, so the prompt isn't waiting when it comes back.
    @Test func leavingAMonitorInTheSidebarDropsItsStagedInputSwitch() async throws {
        let setup = try await Setup.make(.twoMonitors)
        let first = try #require(setup.manager.monitors.first)
        let window = MainWindowController(manager: setup.manager, present: { _ in }).prepareWindow()
        let sidebar = try #require(sidebarTable(in: window))
        let hdmi = try #require(first.input?.options.first { $0.name == "HDMI" })
        first.input?.request(hdmi)
        #expect(first.input?.pendingSelection == hdmi)
        select(row: sidebar.numberOfRows - 1, in: sidebar)
        #expect(OffscreenRenderer.spin(until: { first.input?.pendingSelection == nil }))
        #expect(first.input?.value == 0x13)
        #expect(first.input?.isWriting == false)
    }

    // MARK: Sidebar

    /// The detail follows the sidebar, and falls back to the remaining monitor
    /// when the selected one goes.
    @Test func pickingAMonitorInTheSidebarShowsItsControls() async throws {
        let platform = FakePlatform()
        platform.connect(Setup.hp())
        let identity = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002", productName: "HP E27m G4")
        let secondDisplay = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: identity))
        secondDisplay.update { $0.values[0x10]?.current = 25 }
        let manager = await Setup.started(platform)
        #expect(await eventually { manager.monitors.count == 2 && manager.monitors.allSatisfy { $0.brightness?.value != nil } })
        let (first, second) = (manager.monitors[0], manager.monitors[1])
        let window = MainWindowController(manager: manager, present: { _ in }).prepareWindow()
        let sidebar = try #require(sidebarTable(in: window))

        // At first the detail shows the first monitor, brightness 100.
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: window).map { isAt($0, 1.0) } == true }))
        select(row: sidebar.numberOfRows - 1, in: sidebar)
        // The second one's brightness is 25.
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: window).map { isAt($0, 0.25) } == true }))
        move(try #require(firstSlider(in: window)), to: 0.40)
        #expect(second.brightness?.value == 40)
        #expect(first.brightness?.value == 100)

        // The second monitor goes: the detail is the first one's again.
        platform.state.withLock { _ = $0.displays.removeLast() }
        await manager.rescan()
        #expect(manager.monitors.count == 1)
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: window).map { isAt($0, 1.0) } == true }))
        move(try #require(firstSlider(in: window)), to: 0.60)
        #expect(first.brightness?.value == 60)
    }

    // MARK: Refresh

    /// Coming forward reads every monitor again, as opening the menu does.
    /// The manager skips monitors read in the last two seconds, so the test
    /// waits that long first.
    @Test func theWindowReadsEveryMonitorWhenItComesForward() async throws {
        let platform = FakePlatform()
        let firstDisplay = platform.connect(Setup.hp())
        let identity = DisplayIdentity(vendorID: 0x220E, productID: 0x3753, alphanumericSerial: "TEST0000002", productName: "HP E27m G4")
        let secondDisplay = platform.connect(DiscoveredDisplay(serviceID: 2, framebuffer: "dispext1", identity: identity))
        let manager = await Setup.started(platform)
        #expect(await eventually { manager.monitors.count == 2 && manager.monitors.allSatisfy { $0.brightness?.value == 100 } })
        let controller = MainWindowController(manager: manager, present: { _ in })
        let window = controller.prepareWindow()
        // Changed with the monitors' own buttons, which Glim can't see.
        firstDisplay.update { $0.values[0x10]?.current = 30 }
        secondDisplay.update { $0.values[0x10]?.current = 40 }
        try await Task.sleep(for: .milliseconds(2100))
        #expect(manager.monitors.map { $0.brightness?.value } == [100, 100], "nothing polls")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(await eventually { manager.monitors.map { $0.brightness?.value } == [30, 40] })
    }

    // MARK: One source of truth

    /// Moves the real sliders, as a drag's last step does: the menu's follow
    /// the window's, and the window's the menu's.
    @Test func aChangeInTheWindowShowsInTheMenuAndTheReverse() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let menu = OffscreenRenderer.host(MenuContentView(manager: setup.manager), width: 300, dark: false)
        defer { menu.close() }
        let window = MainWindowController(manager: setup.manager, present: { _ in }).prepareWindow()
        // Brightness comes first in both. It reads 72 of 0–100.
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: menu).map { isAt($0, 0.72) } == true }))
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: window).map { isAt($0, 0.72) } == true }))
        let menuSlider = try #require(firstSlider(in: menu))
        let windowSlider = try #require(firstSlider(in: window))

        move(windowSlider, to: 0.40)
        #expect(monitor.brightness?.value == 40)
        #expect(OffscreenRenderer.spin(until: { isAt(menuSlider, 0.40) }))

        move(menuSlider, to: 0.55)
        #expect(monitor.brightness?.value == 55)
        #expect(OffscreenRenderer.spin(until: { isAt(windowSlider, 0.55) }))
        #expect(await eventually { simulated.value(0x10) == 55 })
    }

    /// SwiftUI never ends a drag on a slider it removes. Here the monitor stops
    /// answering mid-drag and the window swaps its controls for "Not
    /// responding": the slider that went must end the drag, or the monitor
    /// could never be read again while the window stays open.
    @Test func aSliderRemovedMidDragEndsTheDrag() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let window = MainWindowController(manager: setup.manager, present: { _ in }).prepareWindow()
        #expect(OffscreenRenderer.spin(until: { firstSlider(in: window) != nil }))
        let brightness = try #require(monitor.brightness)
        brightness.setEditing(true)
        simulated.update { $0.silent = true }
        await monitor.contrast?.refresh()
        #expect(monitor.status == .notResponding)
        #expect(OffscreenRenderer.spin(until: { !brightness.isEditing }))
    }

    // MARK: Launch, reopen and close

    /// The whole launch, as AppKit drives it: menu bar only until the window
    /// opens, then in the Dock until it closes.
    @Test func aLaunchStartsInTheMenuBarThenOpensTheWindowInTheDock() async throws {
        let defaults = try TestDefaults("launch-path")
        let log = Log()
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults.store,
                                   present: log.present, setPolicy: log.setPolicy, isAnotherCopyRunning: { false })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        #expect(log.policies == [.accessory])
        #expect(log.windows.isEmpty)
        // No Apple event is being handled in a test, as when the bare
        // executable runs: an ordinary open.
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(log.windows.count == 1)
        #expect(log.policies == [.accessory, .regular])
        #expect(await eventually { !delegate.manager.isDiscovering })
        delegate.mainWindow.window?.close()
        #expect(log.policies == [.accessory, .regular, .accessory])
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test func openingGlimWhileItRunsShowsTheWindow() throws {
        let defaults = try TestDefaults("reopen")
        let log = Log()
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults.store,
                                   present: log.present, setPolicy: log.setPolicy, isAnotherCopyRunning: { false })
        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(!handled, "Glim shows the window itself")
        #expect(log.windows.count == 1)
        #expect(delegate.presence.isWindowOpen)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func aLaunchShowsTheWindowUnlessMacOSStartedGlimAtLogin() throws {
        let defaults = try TestDefaults("launch")
        let log = Log()
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults.store,
                                   present: log.present, setPolicy: log.setPolicy, isAnotherCopyRunning: { false })
        delegate.showWindowUnlessLoginItem(Self.launchEvent(launchedAs: keyAELaunchedAsLogInItem))
        #expect(log.windows.isEmpty)
        delegate.showWindowUnlessLoginItem(Self.launchEvent())
        #expect(log.windows.count == 1)
    }

    @Test func loginItemLaunchesAreTold() {
        #expect(AppDelegate.isLoginItemLaunch(Self.launchEvent(launchedAs: keyAELaunchedAsLogInItem)))
        // Finder, Spotlight, Launchpad and `open` send no such flag.
        #expect(!AppDelegate.isLoginItemLaunch(Self.launchEvent()))
        #expect(!AppDelegate.isLoginItemLaunch(Self.launchEvent(launchedAs: keyAELaunchedAsServiceItem)))
        // The bare executable, run during development, gets no event at all.
        #expect(!AppDelegate.isLoginItemLaunch(nil))
        // Only the launch counts.
        #expect(!AppDelegate.isLoginItemLaunch(Self.event(kAEReopenApplication, launchedAs: keyAELaunchedAsLogInItem)))
    }

    /// ⌘W closes the main window, and leaves alone a window without a close
    /// button, such as the menu bar's panel.
    @Test func closeOnlyClosesAWindowWithACloseButton() {
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()), present: { _ in })
        controller.show()
        GlimCommands.close(controller.window)
        #expect(!controller.isOpen)

        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let watcher = CloseWatcher()
        panel.delegate = watcher
        GlimCommands.close(panel)
        #expect(!watcher.closed)
        GlimCommands.close(nil)
    }

    // MARK: Settings

    /// The Dock switch shows AppPresence's rule, and can't be turned off while
    /// the menu bar icon is hidden.
    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func theDockSwitchShowsTheRule(showsMenuBarIcon: Bool, alwaysShowDockIcon: Bool) throws {
        let defaults = try TestDefaults("settings-\(showsMenuBarIcon)-\(alwaysShowDockIcon)")
        defaults.store.set(showsMenuBarIcon, forKey: Preferences.showMenuBarIcon)
        defaults.store.set(alwaysShowDockIcon, forKey: Preferences.alwaysShowDockIcon)
        let host = OffscreenRenderer.host(GeneralSettingsView().defaultAppStorage(defaults.store), width: 460, dark: false)
        defer { host.close() }
        let (menuBar, dock) = try placeSwitches(in: host)
        #expect((menuBar.state == .on) == showsMenuBarIcon)
        let inDock = AppPresence.showsDockIcon(isWindowOpen: false, alwaysShowDockIcon: alwaysShowDockIcon,
                                               showsMenuBarIcon: showsMenuBarIcon)
        #expect((dock.state == .on) == inDock)
        #expect(dock.isEnabled == showsMenuBarIcon)
    }

    /// From a fresh install, turning the menu bar icon off in Settings puts
    /// Glim in the Dock: Settings, the defaults and the presence agree.
    @Test func hidingTheMenuBarIconInSettingsPutsGlimInTheDock() async throws {
        let defaults = try TestDefaults("settings-flow")
        let log = Log()
        let presence = AppPresence(defaults: defaults.store, setPolicy: log.setPolicy)
        presence.start()
        #expect(log.policies == [.accessory])
        let host = OffscreenRenderer.host(GeneralSettingsView().defaultAppStorage(defaults.store), width: 460, dark: false)
        defer { host.close() }
        let (menuBar, dock) = try placeSwitches(in: host)
        #expect(menuBar.state == .on && dock.state == .off, "a fresh install: in the menu bar, not the Dock")
        menuBar.state = .off
        menuBar.sendAction(menuBar.action, to: menuBar.target)
        #expect(defaults.store.object(forKey: Preferences.showMenuBarIcon) as? Bool == false)
        #expect(await eventually { log.policies == [.accessory, .regular] })
        #expect(OffscreenRenderer.spin(until: { dock.state == .on && !dock.isEnabled }))
    }

    // MARK: Wording

    @Test func theProfileSaysWhichControlsWereNotTested() {
        #expect(MonitorText.profile(.hpE27mG4) == "Tested with Glim, except color temperature, color presets and input switching")
        var profile = MonitorProfile.hpE27mG4
        profile.untested = []
        #expect(MonitorText.profile(profile) == "Tested with Glim")
        profile.untested = [.input, .contrast]
        #expect(MonitorText.profile(profile) == "Tested with Glim, except contrast and input switching")
        profile.untested = [.input, .mute, .brightness]
        #expect(MonitorText.profile(profile) == "Tested with Glim, except brightness, mute and input switching")
        #expect(MonitorText.profile(.generic(capabilities: nil)) == "Untested: controls from the display's own description")
    }

    // MARK: Helpers

    private func controls<Control: NSView>(_ type: Control.Type, in view: NSView?) -> [Control] {
        guard let view else { return [] }
        if let control = view as? Control { return [control] }
        return view.subviews.flatMap { controls(type, in: $0) }
    }

    private func firstSlider(in window: NSWindow) -> NSSlider? {
        controls(NSSlider.self, in: window.contentView).first
    }

    /// The table furthest left is the sidebar's.
    private func sidebarTable(in window: NSWindow) -> NSTableView? {
        var sidebar: NSTableView?
        OffscreenRenderer.spin(until: {
            sidebar = controls(NSTableView.self, in: window.contentView)
                .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            return (sidebar?.numberOfRows ?? 0) > 0
        })
        return sidebar
    }

    /// Selects a row as a click would: AppKit tells SwiftUI's binding.
    private func select(row: Int, in table: NSTableView) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func lookForDisplays(in window: NSWindow) -> NSControl? {
        let item = window.toolbar?.items.first { $0.label == "Look for Displays" }
        return controls(NSControl.self, in: item?.view).first
    }

    /// The General pane's switches are, in order: open at login, show in the
    /// menu bar, always show in the Dock, then the menu's five rows.
    private func placeSwitches(in window: NSWindow) throws -> (menuBar: NSSwitch, dock: NSSwitch) {
        var switches: [NSSwitch] = []
        OffscreenRenderer.spin(until: {
            switches = controls(NSSwitch.self, in: window.contentView)
            return switches.count == 8
        })
        try #require(switches.count == 8, "found \(switches.count) switches")
        return (switches[1], switches[2])
    }

    // SwiftUI's AppKit slider runs from its minValue to its maxValue (0 to 1)
    // whatever the range it was given, so these work in fractions of it.

    /// Sets a slider as AppKit does at the end of a drag.
    private func move(_ slider: NSSlider, to fraction: Double) {
        slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        slider.sendAction(slider.action, to: slider.target)
    }

    private func isAt(_ slider: NSSlider, _ fraction: Double) -> Bool {
        let span = slider.maxValue - slider.minValue
        return span > 0 && abs((slider.doubleValue - slider.minValue) / span - fraction) < 0.001
    }

    static func launchEvent(launchedAs flag: OSType? = nil) -> NSAppleEventDescriptor {
        event(kAEOpenApplication, launchedAs: flag)
    }

    static func event(_ id: AEEventID, launchedAs flag: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let flag {
            event.setParam(NSAppleEventDescriptor(enumCode: flag), forKeyword: keyAEPropData)
        }
        return event
    }
}
