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
    public var mappings: ButtonMappings
    public var isEnabled = true {
        didSet { if !isEnabled { releaseAll() } }
    }

    private let performer: ActionPerforming
    /// Effects that are "down" right now, keyed by CID, so a release always matches its press
    /// even if the mapping changed while the button was held.
    private var held: [UInt16: ActionEffect] = [:]

    public init(mappings: ButtonMappings, performer: ActionPerforming) {
        self.mappings = mappings
        self.performer = performer
    }

    public func handle(_ event: ButtonEvent) {
        switch event.phase {
        case .press:
            guard isEnabled, let effect = mappings[event.cid].effect else { return }
            if effect.tracksButtonState {
                held[event.cid] = effect
            }
            performer.perform(effect, phase: .down)
        case .release:
            guard let effect = held.removeValue(forKey: event.cid) else { return }
            performer.perform(effect, phase: .up)
        }
    }

    public func releaseAll() {
        let effects = held
        held.removeAll()
        effects.values.forEach { performer.perform($0, phase: .up) }
    }
}
