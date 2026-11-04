import Observation

/// The monitor's video input.
///
/// Switching away from the input this Mac is on takes the picture away from
/// it, possibly to a port with nothing connected. So a selection is only
/// staged by ``request(_:)``, and nothing is sent until ``confirm()``.
@MainActor
@Observable
public final class InputSelector {
    public let options: [InputOption]
    public let control: DeviceControl<UInt16>
    /// The input picked but not yet confirmed.
    public private(set) var pendingSelection: InputOption?

    public init(options: [InputOption], control: DeviceControl<UInt16>) {
        self.options = options
        self.control = control
    }

    /// The active input, if it is one of ``options``.
    public var current: InputOption? {
        guard let value = control.value else { return nil }
        return options.first { $0.value == value }
    }

    /// The active input's name, even when it is not one of ``options``.
    public var currentName: String? {
        current?.name ?? control.value.map(InputSourceNames.name(for:))
    }

    /// Stages a switch for confirmation. Picking the active input clears it.
    public func request(_ option: InputOption) {
        pendingSelection = option.value == control.value ? nil : option
    }

    /// Sends the staged switch.
    public func confirm() {
        guard let option = pendingSelection else { return }
        pendingSelection = nil
        Log.state.notice("switching input to \(option.name, privacy: .public) (0x\(String(option.value, radix: 16), privacy: .public))")
        control.set(option.value)
    }

    public func cancel() {
        pendingSelection = nil
    }
}
