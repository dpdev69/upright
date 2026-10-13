import AppKit
import CoreGraphics

/// Turns action effects into synthetic input. Keyboard, media-key and mouse events are posted
/// to the HID event tap, which requires Accessibility access.
@MainActor
final class SystemActionPerformer: ActionPerforming {
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Kept until `open` exits so LaunchServices processes are reaped instead of left as zombies.
    private var launches: [Process] = []

    func perform(_ effect: ActionEffect, phase: ActionPhase) {
        switch effect {
        case .keyCombo(let combo):
            postKey(combo, down: phase == .down)
        case .mouseButton(let button):
            postMouseButton(button, down: phase == .down)
        case .media(let key):
            if phase == .down { postMediaKey(key) }
        case .missionControl(let mode):
            if phase == .down { openMissionControl(mode) }
        }
    }

    private func postKey(_ combo: KeyCombo, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: down) else { return }
        var flags = CGEventFlags()
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.isNavigationKey {
            flags.insert(.maskSecondaryFn)
            flags.insert(.maskNumericPad)
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postMouseButton(_ button: SyntheticMouseButton, down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: down ? .otherMouseDown : .otherMouseUp,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.post(tap: .cghidEventTap)
    }

    /// Media keys are NSSystemDefined events (subtype 8) carrying the NX_KEYTYPE in data1.
    private func postMediaKey(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key.rawValue << 16) | state,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func openMissionControl(_ mode: MissionControlMode) {
        // Mission Control.app is arm64e-only. Executing it from this arm64 app is
        // killed immediately, so LaunchServices has to start it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        if !mode.rawValue.isEmpty {
            process.arguments?.append(contentsOf: ["--args", mode.rawValue])
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.launches.removeAll { $0 === finished }
            }
        }
        launches.append(process)
        do {
            try process.run()
        } catch {
            launches.removeAll { $0 === process }
        }
    }
}
