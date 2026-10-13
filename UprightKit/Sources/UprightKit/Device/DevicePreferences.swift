import Foundation

// Wave 0 scaffold: final signatures and a first implementation. W1.7 owns this file
// (tolerant decoding, tests).

/// Settings and memory for one physical mouse (or the seed for a model's first-seen units).
public struct DevicePreferences: Codable, Hashable, Sendable {
    public var nickname: String?
    /// "Remap this mouse": off keeps every button native on this unit.
    public var remapEnabled = true
    /// The pointer speed to keep; nil leaves the mouse's own setting alone.
    public var preferredDPI: Int?
    public var lastName: String?
    public var lastModel: ModelKey?
    public var lastControls: [UInt16] = []
    /// `ConnectionKind.rawValue` of the last connection.
    public var lastConnection: String?
    public var lastSeen: Date?

    public init(
        nickname: String? = nil,
        remapEnabled: Bool = true,
        preferredDPI: Int? = nil,
        lastName: String? = nil,
        lastModel: ModelKey? = nil,
        lastControls: [UInt16] = [],
        lastConnection: String? = nil,
        lastSeen: Date? = nil
    ) {
        self.nickname = nickname
        self.remapEnabled = remapEnabled
        self.preferredDPI = preferredDPI
        self.lastName = lastName
        self.lastModel = lastModel
        self.lastControls = lastControls
        self.lastConnection = lastConnection
        self.lastSeen = lastSeen
    }
}

/// Every mouse's preferences, persisted under `defaultsKey`. Only stable device IDs are stored.
public struct DevicePreferencesStore: Codable, Hashable, Sendable {
    public static let defaultsKey = "devicePreferences.v1"

    /// Seeds (preferred speed) for units of a model seen for the first time.
    public var models: [ModelKey: DevicePreferences]
    public var devices: [DeviceID: DevicePreferences]

    public init(models: [ModelKey: DevicePreferences] = [:], devices: [DeviceID: DevicePreferences] = [:]) {
        self.models = models
        self.devices = devices
    }

    /// The unit's own preferences, else its model's seed, else defaults.
    public func preferences(for id: DeviceID, model: ModelKey) -> DevicePreferences {
        if id.isStable, let own = devices[id] { return own }
        return models[model] ?? DevicePreferences()
    }

    /// Remembers what was last seen of a unit (name, controls, connection, time). A unit seen
    /// for the first time starts from its model's seed. Transient IDs are ignored.
    public mutating func record(_ id: DeviceID, snapshot: DeviceSnapshot) {
        guard id.isStable else { return }
        var prefs = devices[id] ?? id.model.flatMap { models[$0] } ?? DevicePreferences()
        prefs.lastModel = id.model ?? prefs.lastModel
        prefs.lastName = snapshot.name
        prefs.lastControls = snapshot.configurableControls.map(\.cid)
        prefs.lastConnection = snapshot.connection.rawValue
        prefs.lastSeen = Date()
        devices[id] = prefs
    }

    /// Copies Upright 2.x's single preferred speed into the MX Vertical seed, once: an existing
    /// seed (even one without a speed) means it already ran.
    public mutating func migrateLegacy(preferredDPI: Int?) {
        guard models[.mxVertical] == nil else { return }
        models[.mxVertical] = DevicePreferences(preferredDPI: preferredDPI)
    }

    public mutating func forget(_ id: DeviceID) {
        devices[id] = nil
    }
}
