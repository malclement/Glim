import AppKit

/// Whether Glim is in the Dock.
///
/// Glim is a menu bar app first: `LSUIElement` keeps it out of the Dock at
/// launch. It joins the Dock while its window is open, always when the
/// settings say so, and whenever its menu bar icon is hidden, because then
/// the Dock is the only way back to it. Being in the Dock is the `.regular`
/// activation policy, which also gives Glim its menus in the menu bar.
@MainActor
final class AppPresence {
    /// Set by the main window as it opens and closes.
    var isWindowOpen = false {
        didSet { apply() }
    }

    private let defaults: UserDefaults
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var isStarted = false
    private var appliedPolicy: NSApplication.ActivationPolicy?

    init(defaults: UserDefaults = .standard,
         setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }) {
        self.defaults = defaults
        self.setPolicy = setPolicy
    }

    /// Whether Glim belongs in the Dock right now.
    var showsDockIcon: Bool {
        Self.showsDockIcon(isWindowOpen: isWindowOpen,
                           alwaysShowDockIcon: defaults.alwaysShowDockIcon,
                           showsMenuBarIcon: defaults.showMenuBarIcon)
    }

    nonisolated static func showsDockIcon(isWindowOpen: Bool, alwaysShowDockIcon: Bool, showsMenuBarIcon: Bool) -> Bool {
        isWindowOpen || alwaysShowDockIcon || !showsMenuBarIcon
    }

    /// Applies the policy, and keeps applying it as the window and the
    /// settings change. Nothing is applied before this, so a test can drive an
    /// instance without touching its own process.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Called on the thread that changed the value, which for
        // `defaults write` is not necessarily the main one.
        let changed: @Sendable (UserDefaults, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
        observations = [
            defaults.observe(\.showMenuBarIcon, changeHandler: changed),
            defaults.observe(\.alwaysShowDockIcon, changeHandler: changed),
        ]
        apply()
    }

    private func apply() {
        guard isStarted else { return }
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard policy != appliedPolicy else { return }
        appliedPolicy = policy
        AppLog.app.info("\(policy == .regular ? "in the Dock" : "menu bar only", privacy: .public)")
        setPolicy(policy)
    }
}
