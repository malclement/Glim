import Observation

/// The monitor's color preset. Unlike an input switch, a preset is harmless
/// and undone with one more pick, so a pick is written at once.
@MainActor
@Observable
public final class ColorPresetSelector {
    public let presets: ColorPresets
    let control: DeviceControl<ColorPresetValue>

    public init(presets: ColorPresets, control: DeviceControl<ColorPresetValue>) {
        self.presets = presets
        self.control = control
    }

    public var options: [ColorPresetOption] { presets.options }
    /// What the monitor reports, or the pick being written. nil until read.
    public var value: ColorPresetValue? { control.value }
    public var failure: ControlFailure? { control.failure }
    public var isWriting: Bool { control.isWriting }

    /// The active preset, if it is one of ``options``.
    public var current: ColorPresetOption? {
        control.value.flatMap(presets.option(for:))
    }

    /// The active preset's name, even when it is not one of ``options``.
    public var currentName: String? {
        control.value.map(presets.name(of:))
    }

    /// The preset that restores the factory color, if the monitor has one.
    public var factory: ColorPresetOption? {
        presets.factory.flatMap { factory in options.first { $0.value == factory } }
    }

    public func select(_ option: ColorPresetOption, origin: ChangeOrigin = .user) {
        Log.state.notice("color preset \(option.name, privacy: .public) (0x\(String(option.value, radix: 16), privacy: .public))")
        control.set(.preset(option.value), origin: origin)
    }

    /// Reads the monitor again, unless a pick is being written.
    public func refresh() async {
        await control.refresh()
    }
}
