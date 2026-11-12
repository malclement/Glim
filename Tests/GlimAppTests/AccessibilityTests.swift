import AppKit
@testable import Glim
import GlimCore
import GlimTestSupport
import SwiftUI
import Testing

/// The words, motion and contrast rules that VoiceOver and the accessibility
/// settings depend on. They are pure functions because the accessibility tree
/// is not built without an assistive client, so a label cannot be read back
/// from a rendered view.
@Suite struct AccessibilityHelperTests {
    @Test func theInputConfirmationIsAnnounced() {
        #expect(AccessibilityText.inputConfirmation(target: "HDMI") == "Switch to HDMI? Cancel or Switch.")
        #expect(AccessibilityText.inputConfirmationLabel == "Confirm input switch")
    }

    @Test func brightnessSaysWhetherAutomaticBrightnessDrivesIt() {
        let following = AdaptiveStatus.following(source: .lightSensor, target: 0.5, fallback: nil)
        #expect(AccessibilityText.automaticBrightnessSuffix(following) == ", adjusting automatically")
        #expect(AccessibilityText.automaticBrightnessSuffix(.paused) == ", automatic brightness paused")
        #expect(AccessibilityText.automaticBrightnessSuffix(.off).isEmpty)
        #expect(AccessibilityText.automaticBrightnessSuffix(.waiting).isEmpty)
        #expect(AccessibilityText.automaticBrightnessSuffix(nil).isEmpty)
    }

    @Test func pausedAndOffHaveDifferentGlyphs() {
        #expect(BrightnessSymbol.pausedSymbol != "sun.max")
        #expect(BrightnessSymbol.pausedSymbol != "sun.max.fill")
    }

    @Test func slidersSpeakUnits() {
        #expect(AccessibilityText.kelvin(4500) == "4500 kelvin")
        #expect(AccessibilityText.percent(0.35) == "35 percent")
        #expect(AccessibilityText.percent(1) == "100 percent")
        #expect(AccessibilityText.spokenTemperature("6500 K") == "6500 kelvin")
        #expect(AccessibilityText.spokenTemperature("sRGB") == "sRGB")
        #expect(AccessibilityText.spokenTemperature("–") == "–")
    }

    @Test func aFailureIsPartOfTheSpokenValue() {
        #expect(AccessibilityText.value("40%", failure: nil) == "40%")
        #expect(AccessibilityText.value("40%", failure: "Not accepted") == "40%. Not accepted")
        #expect(AccessibilityText.warningLabel("Not accepted") == "Warning: Not accepted")
    }

    @Test func theCurveSaysWhereTheDisplayIs() {
        let dark = AccessibilityText.curveReading(source: .lightSensor, reading: BrightnessCurve.lightReading(lux: 99), brightness: 0.4)
        #expect(dark == "Light now about 99 lux, display at 40 percent")
        #expect(AccessibilityText.curveReading(source: .followBuiltIn, reading: 0.5, brightness: nil) == "MacBook screen at 50 percent")
        #expect(AccessibilityText.curveReading(source: .schedule, reading: nil, brightness: 0.25) == "display at 25 percent")
        #expect(AccessibilityText.curveReading(source: .lightSensor, reading: nil, brightness: nil).isEmpty)
    }

    @Test func theSpeakersReasonIsToldForEachCase() {
        let ambiguous = AccessibilityText.speakersReason(.ambiguous)
        #expect(ambiguous?.contains("can't tell which speakers belong") == true)
        #expect(AccessibilityText.speakersReason(.noDevice) != nil)
        #expect(AccessibilityText.speakersReason(.noDevice) != ambiguous)
        #expect(AccessibilityText.speakersReason(nil) == nil)
    }

    @Test func reduceMotionTurnsAnimationOff() {
        #expect(Motion.animation(reduceMotion: true) == nil)
        #expect(Motion.animation(reduceMotion: false) != nil)
        #expect(!Motion.animates(reduceMotion: true) && Motion.animates(reduceMotion: false))
        #expect(Motion.symbolTransition(reduceMotion: true) == ContentTransition.identity)
    }

