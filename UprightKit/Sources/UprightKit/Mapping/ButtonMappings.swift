import Foundation

/// The user's button → action table, keyed by control ID.
///
/// `.deviceDefault` is never stored: a button without an entry is left to the mouse.
public struct ButtonMappings: Codable, Hashable, Sendable {
    private var actions: [UInt16: ButtonAction]

    public init(_ actions: [UInt16: ButtonAction] = [:]) {
        self.actions = actions.filter { $0.value != .deviceDefault }
    }

    /// Fresh installs divert nothing: every button keeps its native behavior.
    public static let defaults = ButtonMappings()

    /// What Upright 1.x mapped out of the box. Users upgrading from it keep these.
    public static let legacyDefaults = ButtonMappings([
        KnownControl.back: .system(.navigateBack),
        KnownControl.forward: .system(.navigateForward),
        KnownControl.dpiSwitch: .system(.missionControl),
    ])

    /// The onboarding template for a model with these controls. The MX Vertical keeps what
    /// Upright 1.x shipped (`legacyDefaults`); any other model gets `suggested(forControls:)`.
    public static func suggested(for model: ModelKey, controls: [UInt16]) -> ButtonMappings {
        model == .mxVertical ? legacyDefaults : suggested(forControls: controls)
    }

    /// Back → ⌘[ and Forward → ⌘] when the mouse has those buttons, Mission Control on a gesture
    /// button (0xC3, else 0xD0); every other control stays native.
    public static func suggested(forControls controls: [UInt16]) -> ButtonMappings {
        var table: [UInt16: ButtonAction] = [:]
        if controls.contains(KnownControl.back) { table[KnownControl.back] = .system(.navigateBack) }
        if controls.contains(KnownControl.forward) { table[KnownControl.forward] = .system(.navigateForward) }
        if let gesture = [KnownControl.gestureButton, KnownControl.multiPlatformGesture].first(where: controls.contains) {
            table[gesture] = .system(.missionControl)
        }
        return ButtonMappings(table)
    }

    public subscript(cid: UInt16) -> ButtonAction {
        get { actions[cid] ?? .deviceDefault }
        set { actions[cid] = newValue == .deviceDefault ? nil : newValue }
    }

    public var mappedControls: [UInt16: ButtonAction] { actions }
    public var isEmpty: Bool { actions.isEmpty }

    /// Controls the mouse should divert to Upright. Actions that need Accessibility are
    /// left on the mouse's native behavior until access is granted.
    public func divertedControls(accessibilityGranted: Bool) -> Set<UInt16> {
        Set(actions.filter { _, action in
            action.requiresDiversion && (accessibilityGranted || !action.requiresAccessibility)
        }.keys)
    }

    /// Diverted controls mapped to gestures: these also need the mouse's raw movement while held.
    public func gestureControls(accessibilityGranted: Bool) -> Set<UInt16> {
        divertedControls(accessibilityGranted: accessibilityGranted).filter { actions[$0]?.isGestures == true }
    }

    /// Applies per-button overrides on top of this table. An override of `.deviceDefault`
    /// hands the button back to the mouse.
    public func applying(_ overrides: [UInt16: ButtonAction]) -> ButtonMappings {
        var result = self
        for (cid, action) in overrides { result[cid] = action }
        return result
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case actions }

    /// Decodes entry by entry: an unreadable entry (corrupt, or from a newer version) is skipped
    /// and noted in the decoder's `MappingDecodingReport` instead of failing the whole table.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.actions) else {
            self.init()
            return
        }
        let table = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .actions)
        self.init(ActionTable.decode(from: table, report: decoder.mappingReport, context: "global"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var table = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .actions)
        try ActionTable.encode(actions, to: &table)
    }

    // MARK: Legacy persistence

    /// Where Upright 1.x stored its single mapping table. Read once for migration; see `MappingStore`.
    public static let defaultsKey = "buttonMappings.v1"
}

/// Collects what tolerant decoding had to skip. Pass one in `userInfo[.mappingReport]`.
public final class MappingDecodingReport: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []

    public init() {}

    public var issues: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notes
    }

    public var isClean: Bool { issues.isEmpty }

    func note(_ issue: String) {
        lock.lock()
        notes.append(issue)
        lock.unlock()
    }
}

extension CodingUserInfoKey {
    public static let mappingReport = CodingUserInfoKey(rawValue: "upright.mappingReport")!
}

extension Decoder {
    var mappingReport: MappingDecodingReport? { userInfo[.mappingReport] as? MappingDecodingReport }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// CID-keyed action tables are JSON objects with decimal-string keys.
enum ActionTable {
    static func decode(
        from container: KeyedDecodingContainer<AnyCodingKey>,
        report: MappingDecodingReport?,
        context: String
    ) -> [UInt16: ButtonAction] {
        var result: [UInt16: ButtonAction] = [:]
        for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            guard let cid = UInt16(key.stringValue) else {
                report?.note("\(context): skipped entry with invalid control ID “\(key.stringValue)”")
                continue
            }
            do {
                result[cid] = try container.decode(ButtonAction.self, forKey: key)
            } catch {
                report?.note("\(context): skipped unreadable action for control \(key.stringValue) (\(error.briefDescription))")
            }
        }
        return result
    }

    static func encode(_ actions: [UInt16: ButtonAction], to container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        for (cid, action) in actions {
            try container.encode(action, forKey: AnyCodingKey(String(cid)))
        }
    }
}

extension Error {
    /// A one-line description of a decoding error, for logs.
    var briefDescription: String {
        guard let error = self as? DecodingError else { return "\(self)" }
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
