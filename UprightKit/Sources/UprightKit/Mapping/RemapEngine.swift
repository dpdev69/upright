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

/// One physical button on one mouse. Engine state is keyed by it, so the same button held on
/// two mice is two independent holds.
public struct ControlKey: Hashable, Comparable, Sendable {
    public var source: DeviceAddress
    public var cid: UInt16

    public init(source: DeviceAddress, cid: UInt16) {
        self.source = source
        self.cid = cid
    }

    public static func < (lhs: ControlKey, rhs: ControlKey) -> Bool {
        lhs.source != rhs.source ? lhs.source < rhs.source : lhs.cid < rhs.cid
    }
}

/// Routes button events from the mice to the configured actions.
///
/// Every hold, gesture and pressed button is tracked per `ControlKey`, i.e. per sending device
/// (`ButtonEvent.source`). The mappings, gesture source and gesture distance are looked up for
/// that device at press and kept until the release, so a press always ends the way it started.
@MainActor
public final class RemapEngine {
    /// The table used when `mappingsProvider` is nil (single-mouse callers). Changing it while a
    /// button is held doesn't affect that button: its release always matches its press.
    public var mappings: ButtonMappings
    /// The table for the device that pressed a button, asked at each press. Nil uses `mappings`.
    public var mappingsProvider: (@MainActor (DeviceAddress) -> ButtonMappings)?

    public var isEnabled = true {
        didSet { if !isEnabled { releaseAll() } }
    }
    /// Receives `.device` effects together with the device whose button fired them.
    public var onSourcedDeviceAction: ((DeviceAction, DeviceAddress) -> Void)?
    /// Receives `.device` effects without their device (single-mouse callers). Called in addition
    /// to `onSourcedDeviceAction` when both are set, so set only one of them.
    public var onDeviceAction: ((DeviceAction) -> Void)?

    /// How far the mouse must move while a gesture button is held before a direction fires, in raw
    /// sensor counts. Used when `rawThresholdProvider` is nil. Set it from the mouse's pointer
    /// speed with `GestureRecognizer.rawThreshold(dpi:)`.
    public var rawGestureThreshold = GestureRecognizer.rawThreshold(dpi: nil)
    /// The raw-count distance for the device that pressed a gesture button, asked at the press
    /// (raw counts depend on that mouse's DPI). Nil uses `rawGestureThreshold`.
    public var rawThresholdProvider: (@MainActor (DeviceAddress) -> Double)?
    /// The same distance for buttons whose gestures follow the cursor, in points.
    public var cursorGestureThreshold = GestureRecognizer.cursorThreshold
    /// Where a gesture button's movement comes from, by CID. Used when `gestureSourceFor` is nil;
    /// raw movement by default.
    public var gestureSource: @MainActor (UInt16) -> PointerDeltaSource = { _ in .rawSensor }
    /// Where a gesture button's movement comes from on a given device (whether that mouse reports
    /// raw XY for the control). Asked at each press.
    public var gestureSourceFor: (@MainActor (DeviceAddress, UInt16) -> PointerDeltaSource)?

    /// A gesture in progress. The set, movement source and distance are captured at press, so a
    /// profile switch or DPI change mid-hold doesn't change what the hold does.
    struct GestureState: Hashable, Sendable {
        var set: GestureSet
        var deltaSource: PointerDeltaSource
        var recognizer: GestureRecognizer
    }

    private let performer: ActionPerforming
    /// Effects that are "down" right now.
    private(set) var held: [ControlKey: ActionEffect] = [:]
    /// Gestures in progress.
    private(set) var gestures: [ControlKey: GestureState] = [:]
    /// Buttons physically held right now (as far as the engine has seen), whatever they're mapped to.
    public private(set) var pressedKeys: Set<ControlKey> = []

    public init(mappings: ButtonMappings, performer: ActionPerforming) {
        self.mappings = mappings
        self.performer = performer
    }

    // MARK: Queries

    /// Buttons held on `source`. Keep these diverted on that device until released so their
    /// release still reaches the engine.
    public func pressedControls(for source: DeviceAddress) -> Set<UInt16> {
        Set(pressedKeys.lazy.filter { $0.source == source }.map(\.cid))
    }

    /// Held buttons on `source` whose press started a gesture. Keep these reporting movement
    /// on that device until released.
    public func gestureControls(for source: DeviceAddress) -> Set<UInt16> {
        Set(gestures.keys.lazy.filter { $0.source == source }.map(\.cid))
    }

    /// Held buttons on every device, by CID alone (single-mouse callers).
    public var pressedControls: Set<UInt16> { Set(pressedKeys.map(\.cid)) }

    /// Gesture buttons held on every device, by CID alone (single-mouse callers).
    public var gestureControls: Set<UInt16> { Set(gestures.keys.map(\.cid)) }

    /// True while a gesture that follows the cursor is in progress, i.e. while cursor movement
    /// should be watched and passed to `handleCursorDelta(dx:dy:)`.
    public var needsCursorDeltas: Bool {
        gestures.values.contains { $0.deltaSource == .cursor }
    }

