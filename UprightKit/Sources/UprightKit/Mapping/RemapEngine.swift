/// Where movement reported to gestures comes from.
public enum PointerDeltaSource: Hashable, Sendable {
    /// The mouse's raw sensor movement (HID++ raw XY), in counts at the current DPI.
    case rawSensor
    /// Cursor movement, in points, for buttons that can't report raw movement.
    case cursor
}

public enum ActionPhase: Hashable, Sendable {
    case down
    case up
}

/// Carries out an action's effect. The macOS implementation posts CGEvents.
@MainActor
public protocol ActionPerforming: AnyObject {
    func perform(_ effect: ActionEffect, phase: ActionPhase)
}

/// Routes button events from the mouse to the configured actions.
@MainActor
public final class RemapEngine {
    /// The table for the current context (the frontmost app's effective mappings). Changing it
    /// while a button is held doesn't affect that button: its release always matches its press.
    public var mappings: ButtonMappings
    public var isEnabled = true {
        didSet { if !isEnabled { releaseAll() } }
    }
    /// Receives `.device` effects, which the mouse carries out rather than the performer.
    public var onDeviceAction: ((DeviceAction) -> Void)?

    /// Buttons physically held right now (as far as the engine has seen), whatever they're mapped to.
    /// Keep these diverted until released so their release still reaches the engine.
    public private(set) var pressedControls: Set<UInt16> = []

    /// How far the mouse must move while a gesture button is held before a direction fires, in raw
    /// sensor counts. Set it from the mouse's pointer speed with `GestureRecognizer.rawThreshold(dpi:)`.
    public var rawGestureThreshold = GestureRecognizer.rawThreshold(dpi: nil)
    /// The same distance for buttons whose gestures follow the cursor, in points.
    public var cursorGestureThreshold = GestureRecognizer.cursorThreshold
    /// Where a gesture button's movement comes from. Asked at each press; raw movement by default.
    public var gestureSource: @MainActor (UInt16) -> PointerDeltaSource = { _ in .rawSensor }

    /// Held buttons whose press started a gesture. Keep these reporting movement until released.
    public var gestureControls: Set<UInt16> { Set(gestures.keys) }

    private let performer: ActionPerforming
    /// Effects that are "down" right now, keyed by CID.
    private var held: [UInt16: ActionEffect] = [:]
    /// Gestures in progress, keyed by CID. The set is captured at press so a profile switch
    /// mid-hold doesn't change what the hold does.
    private var gestures: [UInt16: (set: GestureSet, source: PointerDeltaSource, recognizer: GestureRecognizer)] = [:]

    public init(mappings: ButtonMappings, performer: ActionPerforming) {
        self.mappings = mappings
        self.performer = performer
    }

    public func handle(_ event: ButtonEvent) {
        switch event.phase {
        case .press:
            // A second press without a release means the release was lost; finish the first one.
            if let stale = held.removeValue(forKey: event.cid) {
                performer.perform(stale, phase: .up)
            }
            gestures.removeValue(forKey: event.cid)
            pressedControls.insert(event.cid)
            guard isEnabled else { return }
            let action = mappings[event.cid]
            if case .gestures(let set) = action {
                let source = gestureSource(event.cid)
                let threshold = source == .rawSensor ? rawGestureThreshold : cursorGestureThreshold
                gestures[event.cid] = (set, source, GestureRecognizer(threshold: threshold))
                return
            }
            guard let effect = action.effect else { return }
            if case .device(let action) = effect {
                onDeviceAction?(action)
                return
            }
            if effect.tracksButtonState {
                held[event.cid] = effect
            }
            performer.perform(effect, phase: .down)
        case .release:
            pressedControls.remove(event.cid)
            if let gesture = gestures.removeValue(forKey: event.cid) {
                if gesture.recognizer.isTap { fire(gesture.set.tap) }
                return
            }
            guard let effect = held.removeValue(forKey: event.cid) else { return }
            performer.perform(effect, phase: .up)
        }
    }

    /// Movement while buttons are held: raw XY from the mouse, or cursor movement as a fallback.
    /// Only gestures tracking that source use it. Each held gesture button fires at most one
    /// direction per press.
    public func handlePointerDelta(dx: Int, dy: Int, source: PointerDeltaSource = .rawSensor) {
        for cid in gestures.keys.sorted() where gestures[cid]?.source == source {
            guard let direction = gestures[cid]?.recognizer.add(dx: dx, dy: dy),
                  let set = gestures[cid]?.set
            else { continue }
            fire(set[direction])
        }
    }

    /// Carries out a gesture slot as a complete press and release.
    private func fire(_ action: ButtonAction) {
        guard let effect = action.effect else { return }
        if case .device(let deviceAction) = effect {
            onDeviceAction?(deviceAction)
            return
        }
        performer.perform(effect, phase: .down)
        if effect.tracksButtonState {
            performer.perform(effect, phase: .up)
        }
    }

    public func releaseAll() {
        let effects = held
        held.removeAll()
        gestures.removeAll()
        pressedControls.removeAll()
        effects.values.forEach { performer.perform($0, phase: .up) }
    }
}
