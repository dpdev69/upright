import AppKit
import CoreGraphics
import os

/// Turns action effects into synthetic input. Keyboard, media-key and mouse events are posted
/// to the HID event tap, which requires Accessibility access.
@MainActor
final class SystemActionPerformer: ActionPerforming {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let launcher = ProcessLauncher()
    private let logger = Logger(subsystem: "Upright", category: "Actions")

    /// How many held shortcuts currently need each modifier, so overlapping shortcuts that
    /// share a modifier release it only after the last one lets go.
    private var modifierHolds: [Int: Int] = [:]
    /// Like `modifierHolds`, for synthetic mouse buttons and repeating media keys: two mice
    /// holding the same button (or key) post one press, and the last release ends it.
    private var mouseButtonHolds = HoldCounts<SyntheticMouseButton>()
    private var mediaKeyHolds = HoldCounts<MediaKey>()
    /// Buttons with at least one hold, in the order they went down.
    private var heldMouseButtons: [SyntheticMouseButton] = []
    private var lastClick: (button: SyntheticMouseButton, time: TimeInterval, location: CGPoint, count: Int64)?
    private var clickStates: [SyntheticMouseButton: Int64] = [:]
    private let dragRewriter = MouseDragRewriter()
    private var mediaRepeats: [MediaKey: Task<Void, Never>] = [:]

    private static let doubleClickDistance: CGFloat = 5
    private static let mediaRepeatDelay: UInt64 = 400_000_000
    private static let mediaRepeatInterval: UInt64 = 100_000_000

    func perform(_ effect: ActionEffect, phase: ActionPhase) {
        let down = phase == .down
        switch effect {
        case .keyCombo(let combo):
            down ? pressKey(combo) : releaseKey(combo)
        case .mouseButton(let button):
            postMouseButton(button, down: down)
        case .media(let key):
            if key.repeatsWhileHeld {
                down ? startRepeating(key) : stopRepeating(key)
            } else if down {
                postMediaKey(key)
            }
        case .missionControl(let mode):
            if down { openMissionControl(mode) }
        case .launchApp(let app):
            if down { launch(app) }
        case .openURL(let url):
            if down { NSWorkspace.shared.open(url) }
        case .runShortcut(let name):
            if down { launcher.run("/usr/bin/shortcuts", arguments: ["run", name]) }
        case .device:
            // Routed to the device by RemapEngine; nothing to post.
            break
        }
    }

    // MARK: Keys

    /// Posts real modifier presses before the key, like a keyboard does, so apps that track
    /// modifier state (rather than reading flags off the key event) see them too.
    private func pressKey(_ combo: KeyCombo) {
        for modifier in combo.modifiers.elements {
            let holds = modifierHolds[modifier.rawValue, default: 0]
            modifierHolds[modifier.rawValue] = holds + 1
            if holds == 0 { postModifier(modifier, down: true) }
        }
        postKey(combo, down: true)
    }

    private func releaseKey(_ combo: KeyCombo) {
        postKey(combo, down: false)
        for modifier in combo.modifiers.elements.reversed() {
            let holds = modifierHolds[modifier.rawValue, default: 0]
            guard holds > 0 else { continue }
            modifierHolds[modifier.rawValue] = holds == 1 ? nil : holds - 1
            if holds == 1 { postModifier(modifier, down: false) }
        }
    }

    private func postKey(_ combo: KeyCombo, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: down) else { return }
        var flags = heldModifierFlags.union(Self.flags(for: combo.modifiers))
        if combo.carriesFunctionFlag { flags.insert(.maskSecondaryFn) }
        if combo.carriesNumericPadFlag { flags.insert(.maskNumericPad) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postModifier(_ modifier: KeyModifiers, down: Bool) {
        guard let keyCode = KeyCode.modifierKey(for: modifier),
              let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        // A modifier key reaches apps as flagsChanged, carrying the flags in effect after it.
        event.type = .flagsChanged
        event.flags = heldModifierFlags
        event.post(tap: .cghidEventTap)
    }

    private var heldModifierFlags: CGEventFlags {
        Self.flags(for: KeyModifiers(rawValue: modifierHolds.keys.reduce(0, |)))
    }

    private static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    // MARK: Mouse buttons

    private func postMouseButton(_ button: SyntheticMouseButton, down: Bool) {
        // Only the first press and the last release reach the system; the ones in between are
        // another mouse holding the same button, or a release with nothing held.
        guard down ? mouseButtonHolds.acquire(button) : mouseButtonHolds.release(button) else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: down ? .otherMouseDown : .otherMouseUp,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: down ? nextClickState(button, at: location) : clickStates[button] ?? 1)
        event.flags = CGEventSource.flagsState(.combinedSessionState)

        heldMouseButtons.removeAll { $0 == button }
        if down {
            heldMouseButtons.append(button)
        } else {
            clickStates[button] = nil
        }
        // While a button is held, pointer movement must arrive as drags of that button.
        dragRewriter.setButton(heldMouseButtons.last.map { Int64($0.rawValue) })
        event.post(tap: .cghidEventTap)
    }

