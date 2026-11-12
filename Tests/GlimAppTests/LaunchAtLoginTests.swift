import Foundation
@testable import Glim
import GlimCore
import Testing

/// A login item the test scripts. Nothing is registered on the machine.
@MainActor
final class ScriptedLoginItem: LoginItemService {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The operation couldn't be completed." }
    }

    var status: LoginItemStatus
    /// What `register()` leaves the status at when it succeeds.
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerFails = false
    private(set) var registers = 0
    private(set) var unregisters = 0

    init(_ status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registers += 1
        if registerFails { throw Failure() }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisters += 1
        // The real call throws when nothing is registered.
        guard status == .enabled || status == .requiresApproval else { throw Failure() }
        status = .notRegistered
    }
}

@Suite @MainActor struct LaunchAtLoginTests {
    private func login(_ item: ScriptedLoginItem, path: String = "/Applications/Glim.app",
                       events: EventLog = EventLog()) -> LaunchAtLogin {
        LaunchAtLogin(service: item, bundlePath: path, events: events)
    }

    // MARK: Status to UI state

    @Test(arguments: [
        (LoginItemStatus.enabled, true, false, false),
        (.notRegistered, false, false, false),
        (.requiresApproval, false, true, false),
        (.notFound, false, false, true),
    ])
    func everyStatusHasItsState(status: LoginItemStatus, enabled: Bool, approval: Bool, notFound: Bool) {
        let model = login(ScriptedLoginItem(status))
        model.refresh()
        #expect(model.status == status)
        #expect(model.isEnabled == enabled)
        #expect(model.requiresApproval == approval)
        #expect(model.isNotFound == notFound)
    }

    @Test func theNotFoundNoteExplainsAndTheOthersAreSilent() {
        let note = GeneralSettingsView.loginNote(notFound: true, outsideApplications: false)
        #expect(note?.contains("can't find Glim as a login item") == true)
        #expect(GeneralSettingsView.loginNote(notFound: false, outsideApplications: false) == nil)
        #expect(GeneralSettingsView.loginNote(notFound: false, outsideApplications: true)?.contains("Applications folder") == true)
    }

    // MARK: Errors

    @Test func aFailedRegisterShowsItsErrorAndARefreshOfAHealthyStatusClearsIt() {
        let item = ScriptedLoginItem(.notRegistered)
        item.registerFails = true
        let model = login(item)
        model.setEnabled(true)
        #expect(model.errorMessage == "The operation couldn't be completed.")
        #expect(!model.isEnabled)

        // The user fixed it in System Settings meanwhile.
        item.status = .enabled
        model.refresh()
        #expect(model.isEnabled)
        #expect(model.errorMessage == nil)
    }

    @Test func aRefreshKeepsAnErrorWhileTheStatusStillNeedsAttention() {
        let item = ScriptedLoginItem(.notRegistered)
        item.registerFails = true
        let model = login(item)
        model.setEnabled(true)
        item.status = .requiresApproval
        model.refresh()
        #expect(model.errorMessage != nil)
    }

    @Test func registeringCanLeaveTheItemWaitingForApproval() {
        let item = ScriptedLoginItem(.notRegistered)
        item.statusAfterRegister = .requiresApproval
        let model = login(item)
        model.setEnabled(true)
        #expect(model.requiresApproval)
        #expect(model.errorMessage == nil)
    }

    // MARK: Unregister

    @Test func switchingOffWhenNothingIsRegisteredDoesNotCallUnregister() {
        for status in [LoginItemStatus.notRegistered, .notFound] {
            let item = ScriptedLoginItem(status)
            let model = login(item)
            model.setEnabled(false)
            #expect(item.unregisters == 0)
            #expect(model.errorMessage == nil)
        }
    }

    @Test func switchingOffAnEnabledOrPendingItemUnregistersIt() {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            let item = ScriptedLoginItem(status)
            let model = login(item)
            model.setEnabled(false)
            #expect(item.unregisters == 1)
            #expect(model.status == .notRegistered)
        }
    }

    @Test func constructingAndRefreshingNeverRegisterOrUnregister() {
        let item = ScriptedLoginItem(.enabled)
        let model = login(item)
        model.refresh()
        #expect(item.registers == 0 && item.unregisters == 0)
    }

    // MARK: Logging

    @Test func transitionsAreRecordedInTheEventRing() {
        let events = EventLog()
        let item = ScriptedLoginItem(.notRegistered)
        let model = login(item, events: events)
        model.refresh()
        model.refresh()
        model.setEnabled(true)
        model.setEnabled(false)
        let messages = events.entries.map(\.message)
        #expect(messages == [
            "login item status: notRegistered",
            "registering the login item",
            "login item status: enabled",
            "unregistering the login item",
            "login item status: notRegistered",
        ])
    }

    @Test func aFailedRegisterIsRecorded() {
        let events = EventLog()
        let item = ScriptedLoginItem(.notRegistered)
        item.registerFails = true
        login(item, events: events).setEnabled(true)
        #expect(events.entries.contains { $0.message.hasPrefix("login item register failed") })
    }

    // MARK: Where the app runs

    @Test(arguments: [
        ("/Applications/Glim.app", true),
        ("/Users/me/Applications/Glim.app", true),
        ("/Volumes/Glim 0.4.0/Glim.app", false),
        ("/Users/me/Downloads/Glim.app", false),
        ("/Users/me/Documents/repositories/Glim/dist/Glim.app", false),
        ("/private/var/folders/xx/T/AppTranslocation/ABC/d/Glim.app", false),
        ("/Volumes/Backup/Applications/Glim.app", false),
    ])
    func theBundleLocationCheck(path: String, expected: Bool) {
        #expect(LaunchAtLogin.isInApplications(path, home: "/Users/me") == expected)
    }

    @Test func runningOutsideApplicationsIsExposed() {
        #expect(login(ScriptedLoginItem(), path: "/Volumes/Glim/Glim.app").runsOutsideApplications)
        #expect(!login(ScriptedLoginItem(), path: "/Applications/Glim.app").runsOutsideApplications)
    }
}
