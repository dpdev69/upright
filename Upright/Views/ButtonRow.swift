import SwiftUI

/// One remappable button: what it is, what it does, and a picker to change that.
struct ButtonRow: View {
    let control: ControlDescriptor
    @Binding var action: ButtonAction
    let showsAccessibilityWarning: Bool

    @State private var isRecording = false
    @State private var wantsShortcut = false

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: control.symbolName, color: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(control.name)
                Text(control.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            if showsAccessibilityWarning && action.requiresAccessibility {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs Accessibility access. Until then this button keeps its normal behavior.")
            }

            if case .keyCombo(let combo) = action {
                ShortcutRecorder(combo: combo, isRecording: $isRecording) { action = .keyCombo($0) }
            } else if wantsShortcut {
                ShortcutRecorder(combo: nil, isRecording: $isRecording) { action = .keyCombo($0) }
            }

            ActionMenu(action: $action) {
                wantsShortcut = true
                isRecording = true
            }
            .frame(width: 190)
        }
        .padding(.vertical, 3)
        .onChange(of: isRecording) { recording in
            if !recording { wantsShortcut = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(control.name)
    }
}

/// Pop-up menu listing every action, grouped like the system's own lists.
struct ActionMenu: View {
    @Binding var action: ButtonAction
    let recordShortcut: () -> Void

    var body: some View {
        Menu {
            Picker("Basic", selection: $action) {
                Label("Default", systemImage: "computermouse").tag(ButtonAction.deviceDefault)
                Label("Do Nothing", systemImage: "nosign").tag(ButtonAction.disabled)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            ForEach(SystemAction.Category.allCases, id: \.self) { category in
                Menu(category.rawValue) {
                    Picker(category.rawValue, selection: $action) {
                        ForEach(SystemAction.actions(in: category)) { system in
                            Label(system.title, systemImage: system.symbolName).tag(ButtonAction.system(system))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Divider()
            Button {
                recordShortcut()
            } label: {
                Label("Keyboard Shortcut…", systemImage: "keyboard")
            }
        } label: {
            Label(menuTitle, systemImage: action.symbolName)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(helpText)
    }

    private var menuTitle: String {
        if case .keyCombo = action { return "Keyboard Shortcut" }
        return action.title
    }

    private var helpText: String {
        switch action {
        case .deviceDefault: return "The mouse handles this button itself"
        case .disabled: return "The button is ignored"
        case .system(let system): return system.title
        case .keyCombo(let combo): return "Sends \(combo.displayString)"
        }
    }
}
