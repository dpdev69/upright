import SwiftUI

/// Pointer speed (DPI) of one mouse: a slider snapped to the speeds it supports, and the presets
/// that "Cycle Pointer Speed" steps through (shared by every mouse, snapped to each one's speeds).
///
/// The speed set here is kept for that mouse only (`DevicePreferences.preferredDPI`) and applied
/// again whenever it reconnects. Callers hide this section for a mouse without ADJUSTABLE_DPI
/// (0x2201); with no mouse (`address` nil) only the presets can be edited.
struct PointerSpeedSection: View {
    let address: DeviceAddress?
    /// nil while no mouse is selected or connected.
    let dpi: DPIInfo?

    @EnvironmentObject private var model: AppModel
    @State private var draftIndex: Double?
    @State private var newPreset = ""

    init(address: DeviceAddress?, dpi: DPIInfo?) {
        self.address = address
        self.dpi = address == nil ? nil : dpi
    }

    var body: some View {
        Section {
            if let dpi, address != nil {
                speedControls(dpi)
            } else {
                Text("Connect a mouse to change its pointer speed.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pointer Speed")
        } footer: {
            if dpi != nil {
                Text("Upright applies this speed again whenever this mouse reconnects. Other mice keep their own. A pointer-speed button on the mouse can still change it unless you remap that button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section {
            presetRows
                .snapshotAnchor("dpiPresets")
            presetEditor
        } header: {
            Text("Speed Presets")
        } footer: {
            Text("“Cycle Pointer Speed” steps through these speeds on whichever mouse the button belongs to, and each one can be assigned to a button in Buttons. Speeds are rounded to the nearest one that mouse supports.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preset rows

    private var presetRows: some View {
        VStack(spacing: 0) {
            ForEach(model.settings.dpiPresets, id: \.self) { preset in
                LabeledContent {
                    Button {
                        model.settings.dpiPresets.removeAll { $0 == preset }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.settings.dpiPresets.count <= 1)
                    .help("Remove this preset")
                    .accessibilityLabel(Text("Remove \(preset) DPI"))
                } label: {
                    Text("\(preset) DPI")
                }
                .padding(.vertical, 4)
                if preset != model.settings.dpiPresets.last {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var presetEditor: some View {
        HStack {
            TextField("Add a speed", text: $newPreset, prompt: Text("e.g. 1000"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .onSubmit(addPreset)
            Button("Add", action: addPreset)
                .disabled(parsedPreset == nil)
            Spacer()
            if let dpi {
                Button("Use Suggested") {
                    model.settings.dpiPresets = dpi.suggestedPresets()
                }
                .help("Replaces the presets with four speeds spread across what this mouse supports")
            }
        }
        if !newPreset.trimmingCharacters(in: .whitespaces).isEmpty, parsedPreset == nil {
            Text("Enter a number from \(DeviceAction.dpiRange.lowerBound) to \(DeviceAction.dpiRange.upperBound).")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Speed

    @ViewBuilder
    private func speedControls(_ dpi: DPIInfo) -> some View {
        let values = Self.values(for: dpi)
        let currentIndex = Self.index(of: dpi.current, in: values)
        let shownIndex = Int((draftIndex ?? Double(currentIndex)).rounded())
        let shownValue = values[min(max(shownIndex, 0), values.count - 1)]

        LabeledContent {
            HStack(spacing: 10) {
                if values.count > 1 {
                    Slider(
                        value: Binding(
                            get: { draftIndex ?? Double(currentIndex) },
                            set: { draftIndex = $0 }
                        ),
                        in: 0...Double(values.count - 1),
                        step: 1
                    ) {
                        Text("Pointer speed")
                    } onEditingChanged: { editing in
                        guard !editing, let draftIndex else { return }
                        apply(values[Int(draftIndex.rounded())])
                        self.draftIndex = nil
                    }
                    .labelsHidden()
                    .accessibilityValue(Text("\(shownValue) DPI"))
                    .snapshotAnchor("dpiSlider")
                }
                Stepper {
                    Text("\(shownValue) DPI")
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                } onIncrement: {
                    apply(values[min(currentIndex + 1, values.count - 1)])
                } onDecrement: {
                    apply(values[max(currentIndex - 1, 0)])
                }
                .accessibilityLabel(Text("Pointer speed"))
                .accessibilityValue(Text("\(shownValue) DPI"))
            }
            .frame(maxWidth: 360)
        } label: {
            Text("Speed")
        }
        // A half-dragged slider doesn't carry over to another mouse.
        .onChange(of: address) { _ in draftIndex = nil }

        HStack {
            Text("Supported: \(dpi.minimum)–\(dpi.maximum) DPI · Default \(dpi.defaultValue) DPI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Use Default") { apply(dpi.defaultValue) }
                .disabled(dpi.current == dpi.defaultValue)
            if keepsSpeed {
                Button("Let the Mouse Decide") {
                    if let address { model.setPreferredDPI(nil, for: address) }
                }
                .help("Stop reapplying a speed when this mouse reconnects")
            }
        }
    }

    /// This mouse has a speed Upright keeps (its own preference, or its model's seed).
    private var keepsSpeed: Bool {
        guard let address else { return false }
        return model.devicePreferences(for: address).preferredDPI != nil
    }

    /// Sets this mouse's speed and keeps it for this mouse only.
    private func apply(_ value: Int) {
        guard let address else { return }
        model.setPreferredDPI(value, for: address)
    }

    /// The speeds the slider snaps to: what the mouse lists, or steps of 50 within its range.
    private static func values(for dpi: DPIInfo) -> [Int] {
        if !dpi.supported.isEmpty { return dpi.supported }
        let range = DeviceAction.dpiRange
        return Array(stride(from: range.lowerBound, through: range.upperBound, by: 50))
    }

    private static func index(of value: Int, in values: [Int]) -> Int {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }

    // MARK: Presets

    private var parsedPreset: Int? {
        let digits = newPreset.filter { !$0.isWhitespace && $0 != "," && $0 != "." }
        guard let value = Int(digits), DeviceAction.dpiRange.contains(value) else { return nil }
        return value
    }

    private func addPreset() {
        guard var value = parsedPreset else { return }
        if let dpi { value = dpi.nearest(to: value) }
        model.settings.dpiPresets.append(value)
        newPreset = ""
    }
}
