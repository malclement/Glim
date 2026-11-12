import AppKit
import GlimCore
import SwiftUI

/// The words VoiceOver gets where the picture says it with a glyph, a colour
/// or position. Pure, so tests can read them: the accessibility tree is not
/// built without an assistive client.
enum AccessibilityText {
    /// Spoken when an input switch is staged.
    static func inputConfirmation(target: String) -> String {
        "Switch to \(target)? Cancel or Switch."
    }

    static let inputConfirmationLabel = "Confirm input switch"

    /// What the brightness slider says about automatic brightness, appended
    /// to its value.
    static func automaticBrightnessSuffix(_ status: AdaptiveStatus?) -> String {
        switch status {
        case .following?: ", adjusting automatically"
        case .paused?: ", automatic brightness paused"
        default: ""
        }
    }

    static func kelvin(_ value: Int) -> String { "\(value) kelvin" }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) percent" }

    /// A control's value as spoken, with the failure that concerns it.
    static func value(_ shown: String, failure: String?) -> String {
        failure.map { "\(shown). \($0)" } ?? shown
    }

    /// The temperature as spoken: "4500 K" becomes "4500 kelvin".
    static func spokenTemperature(_ shown: String) -> String {
        guard shown.hasSuffix(" K") else { return shown }
        return String(shown.dropLast(2)) + " kelvin"
    }

    /// Where the display is on the curve, to follow its description.
    static func curveReading(source: AdaptiveSettings.Source, reading: Double?, brightness: Double?) -> String {
        var parts: [String] = []
        if let reading {
            switch source {
            case .lightSensor:
                // The reading is log10(lux + 1).
                parts.append("Light now about \(Int((pow(10, reading) - 1).rounded())) lux")
            case .followBuiltIn:
                parts.append("MacBook screen at \(Int((reading * 100).rounded())) percent")
            case .schedule:
                break
            }
        }
        if let brightness {
            parts.append("display at \(Int((brightness * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }

    /// The hint on a scene whose displays are all away.
    static let awayScene = "None of this scene's displays is connected."

    static func warningLabel(_ message: String) -> String { "Warning: \(message)" }

    /// Why a display has no volume control, as the window words it.
    static func speakersReason(_ reason: Monitor.AudioUnattachedReason?) -> String? {
        switch reason {
        case .ambiguous?:
            "Glim can't tell which speakers belong to this display while two similar displays, or one it can't identify, are connected."
        case .noDevice?:
            "No USB speakers were found for this display."
        case nil:
            nil
        }
    }
}

/// Animation that honours Reduce Motion.
enum Motion {
    /// Whether transitions and animated symbol changes play.
    static func animates(reduceMotion: Bool) -> Bool { !reduceMotion }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        animates(reduceMotion: reduceMotion) ? .opacity.combined(with: .move(edge: .top)) : .identity
    }

    static func symbolTransition(reduceMotion: Bool) -> ContentTransition {
        animates(reduceMotion: reduceMotion) ? .symbolEffect(.replace) : .identity
    }
}

/// Strokes and fills that separate content, stronger under Increase
/// Contrast.
enum ContrastStyle {
    static func cardFillOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 1 : 0.5
    }

    /// 0 draws no outline.
    static func cardStrokeOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.6 : 0
    }

    static func gridOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.6 : 0.25
    }
}

/// How tall the menu's monitor list may grow before it scrolls.
enum MenuLayout {
    /// The footer, the panel's padding and a margin to the screen's edges.
    static let reserved: CGFloat = 200
    static let minimum: CGFloat = 240

    /// The largest height of the monitors and scenes, for a screen whose
    /// usable height is `visibleHeight`.
    static func maxContentHeight(visibleHeight: CGFloat) -> CGFloat {
        max(minimum, visibleHeight - reserved)
    }

    @MainActor
    static var screenCap: CGFloat {
        maxContentHeight(visibleHeight: NSScreen.main?.visibleFrame.height ?? 800)
    }
}

/// Offers its content at most `maxHeight`, and scrolls it only when it needs
/// more. Content that fits is laid out exactly as without the wrapper.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        CapLayout(maxHeight: maxHeight) {
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct CapLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
