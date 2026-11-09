import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// Scenes and per-display choices: kept across launches, and followed by the
/// menu and the window.
@Suite(.serialized) @MainActor struct GlimStoreTests {
    // MARK: Keeping

    @Test func scenesAndDisplayChoicesSurviveARelaunch() async throws {
        let defaults = try TestDefaults("store-relaunch")
        let (setup, monitor, _) = try await Setup.readyHP()
        let store = GlimStore(defaults: defaults.store)
        let scene = store.addScene(capturing: setup.manager.monitors)
        store.rename(scene.id, to: "  Evening ")
        store.updateScene(scene.id) { $0.includes = [.brightness, .color] }
        store.setName("Desk", for: monitor.id)
        store.setShows(.volume, false, for: monitor.id)

        let relaunched = GlimStore(defaults: defaults.store)
        #expect(relaunched.scenes.map(\.name) == ["Evening"])
        #expect(relaunched.scenes.first?.includes == [.brightness, .color])
        #expect(relaunched.scenes.first?.monitors[monitor.id]?.brightness?.value == 72)
        #expect(relaunched.title(for: monitor, in: setup.manager) == "Desk")
        #expect(!relaunched.shows(.volume, for: monitor.id, default: true))
        #expect(relaunched.shows(.contrast, for: monitor.id, default: true))
        await setup.finish()
    }

    @Test func unreadableDataIsSetAsideNotOverwritten() throws {
        let defaults = try TestDefaults("store-unreadable")
        let garbage = Data("not json".utf8)
        defaults.store.set(garbage, forKey: GlimStore.scenesKey)
        let store = GlimStore(defaults: defaults.store)
        #expect(store.scenes.isEmpty)
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == garbage)
        store.addScene(capturing: [])
        #expect(defaults.store.data(forKey: GlimStore.scenesKey + ".unreadable") == garbage)
    }

    @Test func newScenesGetNamesOfTheirOwn() {
        let store = GlimStore(defaults: nil)
        let names = (0..<3).map { _ in store.addScene(capturing: []).name }
        #expect(names == ["New Scene", "New Scene 2", "New Scene 3"])
        store.rename(store.scenes[0].id, to: "   ")
        #expect(store.scenes[0].name == "New Scene", "a blank name is ignored")
        store.deleteScene(store.scenes[1].id)
        #expect(store.addScene(capturing: []).name == "New Scene 2")
    }

    @Test func aDuplicateSitsBelowItsOriginalWithItsOwnName() {
        let store = GlimStore(defaults: nil)
        let first = store.addScene(capturing: [])
        store.rename(first.id, to: "Evening")
        store.updateScene(first.id) { $0.symbol = "moon" }
        store.addScene(capturing: [])
        let copy = store.duplicateScene(first.id)
        let again = store.duplicateScene(first.id)
        #expect(store.scenes.map(\.name) == ["Evening", "Evening Copy 2", "Evening Copy", "New Scene"])
        #expect(copy?.symbol == "moon" && copy?.id != first.id && again?.id != copy?.id)
    }

    @Test func theFirstNineScenesHaveShortcuts() {
        let store = GlimStore(defaults: nil)
        let scenes = (0..<10).map { _ in store.addScene(capturing: []) }
        #expect(scenes.map { store.shortcutDigit(for: $0.id) } == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil])
        store.moveScenes(from: [9], to: 0)
        #expect(store.shortcutDigit(for: scenes[9].id) == 1)
        #expect(store.shortcutDigit(for: scenes[8].id) == nil)
    }

    @Test func displayChoicesFollowSettingsUntilChanged() {
        let store = GlimStore(defaults: nil)
        #expect(store.shows(.input, for: "a", default: false) == false)
        #expect(store.shows(.input, for: "a", default: true) == true)
        store.setShows(.input, false, for: "a")
        #expect(store.shows(.input, for: "a", default: true) == false)
        store.setName("Left", for: "a")
        store.updateDisplay("a") { $0.showsInMenu = false }
        #expect(!store.showsInMenu("a"))

        store.resetMenu(for: "a")
        #expect(store.showsInMenu("a"))
        #expect(store.shows(.input, for: "a", default: true))
        #expect(store.preferences(for: "a").name == "Left", "the name stays")
        store.setName(" ", for: "a")
        #expect(store.displays["a"] == nil, "nothing left to keep")
    }

    // MARK: The app

    @Test func theWindowUsesTheAppsStore() {
        let defaults = try? TestDefaults("store-delegate")
        let delegate = AppDelegate(manager: MonitorManager(platform: FakePlatform()), defaults: defaults?.store ?? .standard,
                                   present: { _ in }, setPolicy: { _ in }, isAnotherCopyRunning: { false })
        #expect(delegate.mainWindow.store === delegate.store)
    }

    /// "New Scene" in the toolbar saves what the displays show and selects
    /// the new scene in the sidebar. (Its Apply button runs
    /// `DisplayScene.apply`, tested in SceneTests: SwiftUI draws a form's
    /// buttons itself, and an offscreen window has no accessibility tree to
    /// press them through.)
    @Test func newSceneSavesTheDisplaysAndSelectsTheScene() async throws {
        let (setup, monitor, _) = try await Setup.readyHP()
        let store = GlimStore(defaults: nil)
        let window = MainWindowController(manager: setup.manager, store: store, present: { _ in }).prepareWindow()
        let newScene = try #require(toolbarButton("New Scene", in: window))
        #expect(OffscreenRenderer.spin(until: { newScene.isEnabled }))
        newScene.performClick(nil)
        #expect(store.scenes.map(\.name) == ["New Scene"])
        #expect(store.scenes.first?.monitors[monitor.id]?.brightness?.value == 72)
        // Rows: "Displays", the HP, "Scenes", the scene, which is selected.
        let sidebar = try #require(controls(NSTableView.self, in: window.contentView)
            .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        #expect(OffscreenRenderer.spin(until: { sidebar.numberOfRows == 4 && sidebar.selectedRow == 3 }))
        await setup.finish()
    }

    /// The menu leaves out what the window hid: a row, or a whole display.
    @Test func theMenuFollowsEachDisplaysChoices() async throws {
        let (setup, monitor, _) = try await Setup.readyHP()
        let store = GlimStore(defaults: nil)
        let menu = OffscreenRenderer.host(MenuContentView(manager: setup.manager).environment(\.glimStore, store),
                                          width: 300, dark: false)
        defer { menu.close() }
        func sliders() -> Int { controls(NSSlider.self, in: menu.contentView).count }
        // Brightness, contrast, temperature, volume.
        #expect(OffscreenRenderer.spin(until: { sliders() == 4 }))
        store.setShows(.color, false, for: monitor.id)
        #expect(OffscreenRenderer.spin(until: { sliders() == 3 }))
        store.updateDisplay(monitor.id) { $0.showsInMenu = false }
        #expect(OffscreenRenderer.spin(until: { sliders() == 0 }))
        await setup.finish()
    }

    // MARK: Helpers

    private func controls<Control: NSView>(_ type: Control.Type, in view: NSView?) -> [Control] {
        guard let view else { return [] }
        if let control = view as? Control { return [control] }
        return view.subviews.flatMap { controls(type, in: $0) }
    }

    private func toolbarButton(_ label: String, in window: NSWindow) -> NSControl? {
        var found: NSControl?
        OffscreenRenderer.spin(until: {
            let item = window.toolbar?.items.first { $0.label == label }
            found = controls(NSControl.self, in: item?.view).first
            return found != nil
        })
        return found
    }
}