    @Test func increasedContrastStrengthensWhatSeparatesContent() {
        #expect(ContrastStyle.cardFillOpacity(.increased) > ContrastStyle.cardFillOpacity(.standard))
        #expect(ContrastStyle.cardStrokeOpacity(.increased) > ContrastStyle.cardStrokeOpacity(.standard))
        #expect(ContrastStyle.gridOpacity(.increased) > ContrastStyle.gridOpacity(.standard))
    }

    @Test func theMenuCapFollowsTheScreenButNeverCollapses() {
        #expect(MenuLayout.maxContentHeight(visibleHeight: 900) == 900 - MenuLayout.reserved)
        #expect(MenuLayout.maxContentHeight(visibleHeight: 100) == MenuLayout.minimum)
        #expect(MenuLayout.maxContentHeight(visibleHeight: 1200) > MenuLayout.maxContentHeight(visibleHeight: 800))
    }

    @Test func everySceneSymbolIsSpoken() {
        for symbol in DisplayScene.symbols {
            #expect(!DisplayScene.name(ofSymbol: symbol).isEmpty)
        }
    }
}

/// The new situations, against the real views.
@Suite(.serialized) @MainActor struct AccessibilityRenderTests {
    private func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        if let match = view as? View { return [match] }
        return view.subviews.flatMap { views(type, in: $0) }
    }

    private func menuHeight(_ setup: Setup, cap: CGFloat) -> (height: CGFloat, sliders: Int, scrollers: Int) {
        let host = OffscreenRenderer.host(MenuContentView(manager: setup.manager, maxContentHeight: cap)
            .environment(\.glimStore, setup.store).environment(\.adaptive, setup.adaptive), width: 300, dark: false)
        defer { host.close() }
        return (host.frame.height, views(NSSlider.self, in: host.contentView).count,
                views(NSScrollView.self, in: host.contentView).count)
    }

    /// Three monitors do not fit under a small cap: the panel stops growing
    /// and the list scrolls. One and two monitors are laid out as before.
    @Test func threeMonitorsScrollInsteadOfGrowingPastTheCap() async throws {
        let setup = try await Setup.make(.threeMonitors)
        let uncapped = menuHeight(setup, cap: 10_000)
        let cap: CGFloat = 400
        let capped = menuHeight(setup, cap: cap)
        #expect(uncapped.height > cap + MenuLayout.reserved, "the content is taller than the cap: \(uncapped.height)")
        #expect(capped.height <= cap + MenuLayout.reserved, "panel is \(capped.height) high under a cap of \(cap)")
        #expect(capped.height < uncapped.height)
        #expect(capped.sliders == 9 && uncapped.sliders == 9, "every monitor keeps its three sliders")
        #expect(capped.scrollers >= 1)
        // The cap derived from this machine's screen holds as well.
        let onScreen = menuHeight(setup, cap: MenuLayout.screenCap)
        #expect(onScreen.height <= max(MenuLayout.screenCap + MenuLayout.reserved, uncapped.height))
    }

    @Test(arguments: [Situation.hp, .twoMonitors])
    func fewMonitorsRenderExactlyAsBefore(in situation: Situation) async throws {
        let setup = try await Setup.make(situation)
        let uncapped = menuHeight(setup, cap: 10_000)
        let onScreen = menuHeight(setup, cap: MenuLayout.screenCap)
        #expect(onScreen.height == uncapped.height, "\(situation): \(onScreen.height) against \(uncapped.height)")
        #expect(onScreen.sliders == uncapped.sliders)
    }

    @Test func longNamesDoNotChangeTheMenusSize() async throws {
        let setup = try await Setup.make(.longNames)
        let store = try #require(setup.store)
        let monitor = try #require(setup.manager.monitors.first)
        let scene = try #require(store.scenes.first)
        let long = menuHeight(setup, cap: 10_000)
        store.setName("Desk", for: monitor.id)
        store.rename(scene.id, to: "Day")
        let short = menuHeight(setup, cap: 10_000)
        #expect(long.height == short.height, "long names wrap: \(long.height) against \(short.height)")
        #expect(long.sliders == short.sliders && long.sliders == 4)
    }

    @Test func ambiguousSpeakersLeaveNoVolumeSliderAndSayWhy() async throws {
        let setup = try await Setup.make(.ambiguousSpeakers)
        for monitor in setup.manager.monitors {
            #expect(monitor.volume == nil)
            #expect(AccessibilityText.speakersReason(monitor.audioUnattachedReason) != nil)
        }
        let monitor = try #require(setup.manager.monitors.first)
        let host = OffscreenRenderer.host(MonitorDetailView(manager: setup.manager, monitor: monitor).frame(height: 900),
                                          width: 540, dark: false)
        defer { host.close() }
        // Brightness, contrast and temperature; the HP with speakers has a fourth.
        #expect(OffscreenRenderer.spin(until: { views(NSSlider.self, in: host.contentView).count == 3 }, timeout: 5))
    }

    @Test func aMonitorWithItsSpeakersHasNoReasonToGive() async throws {
        let setup = try await Setup.make(.hp)
        let monitor = try #require(setup.manager.monitors.first)
        #expect(AccessibilityText.speakersReason(monitor.audioUnattachedReason) == nil)
        let host = OffscreenRenderer.host(MonitorDetailView(manager: setup.manager, monitor: monitor).frame(height: 900),
                                          width: 540, dark: false)
        defer { host.close() }
        #expect(OffscreenRenderer.spin(until: { views(NSSlider.self, in: host.contentView).count == 4 }, timeout: 5))
    }

    @Test func pausedAutomaticBrightnessIsSpoken() async throws {
        let setup = try await Setup.make(.adaptivePaused)
        let monitor = try #require(setup.manager.monitors.first)
        let adaptive = try #require(setup.adaptive)
        #expect(adaptive.statuses[monitor.id] == .paused)
        #expect(AccessibilityText.automaticBrightnessSuffix(adaptive.statuses[monitor.id]) == ", automatic brightness paused")
    }

    @Test func aSceneWhoseDisplayIsAwayStaysInTheMenu() async throws {
        let setup = try await Setup.make(.sceneAway)
        let store = try #require(setup.store)
        let scene = try #require(store.scenes.first)
        #expect(scene.connected(in: setup.manager.monitors).isEmpty)
        #expect(!scene.isActive(on: setup.manager.monitors))
        let shown = menuHeight(setup, cap: 10_000)
        let without = menuHeight(Setup.copy(setup, store: GlimStore(defaults: nil)), cap: 10_000)
        #expect(shown.height > without.height, "the scene's row adds height")
        #expect(shown.sliders == 4)
    }

    @Test func hidingEveryDisplayLeavesTheMenuWithoutControls() async throws {
        let setup = try await Setup.make(.allHidden)
        let menu = menuHeight(setup, cap: 10_000)
        #expect(menu.sliders == 0)
        // The window still offers them all.
        let monitor = try #require(setup.manager.monitors.first)
        let host = OffscreenRenderer.host(MonitorDetailView(manager: setup.manager, monitor: monitor)
            .environment(\.glimStore, setup.store).frame(height: 900), width: 540, dark: false)
        defer { host.close() }
        #expect(OffscreenRenderer.spin(until: { views(NSSlider.self, in: host.contentView).count == 4 }, timeout: 5))
    }

    @Test func theWindowKeepsItsActionsReachableAtItsMinimumWidth() async throws {
        let setup = try await Setup.make(.scenes)
        let store = try #require(setup.store)
        let scene = try #require(store.scenes.first)
        let view = SceneDetailView(store: store, manager: setup.manager, scene: scene).frame(width: 440, height: 700)
        let host = OffscreenRenderer.host(view, width: 440, dark: false)
        defer { host.close() }
        // Delete, Duplicate, Save Current Settings and Apply: the symbol
        // picker is a pop-up button too.
        let buttons = views(NSButton.self, in: host.contentView).filter { !($0 is NSPopUpButton) }
        #expect(buttons.count == 4, "found \(buttons.count) buttons")
        // Every one of them lies inside the pane, none clipped.
        for button in buttons {
            let frame = button.convert(button.bounds, to: nil)
            #expect(frame.minX >= -0.5 && frame.maxX <= 440 + 0.5, "a button spans \(frame.minX) to \(frame.maxX)")
        }
    }
}

extension Setup {
    /// The same monitors with another store, for comparing menus.
    @MainActor
    static func copy(_ setup: Setup, store: GlimStore?) -> Setup {
        var copy = setup
        copy.store = store
        return copy
    }
}
