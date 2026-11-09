import GlimCore
import SwiftUI

/// Everything about one monitor: its controls, what Glim knows about it, and
/// diagnostics. The window shows every control the monitor offers; the
/// settings that hide rows apply to the menu only.
struct MonitorDetailView: View {
    let manager: MonitorManager
    let monitor: Monitor
    @Environment(\.glimStore) private var store

    var body: some View {
        Form {
            Section {
                MonitorHeader(monitor: monitor, title: store?.title(for: monitor, in: manager) ?? manager.title(for: monitor))
            }
            MonitorControls(monitor: monitor)
                .labelStyle(IconColumnLabelStyle())
            if let store {
                MenuChoices(store: store, monitor: monitor)
            }
            Section("Display") {
                if let store {
                    DisplayNameField(store: store, monitor: monitor, defaultName: manager.title(for: monitor))
                }
                LabeledContent("Model", value: monitor.name)
                if let identity = monitor.identity {
                    LabeledContent("EDID", value: MonitorText.edid(identity))
                }
                LabeledContent("Profile", value: MonitorText.profile(monitor.profile))
                LabeledContent("Speakers", value: MonitorText.speakers(of: monitor))
            }
            Section {
                HStack {
                    Spacer()
                    CopyDiagnosticsButton(manager: manager)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Diagnostics list what Glim found and what each control reads, without serial numbers. Attach them to a bug report.")
                    .foregroundStyle(.secondary)
                    // A grouped form aligns wrapped lines to the trailing edge.
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// A name of the user's own. Blank goes back to Glim's, which is the
/// placeholder.
private struct DisplayNameField: View {
    let store: GlimStore
    let monitor: Monitor
    let defaultName: String
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name, prompt: Text(defaultName))
            .onAppear { name = store.preferences(for: monitor.id).name ?? "" }
            .onChange(of: name) { _, new in store.setName(new, for: monitor.id) }
    }
}

/// What this display shows in the menu: whether it shows at all, and which
/// of its rows. Each choice follows Settings until it is changed here.
private struct MenuChoices: View {
    let store: GlimStore
    let monitor: Monitor
    @AppStorage(Preferences.showContrast) private var showContrast = true
    @AppStorage(Preferences.showColor) private var showColor = true
    @AppStorage(Preferences.showVolume) private var showVolume = true
    @AppStorage(Preferences.showInput) private var showInput = true

    private func settingsDefault(_ row: MenuRow) -> Bool {
        switch row {
        case .contrast: showContrast
        case .color: showColor
        case .volume: showVolume
        case .input: showInput
        }
    }

    private var rows: [MenuRow] { MenuRow.allCases.filter { $0.isOffered(by: monitor) } }

    var body: some View {
        let preferences = store.preferences(for: monitor.id)
        Section {
            Toggle("Show this display", isOn: Binding(
                get: { store.showsInMenu(monitor.id) },
                set: { shown in store.updateDisplay(monitor.id) { $0.showsInMenu = shown ? nil : false } }
            ))
            if store.showsInMenu(monitor.id) {
                ForEach(rows, id: \.self) { row in
                    Toggle(row.title, isOn: Binding(
                        get: { store.shows(row, for: monitor.id, default: settingsDefault(row)) },
                        set: { store.setShows(row, $0, for: monitor.id) }
                    ))
                }
            }
        } header: {
            Text("In the menu")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Brightness is always shown. Rows you haven't changed here follow Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !preferences.rows.isEmpty || preferences.showsInMenu != nil {
                    Button("Use Settings") { store.resetMenu(for: monitor.id) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The monitor's name and status.
private struct MonitorHeader: View {
    let monitor: Monitor
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(MonitorText.status(monitor.status))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if monitor.status == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            }
            if !monitor.profile.isTested {
                Label("Untested", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Glim hasn't been tested with this display. Its controls come from the display's own description.")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The controls, as form sections: picture, color, sound, input. Mirrors the
/// menu's rules: while the monitor doesn't answer, its DDC/CI controls make
/// way for a retry, and USB speakers, a separate device, stay.
private struct MonitorControls: View {
    let monitor: Monitor

    var body: some View {
        switch monitor.status {
        case .notResponding:
            Section("Controls") {
                NotRespondingView(monitor: monitor)
            }
            if monitor.hasUSBSpeakers, let volume = monitor.volume {
                Section("Sound") {
                    VolumeControls(volume: volume, mute: monitor.mute)
                }
            }
        case .connecting, .ready:
            if !monitor.hasControls {
                Section("Controls") {
                    Text(monitor.status == .connecting ? "Reading the display…" : "This display doesn't offer any control Glim supports.")
                        .foregroundStyle(.secondary)
                }
            }
            if monitor.brightness != nil || monitor.contrast != nil {
                Section("Picture") {
                    if let brightness = monitor.brightness {
                        LevelControl(title: "Brightness", symbol: "sun.max", control: brightness)
                    }
                    if let contrast = monitor.contrast {
                        LevelControl(title: "Contrast", symbol: "circle.lefthalf.filled", control: contrast)
                    }
                }
            }
            if monitor.colorTemperature != nil || monitor.colorPreset != nil {
                Section("Color") {
                    if let temperature = monitor.colorTemperature {
                        LabeledContent {
                            ColorTemperatureSlider(monitor: monitor, control: temperature)
                        } label: {
                            Label("Temperature", systemImage: "thermometer.medium")
                        }
                    }
                    if let preset = monitor.colorPreset {
                        ColorPresetControl(selector: preset)
                    }
                }
            }
            if let volume = monitor.volume {
                Section("Sound") {
                    VolumeControls(volume: volume, mute: monitor.mute)
                }
            }
            if let input = monitor.input {
                Section("Input") {
                    InputControl(selector: input, isTested: monitor.profile.isTested(.input))
                }
            }
        }
    }
}

private struct LevelControl: View {
    let title: String
    let symbol: String
    let control: DeviceControl<Double>

    var body: some View {
        LabeledContent {
            LevelSlider(title: title, control: control)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// The color preset. The factory preset doubles as the reset.
private struct ColorPresetControl: View {
    let selector: ColorPresetSelector

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let failure = selector.failure {
                    FailureBadge(failure: failure)
                }
                ColorPresetPicker(selector: selector)
                FactoryColorButton(selector: selector)
            }
        } label: {
            Label("Preset", systemImage: "paintpalette")
        }
    }
}

/// Volume, and mute as a switch of its own.
private struct VolumeControls: View {
    let volume: DeviceControl<Double>
    let mute: DeviceControl<Bool>?

    var body: some View {
        LabeledContent {
            LevelSlider(title: "Volume", control: volume)
        } label: {
            Label("Volume", systemImage: speakerSymbol(volume: volume, isMuted: mute?.value == true))
        }
        if let mute {
            // A warning sits beside the control it concerns, as on the other
            // rows.
            LabeledContent {
                HStack(spacing: 6) {
                    if let failure = mute.failure {
                        FailureBadge(failure: failure)
                    }
                    Toggle("Mute", isOn: Binding(get: { mute.value ?? false }, set: { mute.set($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(mute.value == nil)
                }
            } label: {
                Label("Mute", systemImage: "speaker.slash")
            }
        }
    }
}

/// Puts every symbol in a column of one width, as the menu's rows do, so the
/// titles line up whichever symbol is wider.
private struct IconColumnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 20)
            configuration.title
        }
    }
}

/// The input, with the same confirmation as in the menu.
private struct InputControl: View {
    let selector: InputSelector
    /// Whether switching inputs was ever tried on this model.
    let isTested: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let failure = selector.failure {
                    FailureBadge(failure: failure)
                }
                InputPicker(selector: selector)
            }
        } label: {
            Label("Input", systemImage: "cable.connector")
        }
        if let pending = selector.pendingSelection {
            InputConfirmation(selector: selector, target: pending, isTested: isTested)
        }
    }
}