    private func nextClickState(_ button: SyntheticMouseButton, at location: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if let last = lastClick, last.button == button,
           now - last.time <= NSEvent.doubleClickInterval,
           hypot(location.x - last.location.x, location.y - last.location.y) <= Self.doubleClickDistance {
            count = last.count + 1
        }
        lastClick = (button, now, location, count)
        clickStates[button] = count
        return count
    }

    // MARK: Media keys

    private func startRepeating(_ key: MediaKey) {
        // A second mouse holding the same key joins the repeat that is already running.
        guard mediaKeyHolds.acquire(key) else { return }
        postMediaKey(key)
        mediaRepeats[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.mediaRepeatDelay)
            while !Task.isCancelled, let self {
                self.postMediaKey(key)
                try? await Task.sleep(nanoseconds: Self.mediaRepeatInterval)
            }
        }
    }

    private func stopRepeating(_ key: MediaKey) {
        guard mediaKeyHolds.release(key) else { return }
        mediaRepeats.removeValue(forKey: key)?.cancel()
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

    // MARK: Apps and processes

    private func openMissionControl(_ mode: MissionControlMode) {
        // Mission Control.app is arm64e-only. Executing it from this arm64 app is
        // killed immediately, so LaunchServices has to start it.
        var arguments = ["-a", "Mission Control"]
        if !mode.rawValue.isEmpty {
            arguments += ["--args", mode.rawValue]
        }
        launcher.run("/usr/bin/open", arguments: arguments)
    }

    private func launch(_ app: AppReference) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            logger.error("No app with bundle ID \(app.bundleID, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [logger] _, error in
            if let error {
                logger.error("Could not open \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// How many holders currently need each key. `acquire` is true for the first holder and
/// `release` for the last, which are the only moments that change what the system sees.
fileprivate struct HoldCounts<Key: Hashable> {
    private var counts: [Key: Int] = [:]

    mutating func acquire(_ key: Key) -> Bool {
        let count = counts[key, default: 0] + 1
        counts[key] = count
        return count == 1
    }

    /// False while other holders remain, and for a key nobody holds.
    mutating func release(_ key: Key) -> Bool {
        guard let count = counts[key] else { return false }
        counts[key] = count == 1 ? nil : count - 1
        return count == 1
    }
}

/// Runs helper tools without a shell and keeps each `Process` alive until it exits, so it's
/// reaped instead of left as a zombie.
@MainActor
final class ProcessLauncher {
    private var running: [ObjectIdentifier: Process] = [:]
    private let logger = Logger(subsystem: "Upright", category: "Processes")

    func run(_ executable: String, arguments: [String], completion: (@MainActor @Sendable (Int32) -> Void)? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let id = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.running[id] = nil
                completion?(status)
            }
        }
        running[id] = process
        do {
            try process.run()
        } catch {
            running[id] = nil
            logger.error("Could not run \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            completion?(-1)
        }
    }
}

/// While a synthetic mouse button is held, rewrites pointer movement into drags of that button
/// with an active session event tap. The tap exists only while a button is held.
@MainActor
final class MouseDragRewriter {
    /// Shared with the tap callback, which runs on the main run loop.
    fileprivate final class State {
        var buttonNumber: Int64 = 0
        var tap: CFMachPort?
    }

    private let state = State()
    private var runLoopSource: CFRunLoopSource?

    func setButton(_ buttonNumber: Int64?) {
        guard let buttonNumber else {
            stop()
            return
        }
        state.buttonNumber = buttonNumber
        if state.tap == nil { start() }
    }

    private func start() {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dragTapCallback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.tap = tap
        runLoopSource = source
    }

    private func stop() {
        if let tap = state.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        state.tap = nil
        runLoopSource = nil
    }
}

private func dragTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<MouseDragRewriter.State>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .mouseMoved:
        event.type = .otherMouseDragged
        event.setIntegerValueField(.mouseEventButtonNumber, value: state.buttonNumber)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
