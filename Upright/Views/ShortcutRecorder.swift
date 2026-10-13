import AppKit
import SwiftUI

/// A button that records the next key combination typed while it's active.
///
/// Only one recorder records at a time, app-wide. While recording: Escape cancels, Delete clears
/// (when `onClear` is given), and held modifiers show live. A shortcut needs ⌘, ⌃ or ⌥ unless
/// its key is a function or navigation key. Recording stops when the window loses focus or closes.
/// The recorded label comes from the active keyboard layout.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void
    var onClear: (() -> Void)?

    init(combo: KeyCombo?, isRecording: Binding<Bool>, onRecord: @escaping (KeyCombo) -> Void, onClear: (() -> Void)? = nil) {
        self.combo = combo
        _isRecording = isRecording
        self.onRecord = onRecord
        self.onClear = onClear
    }

    @ObservedObject private var coordinator = ShortcutRecordingCoordinator.shared
    @State private var id = UUID()
    @State private var session = RecorderSession()
    @State private var liveModifiers = KeyModifiers()
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button {
                isRecording.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    Text(label)
                        .font(.system(.body, design: combo == nil || isRecording ? .default : .rounded).weight(.medium))
                        .foregroundStyle(isRecording && liveModifiers.isEmpty ? .secondary : .primary)
                }
                .frame(minWidth: 110)
            }
            .help(isRecording ? helpWhileRecording : String(localized: "Click to record a new shortcut"))
            .accessibilityLabel(Text("Keyboard shortcut"))
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isRecording ? helpWhileRecording : String(localized: "Records a new shortcut"))

            if let caption {
                Text(caption.text)
                    .font(.caption)
                    .foregroundStyle(caption.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .background(WindowReader { session.window = $0 })
        .onAppear { if isRecording { start() } }
        .onChange(of: isRecording) { recording in
            recording ? start() : stop()
        }
        .onChange(of: coordinator.activeID) { activeID in
            // Another recorder started.
            if isRecording, let activeID, activeID != id { isRecording = false }
        }
        .onDisappear {
            if isRecording { isRecording = false }
            stop()
        }
    }

    // MARK: Display

    private var label: String {
        if isRecording {
            return liveModifiers.isEmpty ? String(localized: "Type shortcut…") : liveModifiers.symbols + "…"
        }
        return combo?.displayString ?? String(localized: "Record Shortcut")
    }

    private var helpWhileRecording: String {
        onClear == nil
            ? String(localized: "Type a shortcut, or press Escape to cancel")
            : String(localized: "Type a shortcut. Escape cancels, Delete clears.")
    }

    private var accessibilityValue: String {
        if isRecording {
            return String(localized: "Recording")
        }
        return combo?.spokenDescription ?? String(localized: "None")
    }

    private var caption: (text: String, isWarning: Bool)? {
        if isRecording {
            return (hint ?? String(localized: "Include ⌘, ⌃ or ⌥, or use a function key"), hint != nil)
        }
        if let combo, let warning = ReservedShortcuts.warning(for: combo) {
            return (warning, true)
        }
        return nil
    }

    // MARK: Recording

    private func start() {
        coordinator.begin(id)
        hint = nil
        liveModifiers = []
        session.start(
            onEvent: { event in handle(event) },
            onInterrupt: { if isRecording { isRecording = false } }
        )
        announce(String(localized: "Recording shortcut. Type a key combination."))
    }

    private func stop() {
        session.stop()
        coordinator.end(id)
        liveModifiers = []
        hint = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = KeyModifiers(flags)

        if event.type == .flagsChanged {
            liveModifiers = modifiers
            return false
        }
        guard event.type == .keyDown else { return false }

        if modifiers.isEmpty {
            switch event.keyCode {
            case KeyCode.escape:
                isRecording = false
                return true
            case KeyCode.delete:
                if let onClear {
                    onClear()
                    announce(String(localized: "Shortcut cleared"))
                }
                isRecording = false
                return true
            default:
                break
            }
        }

        let candidate = KeyCombo(keyCode: event.keyCode, modifiers: modifiers, keyLabel: Self.label(for: event))
        guard ShortcutValidation.isAcceptable(candidate) else {
            let message = String(localized: "\(candidate.displayString) needs ⌘, ⌃ or ⌥ — or use a function key")
            hint = message
            NSSound.beep()
            announce(message)
            return true
        }

        onRecord(candidate)
        isRecording = false
        announce(String(localized: "Recorded \(candidate.spokenDescription)"))
        return true
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
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

/// Makes sure only one recorder listens for keys at a time.
@MainActor
final class ShortcutRecordingCoordinator: ObservableObject {
    static let shared = ShortcutRecordingCoordinator()

    @Published private(set) var activeID: UUID?

    func begin(_ id: UUID) {
        if activeID != id { activeID = id }
    }

    func end(_ id: UUID) {
        if activeID == id { activeID = nil }
    }
}

/// Owns the key monitor and window observers of one recorder, and removes them however the
/// recorder goes away (stop, disappear, or deallocation).
@MainActor
private final class RecorderSession {
    weak var window: NSWindow? {
        didSet { if tokens.hasMonitor, window !== oldValue { observeWindow() } }
    }

    private let tokens = ListenerTokens()
    private var onInterrupt: (() -> Void)?

    func start(onEvent: @escaping (NSEvent) -> Bool, onInterrupt: @escaping () -> Void) {
        stop()
        self.onInterrupt = onInterrupt
        tokens.setMonitor(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            onEvent(event) ? nil : event
        })
        observeWindow()
    }

    func stop() {
        tokens.removeMonitor()
        tokens.removeObservers()
        onInterrupt = nil
    }

    private func observeWindow() {
        tokens.removeObservers()
        let center = NotificationCenter.default
        var names: [(Notification.Name, AnyObject?)] = [(NSApplication.didResignActiveNotification, NSApp)]
        if let window {
            names.append((NSWindow.didResignKeyNotification, window))
            names.append((NSWindow.willCloseNotification, window))
        }
        for (name, object) in names {
            tokens.addObserver(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActorDelivery.run { self?.interrupt() }
            })
        }
    }

    private func interrupt() {
        let handler = onInterrupt
        stop()
        handler?()
    }
}

