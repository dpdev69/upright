import SwiftUI

/// One remappable button in a model's global table: what it is, what it does, and a picker to
/// change that. `control` carries the model's own wording (`ControlDescriptor(cid:model:)`).
struct ButtonRow: View {
    let control: ControlDescriptor
    @Binding var action: ButtonAction
    let showsAccessibilityWarning: Bool
    var isHighlighted = false
    var note: Text?

    @Environment(\.actionTarget) private var target

    var body: some View {
        ControlRowLayout(control: control, isHighlighted: isHighlighted, note: note) {
            if showsAccessibilityWarning && action.requiresAccessibility {
                AccessibilityWarningIcon()
            }
            if !target.supports(action) {
                UnsupportedActionIcon(deviceName: target.deviceName)
            }
            ActionPicker(selection: $action)
        }
    }
}

/// A button in an app profile: either inherits the global action or overrides it.
struct AppOverrideRow: View {
    let control: ControlDescriptor
    /// nil inherits the global mapping.
    @Binding var override: ButtonAction?
    let globalAction: ButtonAction
    let showsAccessibilityWarning: Bool
    var isHighlighted = false
    var note: Text?

    @Environment(\.actionTarget) private var target

    var body: some View {
        ControlRowLayout(control: control, isHighlighted: isHighlighted, note: note) {
            if let current = override {
                if showsAccessibilityWarning && current.requiresAccessibility {
                    AccessibilityWarningIcon()
                }
                if !target.supports(current) {
                    UnsupportedActionIcon(deviceName: target.deviceName)
                }
                ActionPicker(selection: Binding(
                    get: { override ?? current },
                    set: { override = $0 }
                ))
                Button {
                    override = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use the global action again")
                .accessibilityLabel(Text("Use Global Action"))
            } else {
                Text("Global: \(globalAction.title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(globalAction.helpText)
                Button("Override") {
                    override = globalAction
                }
                .help("Give this button a different action in this app")
            }
        }
    }
}

/// Icon, name and detail of a control, with trailing content. Briefly tinted while highlighted
/// (the button was just pressed).
struct ControlRowLayout<Trailing: View>: View {
    let control: ControlDescriptor
    let isHighlighted: Bool
    var note: Text?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: control.symbolName, color: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(control.name)
                Text(control.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    note
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.18 : 0))
                .padding(.horizontal, -6)
        )
        .animation(.easeOut(duration: 0.35), value: isHighlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(control.name)
    }
}

struct AccessibilityWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("Needs Accessibility access. Until then this button keeps its normal behavior.")
            .accessibilityLabel(Text("Needs Accessibility access"))
    }
}

/// Shown next to a device action the mouse being set up can't carry out (an Easy-Switch channel
/// it doesn't have, a speed outside its range, or pointer speed on a mouse without it).
struct UnsupportedActionIcon: View {
    let deviceName: String?

    var body: some View {
        Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    private var help: String {
        if let deviceName {
            return String(localized: "\(deviceName) can’t do this, so the button does nothing on it.")
        }
        return String(localized: "This mouse can’t do this, so the button does nothing on it.")
    }
}
