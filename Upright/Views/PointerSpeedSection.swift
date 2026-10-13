import SwiftUI

/// Pointer speed (DPI): a slider snapped to the speeds the mouse supports, and the presets that
/// "Cycle Pointer Speed" steps through.
struct PointerSpeedSection: View {
    /// nil while no mouse is connected; only the presets can be edited then.
    let dpi: DPIInfo?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @State private var draftIndex: Double?
    @State private var newPreset = ""

    var body: some View {
        Section {
            if let dpi {
                speedControls(dpi)
            } else {
                Text("Connect the mouse to change its pointer speed.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pointer Speed")
        } footer: {
            if dpi != nil {
                Text("Upright applies this speed again whenever the mouse reconnects. The top button can still change it unless you remap that button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section {
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
            }
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
                    .help("Four speeds spread across what this mouse supports")
                }
            }
            if !newPreset.trimmingCharacters(in: .whitespaces).isEmpty, parsedPreset == nil {
                Text("Enter a number from \(DeviceAction.dpiRange.lowerBound) to \(DeviceAction.dpiRange.upperBound).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Speed Presets")
        } footer: {
            Text("“Cycle Pointer Speed” steps through these speeds, and each one can be assigned to a button in Buttons. Speeds are rounded to the nearest one the mouse supports.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

        HStack {
            Text("Supported: \(dpi.minimum)–\(dpi.maximum) DPI · Default \(dpi.defaultValue) DPI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Use Default") { apply(dpi.defaultValue) }
                .disabled(dpi.current == dpi.defaultValue)
            if devices.desiredDPI != nil {
                Button("Let the Mouse Decide") { devices.setDesiredDPI(nil) }
                .help("Stop reapplying a speed when the mouse reconnects")
            }
        }
    }

    /// AppModel saves the kept speed (settings.preferredDPI) from DeviceManager.desiredDPI.
    private func apply(_ value: Int) {
        devices.setDPI(value)
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
