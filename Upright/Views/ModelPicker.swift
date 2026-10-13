import SwiftUI

/// Chooses which mouse model the Buttons pane configures.
///
/// Wave 0 scaffold: W5.2 owns this file (connected, then remembered, then catalog models).
struct ModelPicker: View {
    let models: [ModelKey]
    @Binding var selection: ModelKey

    var body: some View {
        Picker(selection: $selection) {
            ForEach(models, id: \.self) { model in
                Text(verbatim: DeviceCatalog.model(model)?.name ?? model.rawValue).tag(model)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
    }
}
