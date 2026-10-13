import SwiftUI

/// Edits the five slots of a gesture button: a click and a hold-and-move in each direction.
struct GestureEditor: View {
    @Binding var gestures: GestureSet
    private let title: String?

    init(gestures: Binding<GestureSet>, title: String? = nil) {
        _gestures = gestures
        self.title = title
    }

    var body: some View {
        Section {
            row("Click", symbol: "hand.tap", selection: $gestures.tap)
            ForEach(GestureDirection.allCases, id: \.self) { direction in
                row(direction.label, symbol: direction.symbolName, selection: $gestures[direction])
            }
        } header: {
            if let title {
                Text("Gestures: \(title)")
            }
        } footer: {
            Text("Hold the button and move the mouse to trigger a direction. Click it without moving to trigger Click.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: LocalizedStringKey, symbol: String, selection: Binding<ButtonAction>) -> some View {
        LabeledContent {
            ActionPicker(selection: selection, allowsGestures: false)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

private extension GestureDirection {
    var label: LocalizedStringKey {
        switch self {
        case .up: return "Move Up"
        case .down: return "Move Down"
        case .left: return "Move Left"
        case .right: return "Move Right"
        }
    }
}
