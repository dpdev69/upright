import SwiftUI

/// The mouse models a setup can be made for, grouped the way the pickers list them: models with
/// a mouse here now, then models seen before, then every other model (ones with a saved setup
/// and the catalog's), so a mouse can be set up before it arrives.
@MainActor
struct ModelChoices {
    var connected: [ModelKey]
    var remembered: [ModelKey]
    var other: [ModelKey]

    /// `including` is always listed (under "Other models" when it is nowhere else).
    init(model: AppModel, including selection: ModelKey? = nil) {
        connected = model.connectedModels
        let present = Set(connected)
        remembered = model.rememberedModels.filter { !present.contains($0) }
        let listed = present.union(remembered)
        var seen = listed
        var others = (Array(model.library.models.keys) + DeviceCatalog.models.map(\.key))
            .filter { seen.insert($0).inserted }
        if let selection, !seen.contains(selection) { others.append(selection) }
        other = others.sorted { model.modelName($0).localizedStandardCompare(model.modelName($1)) == .orderedAscending }
    }

    var all: [ModelKey] { connected + remembered + other }
}

/// Chooses which mouse model a setup is for ("Configure: [model ▾]"). Editing a model's
/// setup never changes another model's.
struct ModelPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: ModelKey
    var label: Text = Text("Configure")

    var body: some View {
        let choices = ModelChoices(model: model, including: selection)
        Picker(selection: $selection) {
            if !choices.connected.isEmpty {
                Section {
                    ForEach(choices.connected, id: \.self) { key in
                        item(key, units: unitCount(of: key))
                    }
                } header: {
                    Text("Connected")
                }
            }
            if !choices.remembered.isEmpty {
                Section {
                    ForEach(choices.remembered, id: \.self) { key in
                        item(key, units: 0)
                    }
                } header: {
                    Text("Seen Before")
                }
            }
            if !choices.other.isEmpty {
                Section {
                    ForEach(choices.other, id: \.self) { key in
                        item(key, units: 0)
                    }
                } header: {
                    Text("Other Models")
                }
            }
        } label: {
            label
        }
        .accessibilityValue(Text(verbatim: model.modelName(selection)))
    }

    @ViewBuilder
    private func item(_ key: ModelKey, units: Int) -> some View {
        let name = model.modelName(key)
        Group {
            if units > 1 {
                Text("\(name) (\(units) mice)")
            } else {
                Text(verbatim: name)
            }
        }
        .tag(key)
    }

    /// Mice of a model being served now (one per unit: a mouse on two links counts once).
    private func unitCount(of key: ModelKey) -> Int {
        model.devices.records.filter { $0.model == key && $0.role == .active }.count
    }
}
