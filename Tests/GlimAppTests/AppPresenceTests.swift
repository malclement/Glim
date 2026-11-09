import AppKit
@testable import Glim
import GlimTestSupport
import Testing

private let everyCombination: [(Bool, Bool, Bool)] = [false, true].flatMap { open in
    [false, true].flatMap { always in [false, true].map { menuBar in (open, always, menuBar) } }
}

/// When Glim is in the Dock. Each test has a defaults suite of its own and
/// records the policy instead of applying it to the test process.
@Suite @MainActor struct AppPresenceTests {
    @MainActor final class Recorder {
        var policies: [NSApplication.ActivationPolicy] = []
        var set: @MainActor (NSApplication.ActivationPolicy) -> Void { { [unowned self] in policies.append($0) } }
    }

    @Test(arguments: everyCombination)
    func theRule(isWindowOpen: Bool, alwaysShowDockIcon: Bool, showsMenuBarIcon: Bool) {
        let inDock = AppPresence.showsDockIcon(isWindowOpen: isWindowOpen, alwaysShowDockIcon: alwaysShowDockIcon,
                                               showsMenuBarIcon: showsMenuBarIcon)
        // Out of the Dock only with the window closed, the setting off and the
        // menu bar icon there to get back in by.
        #expect(inDock == !(!isWindowOpen && !alwaysShowDockIcon && showsMenuBarIcon))
    }

    @Test func aMenuBarAppUntilTheWindowOpens() throws {
        let defaults = try TestDefaults("presence-window")
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.start()
        #expect(recorder.policies == [.accessory])
        presence.isWindowOpen = true
        #expect(recorder.policies == [.accessory, .regular])
        presence.isWindowOpen = false
        #expect(recorder.policies == [.accessory, .regular, .accessory])
    }

    @Test func nothingIsAppliedBeforeStart() throws {
        let defaults = try TestDefaults("presence-start")
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.isWindowOpen = true
        #expect(recorder.policies.isEmpty)
        #expect(presence.showsDockIcon)
        presence.start()
        #expect(recorder.policies == [.regular])
    }

    @Test func aPolicyIsAppliedOnlyWhenItChanges() throws {
        let defaults = try TestDefaults("presence-changes")
        defaults.store.set(true, forKey: Preferences.alwaysShowDockIcon)
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.start()
        presence.isWindowOpen = true
        presence.isWindowOpen = false
        #expect(recorder.policies == [.regular])
    }

    @Test func theSettingKeepsGlimInTheDock() async throws {
        let defaults = try TestDefaults("presence-always")
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.start()
        defaults.store.set(true, forKey: Preferences.alwaysShowDockIcon)
        #expect(await eventually { recorder.policies == [.accessory, .regular] })
        defaults.store.set(false, forKey: Preferences.alwaysShowDockIcon)
        #expect(await eventually { recorder.policies == [.accessory, .regular, .accessory] })
    }

    /// A change can arrive on any thread, as a `defaults write` may: the
    /// presence must hop to the main actor rather than assume it is there.
    @Test func aChangeMadeOnAnotherThreadIsApplied() async throws {
        let defaults = try TestDefaults("presence-thread")
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.start()
        let suite = defaults.name
        let wroteOffMain = await Task.detached {
            UserDefaults(suiteName: suite)?.set(true, forKey: Preferences.alwaysShowDockIcon)
            return pthread_main_np() == 0
        }.value
        #expect(wroteOffMain)
        #expect(await eventually { recorder.policies == [.accessory, .regular] })
    }

    @Test func withoutTheMenuBarIconGlimStaysInTheDock() async throws {
        let defaults = try TestDefaults("presence-menu-bar")
        let recorder = Recorder()
        let presence = AppPresence(defaults: defaults.store, setPolicy: recorder.set)
        presence.start()
        defaults.store.set(false, forKey: Preferences.showMenuBarIcon)
        #expect(await eventually { recorder.policies == [.accessory, .regular] })
        // The window closing doesn't take Glim out of the Dock either.
        presence.isWindowOpen = true
        presence.isWindowOpen = false
        #expect(recorder.policies == [.accessory, .regular])
        defaults.store.set(true, forKey: Preferences.showMenuBarIcon)
        #expect(await eventually { recorder.policies == [.accessory, .regular, .accessory] })
    }

    @Test func theMenuBarIconIsShownUntilTurnedOff() throws {
        let defaults = try TestDefaults("presence-defaults")
        #expect(defaults.store.showMenuBarIcon)
        #expect(!defaults.store.alwaysShowDockIcon)
    }
}
