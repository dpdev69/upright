import AppKit
import SwiftUI

/// A button that records the next key combination typed while it's active.
/// Escape cancels; the recorded label comes from the active keyboard layout.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isRecording ? "record.circle" : "keyboard")
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                Text(label)
                    .font(.system(.body, design: combo == nil || isRecording ? .default : .rounded).weight(.medium))
                    .foregroundStyle(isRecording ? .secondary : .primary)
            }
            .frame(minWidth: 110)
        }
        .help(isRecording ? "Type a shortcut, or press Escape to cancel" : "Click to record a new shortcut")
        .onAppear { if isRecording { startMonitoring() } }
        .onChange(of: isRecording) { recording in
            recording ? startMonitoring() : stopMonitoring()
        }
        .onDisappear { stopMonitoring() }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return combo?.displayString ?? "Record Shortcut"
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == KeyCode.escape && flags.subtracting([.function, .numericPad]).isEmpty {
            isRecording = false
            return
        }

        var modifiers = KeyModifiers()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        onRecord(KeyCombo(keyCode: event.keyCode, modifiers: modifiers, keyLabel: Self.label(for: event)))
        isRecording = false
    }

    private static func label(for event: NSEvent) -> String {
        if KeyCode.isLayoutIndependent(event.keyCode), let label = KeyCode.label(for: event.keyCode) {
            return label
        }
        let typed = event.characters(byApplyingModifiers: [])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return typed.uppercased()
        }
        return KeyCode.label(for: event.keyCode) ?? "Key \(event.keyCode)"
    }
}
