import Foundation

/// The user's button → action table, keyed by control ID.
public struct ButtonMappings: Codable, Hashable, Sendable {
    /// JSON object keys must be strings, so CIDs are stored as decimal strings.
    private var actions: [String: ButtonAction]

    public init(_ actions: [UInt16: ButtonAction] = [:]) {
        self.actions = Dictionary(uniqueKeysWithValues: actions.map { (String($0.key), $0.value) })
    }

    public static let defaults = ButtonMappings([
        KnownControl.back: .system(.navigateBack),
        KnownControl.forward: .system(.navigateForward),
        KnownControl.dpiSwitch: .system(.missionControl),
    ])

    public subscript(cid: UInt16) -> ButtonAction {
        get { actions[String(cid)] ?? .deviceDefault }
        set { actions[String(cid)] = newValue == .deviceDefault ? nil : newValue }
    }

    public var mappedControls: [UInt16: ButtonAction] {
        Dictionary(uniqueKeysWithValues: actions.compactMap { key, value in UInt16(key).map { ($0, value) } })
    }

    /// Controls the mouse should divert to Upright. Actions that need Accessibility are
    /// left on the mouse's native behavior until access is granted.
    public func divertedControls(accessibilityGranted: Bool) -> Set<UInt16> {
        Set(mappedControls.filter { _, action in
            action.requiresDiversion && (accessibilityGranted || !action.requiresAccessibility)
        }.keys)
    }

    // MARK: Persistence

    public static let defaultsKey = "buttonMappings.v1"

    public static func load(from defaults: UserDefaults) -> ButtonMappings {
        guard let data = defaults.data(forKey: defaultsKey),
              let mappings = try? JSONDecoder().decode(ButtonMappings.self, from: data) else {
            return .defaults
        }
        return mappings
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