    // MARK: Events

    public func handle(_ event: ButtonEvent) {
        let key = ControlKey(source: event.source, cid: event.cid)
        switch event.phase {
        case .press:
            // A second press of the same button on the same mouse without a release means the
            // release was lost; finish the first one.
            if let stale = held.removeValue(forKey: key) {
                performer.perform(stale, phase: .up)
            }
            gestures.removeValue(forKey: key)
            pressedKeys.insert(key)
            guard isEnabled else { return }
            let action = mappings(for: key.source)[key.cid]
            if case .gestures(let set) = action {
                let deltaSource = gestureSourceFor?(key.source, key.cid) ?? gestureSource(key.cid)
                let threshold = deltaSource == .rawSensor
                    ? (rawThresholdProvider?(key.source) ?? rawGestureThreshold)
                    : cursorGestureThreshold
                gestures[key] = GestureState(set: set, deltaSource: deltaSource, recognizer: GestureRecognizer(threshold: threshold))
                return
            }
            guard let effect = action.effect else { return }
            if case .device(let deviceAction) = effect {
                sendDeviceAction(deviceAction, from: key.source)
                return
            }
            if effect.tracksButtonState {
                held[key] = effect
            }
            performer.perform(effect, phase: .down)
        case .release:
            pressedKeys.remove(key)
            if let gesture = gestures.removeValue(forKey: key) {
                if gesture.recognizer.isTap { fire(gesture.set.tap, from: key.source) }
                return
            }
            guard let effect = held.removeValue(forKey: key) else { return }
            performer.perform(effect, phase: .up)
        }
    }

    /// Raw sensor movement from one mouse. Only gestures held on that same mouse that track raw
    /// movement use it. Each held gesture button fires at most one direction per press.
    public func handlePointerDelta(_ delta: PointerDelta) {
        feedGestures(dx: delta.dx, dy: delta.dy) { key, gesture in
            gesture.deltaSource == .rawSensor && key.source == delta.source
        }
    }

    /// Cursor movement, for gestures on buttons that can't report raw movement. macOS doesn't say
    /// which mouse moved the cursor, so this reaches every cursor-tracked gesture in progress,
    /// whatever device it was pressed on.
    public func handleCursorDelta(dx: Int, dy: Int) {
        feedGestures(dx: dx, dy: dy) { _, gesture in gesture.deltaSource == .cursor }
    }

    /// Movement without a device (single-mouse callers). Cursor movement is `handleCursorDelta`;
    /// raw movement reaches every raw-tracked gesture on every device. Callers that know the
    /// sending mouse use `handlePointerDelta(_:)` instead.
    public func handlePointerDelta(dx: Int, dy: Int, source: PointerDeltaSource = .rawSensor) {
        switch source {
        case .cursor:
            handleCursorDelta(dx: dx, dy: dy)
        case .rawSensor:
            feedGestures(dx: dx, dy: dy) { _, gesture in gesture.deltaSource == .rawSensor }
        }
    }

    /// Ends every hold on every device: held effects go up, gestures are cancelled without firing.
    public func releaseAll() {
        endHolds { _ in true }
    }

    /// Ends every hold on one device (it disconnected, was retired or stopped answering), leaving
    /// other devices' holds alone. Gestures are cancelled without firing.
    public func releaseAll(source: DeviceAddress) {
        endHolds { $0.source == source }
    }

    // MARK: Private

    private func mappings(for source: DeviceAddress) -> ButtonMappings {
        mappingsProvider?(source) ?? mappings
    }

    private func feedGestures(dx: Int, dy: Int, where matches: (ControlKey, GestureState) -> Bool) {
        for key in gestures.keys.sorted() {
            guard let gesture = gestures[key], matches(key, gesture),
                  let direction = gestures[key]?.recognizer.add(dx: dx, dy: dy)
            else { continue }
            fire(gesture.set[direction], from: key.source)
        }
    }

    private func endHolds(where matches: (ControlKey) -> Bool) {
        let keys = held.keys.filter(matches).sorted()
        let effects = keys.compactMap { held.removeValue(forKey: $0) }
        gestures = gestures.filter { !matches($0.key) }
        pressedKeys = pressedKeys.filter { !matches($0) }
        effects.forEach { performer.perform($0, phase: .up) }
    }

    /// Carries out a gesture slot as a complete press and release.
    private func fire(_ action: ButtonAction, from source: DeviceAddress) {
        guard let effect = action.effect else { return }
        if case .device(let deviceAction) = effect {
            sendDeviceAction(deviceAction, from: source)
            return
        }
        performer.perform(effect, phase: .down)
        if effect.tracksButtonState {
            performer.perform(effect, phase: .up)
        }
    }

    private func sendDeviceAction(_ action: DeviceAction, from source: DeviceAddress) {
        onSourcedDeviceAction?(action, source)
        onDeviceAction?(action)
    }
}
