import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// The main window's lifecycle, and how it stays in step with the menu. No
/// window here comes on screen: `present` is replaced, and the views are
/// drawn offscreen.
@Suite(.serialized) @MainActor struct MainWindowTests {
    /// Counts the windows brought forward, instead of bringing them forward.
    @MainActor final class Presenter {
        var windows: [NSWindow] = []
        var present: @MainActor (NSWindow) -> Void { { [unowned self] in windows.append($0) } }
    }

    // MARK: One window

    @Test func thereIsOnlyEverOneWindow() {
        let presenter = Presenter()
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()), present: presenter.present)
        controller.show()
        controller.show()
        #expect(presenter.windows.count == 2)
        #expect(presenter.windows.first === presenter.windows.last)
        #expect(controller.prepareWindow() === presenter.windows.first)
    }

    @Test func theWindowIsOneMacOSDoesNotBringBackByItself() {
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()))
        let window = controller.prepareWindow()
        #expect(window.title == "Glim")
        #expect(!window.isRestorable)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        OffscreenRenderer.spin(0.1)
        // SwiftUI's Look for Displays button lives in the window's toolbar.
        #expect(window.toolbar != nil)
        #expect(window.contentMinSize.width >= 620 && window.contentMinSize.height >= 440)
    }

    // MARK: Dock

    @Test func glimIsInTheDockWhileTheWindowIsOpen() throws {
        let defaults = try TestDefaults("window-dock")
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = AppPresence(defaults: defaults.store, setPolicy: { policies.append($0) })
        presence.start()
        let controller = MainWindowController(manager: MonitorManager(platform: FakePlatform()), present: { _ in }) {
            presence.isWindowOpen = $0
        }
        controller.show()
        #expect(controller.isOpen)
        #expect(policies == [.accessory, .regular])
        controller.window?.close()
        #expect(!controller.isOpen)
        #expect(policies == [.accessory, .regular, .accessory])
    }

    // MARK: Interactions

    @Test func closingTheWindowDropsAnUnconfirmedInputSwitch() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        controller.show()
        let hdmi = try #require(monitor.input?.options.first { $0.name == "HDMI" })
        monitor.input?.request(hdmi)
        #expect(monitor.input?.pendingSelection == hdmi)
        controller.window?.close()
        #expect(monitor.input?.pendingSelection == nil)
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
        #expect(controller.isOpen, "a minimised window is still open")
    }

    @Test func theWindowReadsTheMonitorsWhenItComesForward() async throws {
        let (setup, _, _) = try await Setup.readyHP()
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        let window = controller.prepareWindow()
        let before = setup.platform.state.withLock(\.audioQueries)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(await eventually { setup.platform.state.withLock(\.audioQueries) > before })
    }

    // MARK: One source of truth

    /// Moves the real sliders, as a drag's last step does: the menu's follow
    /// the window's, and the window's the menu's.
    @Test func aChangeInTheWindowShowsInTheMenuAndTheReverse() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let menu = OffscreenRenderer.host(MenuContentView(manager: setup.manager), width: 300, dark: false)
        defer { menu.close() }
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        let window = controller.prepareWindow()
        OffscreenRenderer.spin(0.2)
        // Brightness comes first in both. It reads 72 of 0–100.
        let menuSlider = try #require(sliders(in: menu.contentView).first)
        let windowSlider = try #require(sliders(in: window.contentView).first)
        #expect(isAt(menuSlider, 0.72))
        #expect(isAt(windowSlider, 0.72))

        move(windowSlider, to: 0.40)
        #expect(monitor.brightness?.value == 40)
        #expect(await follows(menuSlider, 0.40))

        move(menuSlider, to: 0.55)
        #expect(monitor.brightness?.value == 55)
        #expect(await follows(windowSlider, 0.55))
        #expect(await eventually { simulated.value(0x10) == 55 })
    }

    /// SwiftUI never ends a drag on a slider it removes. Here the monitor stops
    /// answering mid-drag and the window swaps its controls for "Not
    /// responding": the slider that went must end the drag, or the monitor
    /// could never be read again while the window stays open.
    @Test func aSliderRemovedMidDragEndsTheDrag() async throws {
        let (setup, monitor, simulated) = try await Setup.readyHP()
        let controller = MainWindowController(manager: setup.manager, present: { _ in })
        let window = controller.prepareWindow()
        OffscreenRenderer.spin(0.2)
        #expect(!sliders(in: window.contentView).isEmpty)
        let brightness = try #require(monitor.brightness)
        brightness.setEditing(true)
        simulated.update { $0.silent = true }
        await monitor.contrast?.refresh()
        #expect(monitor.status == .notResponding)
        var ended = false
        for _ in 0..<100 where !ended {
            OffscreenRenderer.spin(0.02)
            ended = !brightness.isEditing
        }
        #expect(ended)
    }

    // MARK: Launch and reopen

    @Test func openingGlimWhileItRunsShowsTheWindow() throws {
        let defaults = try TestDefaults("reopen")
        let presenter = Presenter()
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults.store,
                                   present: presenter.present)
        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(!handled, "Glim shows the window itself")
        #expect(presenter.windows.count == 1)
        #expect(delegate.presence.isWindowOpen)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func aLaunchShowsTheWindowUnlessMacOSStartedGlimAtLogin() throws {
        let defaults = try TestDefaults("launch")
        let presenter = Presenter()
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults.store,
                                   present: presenter.present)
        delegate.showWindowUnlessLoginItem(Self.launchEvent(launchedAs: keyAELaunchedAsLogInItem))
        #expect(presenter.windows.isEmpty)
        delegate.showWindowUnlessLoginItem(Self.launchEvent())
        #expect(presenter.windows.count == 1)
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

    // MARK: Wording

    @Test func theProfileSaysWhichControlsWereNotTested() {
        #expect(MonitorText.profile(.hpE27mG4) == "Tested with Glim, except input switching")
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

    private func sliders(in view: NSView?) -> [NSSlider] {
        guard let view else { return [] }
        if let slider = view as? NSSlider { return [slider] }
        return view.subviews.flatMap(sliders(in:))
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

    private func follows(_ slider: NSSlider, _ fraction: Double) async -> Bool {
        for _ in 0..<100 {
            if isAt(slider, fraction) { return true }
            OffscreenRenderer.spin(0.02)
        }
        return isAt(slider, fraction)
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