enum ShortcutValidation {
    /// A shortcut a button can usefully send: it has ⌘, ⌃ or ⌥, or its key is a function,
    /// navigation or Help key. Bare letters, Return, Space and the like are rejected.
    static func isAcceptable(_ combo: KeyCombo) -> Bool {
        !combo.modifiers.intersection([.command, .control, .option]).isEmpty || combo.carriesFunctionFlag
    }
}

/// Well-known system shortcuts. Recording one is allowed, but the user is told what it does.
/// (Some, like ⌘Tab and ⌘Space, are taken by macOS before the recorder sees them; pick the
/// matching action from the action menu instead.)
enum ReservedShortcuts {
    static func warning(for combo: KeyCombo) -> String? {
        let m = combo.modifiers
        switch (combo.keyCode, m) {
        case (KeyCode.tab, [.command]), (KeyCode.tab, [.command, .shift]):
            return String(localized: "⌘Tab switches apps")
        case (KeyCode.space, [.command]):
            return String(localized: "⌘Space opens Spotlight")
        case (KeyCode.three, [.command, .shift]), (KeyCode.four, [.command, .shift]), (KeyCode.five, [.command, .shift]):
            return String(localized: "This is a macOS screenshot shortcut")
        case (KeyCode.q, [.command]):
            return String(localized: "⌘Q quits the frontmost app")
        case (KeyCode.w, [.command]):
            return String(localized: "⌘W closes the frontmost window")
        case (KeyCode.q, [.command, .control]):
            return String(localized: "⌃⌘Q locks the screen")
        case (KeyCode.escape, [.command, .option]):
            return String(localized: "⌥⌘Esc opens Force Quit")
        default:
            return nil
        }
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

extension KeyCombo {
    /// For VoiceOver: "Command Shift 4" instead of "⌘⇧4".
    var spokenDescription: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append(String(localized: "Control")) }
        if modifiers.contains(.option) { words.append(String(localized: "Option")) }
        if modifiers.contains(.shift) { words.append(String(localized: "Shift")) }
        if modifiers.contains(.command) { words.append(String(localized: "Command")) }
        words.append(Self.spokenKey(keyCode: keyCode) ?? keyLabel)
        return words.joined(separator: " ")
    }

    private static func spokenKey(keyCode: UInt16) -> String? {
        switch keyCode {
        case KeyCode.returnKey: return String(localized: "Return")
        case KeyCode.tab: return String(localized: "Tab")
        case KeyCode.space: return String(localized: "Space")
        case KeyCode.delete: return String(localized: "Delete")
        case KeyCode.forwardDelete: return String(localized: "Forward Delete")
        case KeyCode.escape: return String(localized: "Escape")
        case KeyCode.leftArrow: return String(localized: "Left Arrow")
        case KeyCode.rightArrow: return String(localized: "Right Arrow")
        case KeyCode.upArrow: return String(localized: "Up Arrow")
        case KeyCode.downArrow: return String(localized: "Down Arrow")
        case KeyCode.home: return String(localized: "Home")
        case KeyCode.end: return String(localized: "End")
        case KeyCode.pageUp: return String(localized: "Page Up")
        case KeyCode.pageDown: return String(localized: "Page Down")
        default: return nil
        }
    }
}
