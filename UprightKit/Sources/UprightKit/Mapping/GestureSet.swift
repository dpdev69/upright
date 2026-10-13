import Foundation

/// A direction the mouse moved while a gesture button was held.
public enum GestureDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case up, down, left, right

    public var title: String {
        switch self {
        case .up: return NSLocalizedString("Move Up", comment: "Gesture direction name")
        case .down: return NSLocalizedString("Move Down", comment: "Gesture direction name")
        case .left: return NSLocalizedString("Move Left", comment: "Gesture direction name")
        case .right: return NSLocalizedString("Move Right", comment: "Gesture direction name")
        }
    }

    public var symbolName: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}

/// The five actions of a gesture button: a click (`tap`) and a hold-and-move in each direction.
///
/// Slots hold plain actions; a nested `.gestures` makes the set invalid. `.deviceDefault` and
/// `.disabled` both mean "do nothing" here, because a gesture button is always diverted.
/// Missing or unreadable slots decode as `.disabled`.
public struct GestureSet: Codable, Hashable, Sendable {
    public var tap: ButtonAction
    public var up: ButtonAction
    public var down: ButtonAction
    public var left: ButtonAction
    public var right: ButtonAction

    public init(
        tap: ButtonAction = .disabled,
        up: ButtonAction = .disabled,
        down: ButtonAction = .disabled,
        left: ButtonAction = .disabled,
        right: ButtonAction = .disabled
    ) {
        self.tap = tap
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    /// What picking "Gestures" for a button starts with, modelled on Logitech's gesture button.
    public static let standard = GestureSet(
        tap: .system(.missionControl),
        up: .system(.missionControl),
        down: .system(.appExpose),
        left: .system(.spaceLeft),
        right: .system(.spaceRight)
    )

    public subscript(direction: GestureDirection) -> ButtonAction {
        get {
            switch direction {
            case .up: return up
            case .down: return down
            case .left: return left
            case .right: return right
            }
        }
        set {
            switch direction {
            case .up: up = newValue
            case .down: down = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    public var allActions: [ButtonAction] { [tap, up, down, left, right] }

    public var isValid: Bool {
        allActions.allSatisfy { !$0.isGestures && $0.isValid }
    }

    public var requiresAccessibility: Bool {
        allActions.contains { !$0.isGestures && $0.requiresAccessibility }
    }

    /// True when every slot does nothing.
    public var isEmpty: Bool {
        allActions.allSatisfy { $0 == .disabled || $0 == .deviceDefault }
    }

    /// A one-line description of the assigned slots, for tooltips.
    public var summary: String {
        var parts: [String] = []
        if !tap.doesNothing {
            parts.append(String(format: NSLocalizedString("Click: %@", comment: "Gesture summary entry; %@ is an action name"), tap.title))
        }
        for direction in GestureDirection.allCases where !self[direction].doesNothing {
            parts.append(String(format: NSLocalizedString("%@: %@", comment: "Gesture summary entry; direction and action name"), direction.shortTitle, self[direction].title))
        }
        guard !parts.isEmpty else {
            return NSLocalizedString("Hold and move the mouse; no gestures are assigned", comment: "Gesture button tooltip")
        }
        return String(format: NSLocalizedString("Hold and move the mouse — %@", comment: "Gesture button tooltip; %@ lists the assigned gestures"), parts.joined(separator: ", "))
    }

    private enum CodingKeys: String, CodingKey { case tap, up, down, left, right }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let report = decoder.mappingReport
        func slot(_ key: CodingKeys) -> ButtonAction {
            guard container.contains(key) else { return .disabled }
            guard let action = try? container.decode(ButtonAction.self, forKey: key), !action.isGestures, action.isValid else {
                report?.note("gestures: replaced unusable “\(key.stringValue)” action with Do Nothing")
                return .disabled
            }
            return action
        }
        tap = slot(.tap)
        up = slot(.up)
        down = slot(.down)
        left = slot(.left)
        right = slot(.right)
    }
}

private extension GestureDirection {
    var shortTitle: String {
        switch self {
        case .up: return NSLocalizedString("Up", comment: "Short gesture direction")
        case .down: return NSLocalizedString("Down", comment: "Short gesture direction")
        case .left: return NSLocalizedString("Left", comment: "Short gesture direction")
        case .right: return NSLocalizedString("Right", comment: "Short gesture direction")
        }
    }
}

extension ButtonAction {
    /// True for actions that do nothing when triggered (as a gesture slot).
    var doesNothing: Bool { self == .disabled || self == .deviceDefault }
}
