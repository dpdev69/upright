import Foundation

/// Decodes one value without failing its container: an unreadable entry becomes `nil`, so a
/// single bad value never loses the rest of a saved list or table.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

/// Settings and memory for one physical mouse (or the seed for a model's first-seen units).
///
/// Decoding is tolerant: missing or unreadable fields take their defaults and unknown fields
/// are ignored, so older and newer saves still load.
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

    /// The nickname without surrounding whitespace, or nil when it is empty or blank.
    public var trimmedNickname: String? {
        guard let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case nickname, remapEnabled, preferredDPI, lastName, lastModel, lastControls, lastConnection, lastSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        let dpi: Int? = value(.preferredDPI)
        let controls: [Lossy<UInt16>]? = value(.lastControls)
        self.init(
            nickname: value(.nickname),
            remapEnabled: value(.remapEnabled) ?? true,
            preferredDPI: dpi.flatMap { $0 > 0 ? $0 : nil },
            lastName: value(.lastName),
            lastModel: value(.lastModel),
            lastControls: controls?.compactMap(\.value) ?? [],
            lastConnection: value(.lastConnection),
            lastSeen: value(.lastSeen)
        )
    }
}

/// Every mouse's preferences, persisted under `defaultsKey`. Only stable device IDs are stored.
///
/// The JSON is `{"models": {"046D:B020": {...}}, "devices": {"u:046D:B020:1A2B3C4D": {...}}}`.
/// Decoding skips entries whose key or value is unreadable, and drops transient device IDs.
public struct DevicePreferencesStore: Codable, Hashable, Sendable {
    public static let defaultsKey = "devicePreferences.v1"

    /// Seeds for units of a model seen for the first time. Only `preferredDPI` is used.
    public var models: [ModelKey: DevicePreferences]
    public var devices: [DeviceID: DevicePreferences]

    /// Transient IDs in `devices` are dropped: they must never outlive their connection.
    public init(models: [ModelKey: DevicePreferences] = [:], devices: [DeviceID: DevicePreferences] = [:]) {
        self.models = models
        self.devices = devices.filter { $0.key.isStable }
    }

    // MARK: Lookup

    /// The unit's own preferences, else a first-seen unit's defaults with its model's seed speed.
    /// A unit that has an entry keeps it even when its speed is nil ("let the mouse decide").
    /// Transient IDs never have an entry, so they always get the model seed.
    public func preferences(for id: DeviceID, model: ModelKey) -> DevicePreferences {
        if id.isStable, let own = devices[id] { return own }
        return Self.firstSeen(seed: models[model])
    }

    /// Stores a unit's preferences. Transient IDs are ignored: they aren't remembered.
    public mutating func setPreferences(_ preferences: DevicePreferences, for id: DeviceID) {
        guard id.isStable else { return }
        devices[id] = preferences
    }

    /// Units that have preferences but aren't in `connected`, most recently seen first
    /// (never-seen last), for the "remembered mice" list.
    public func rememberedDevices(excluding connected: Set<DeviceID> = []) -> [(id: DeviceID, preferences: DevicePreferences)] {
        devices
            .filter { !connected.contains($0.key) }
            .sorted { lhs, rhs in
                switch (lhs.value.lastSeen, rhs.value.lastSeen) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.key < rhs.key
                }
            }
            .map { (id: $0.key, preferences: $0.value) }
    }

    // MARK: Updates

    /// Remembers what was last seen of a unit (name, controls, connection, time). A unit seen
    /// for the first time starts from its model's seed speed; settings the user chose are never
    /// touched. Transient IDs are ignored. `now` exists for tests.
    public mutating func record(_ id: DeviceID, snapshot: DeviceSnapshot, now: Date = Date()) {
        guard id.isStable else { return }
        let model = id.model
        var prefs = devices[id] ?? Self.firstSeen(seed: model.flatMap { models[$0] })
        if let model { prefs.lastModel = model }
        prefs.lastName = snapshot.name
        prefs.lastControls = snapshot.configurableControls.map(\.cid)
        prefs.lastConnection = snapshot.connection.rawValue
        prefs.lastSeen = now
        devices[id] = prefs
    }

    /// Copies Upright 2.x's single preferred speed into the MX Vertical seed, once: an existing
    /// seed (even one without a speed) means it already ran. Values that aren't a positive speed
    /// leave the seed without one.
    public mutating func migrateLegacy(preferredDPI: Int?) {
        guard models[.mxVertical] == nil else { return }
        models[.mxVertical] = DevicePreferences(preferredDPI: preferredDPI.flatMap { $0 > 0 ? $0 : nil })
    }

    public mutating func forget(_ id: DeviceID) {
        devices[id] = nil
    }

    private static func firstSeen(seed: DevicePreferences?) -> DevicePreferences {
        DevicePreferences(preferredDPI: seed?.preferredDPI)
    }

    // MARK: Persistence

    /// Raw copies of saved data this version couldn't read in full live under this prefix plus
    /// an ISO 8601 time.
    public static let backupKeyPrefix = "devicePreferences.v1.backup."

    /// Reads the store saved in `defaults`; unreadable or missing data gives an empty store.
    ///
    /// Saved data that can't be read in full (not this format, unreadable entries that were
    /// skipped, or top-level fields this version doesn't know and would drop on the next save)
    /// is first copied, as it is, to a key under `backupKeyPrefix`, the way `MappingStore`
    /// backs up mappings, so saving the store afterwards loses nothing. Each distinct saved
    /// value is backed up once, however many launches read it. `now` exists for tests.
    public static func load(
        from defaults: UserDefaults = .standard,
        log: (String) -> Void = { _ in },
        now: Date = Date()
    ) -> DevicePreferencesStore {
        guard defaults.object(forKey: defaultsKey) != nil else { return DevicePreferencesStore() }
        guard let data = defaults.data(forKey: defaultsKey) else {
            backUpUnreadable(in: defaults, reason: "saved device preferences are not data", log: log, now: now)
            return DevicePreferencesStore()
        }
        guard let store = try? JSONDecoder().decode(DevicePreferencesStore.self, from: data) else {
            backUpUnreadable(in: defaults, reason: "saved device preferences could not be read", log: log, now: now)
            return DevicePreferencesStore()
        }
        if let loss = losses(in: data, keeping: store) {
            backUpUnreadable(in: defaults, reason: loss, log: log, now: now)
        }
        return store
    }

    /// Keys of every backup made so far, oldest first.
    public static func backupKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(backupKeyPrefix) }.sorted()
    }

    /// What reading `data` into `store` left out, or nil when nothing was.
    private static func losses(in data: Data, keeping store: DevicePreferencesStore) -> String? {
        guard let top = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return "saved device preferences could not be read"
        }
        let known: Set<String> = [CodingKeys.models.stringValue, CodingKeys.devices.stringValue]
        let unknown = top.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            return "saved device preferences have fields this version doesn't know (\(unknown.joined(separator: ", ")))"
        }
        func entries(_ key: CodingKeys) -> Int {
            switch top[key.stringValue] {
            case nil, .null?: return 0
            case .object(let entries)?: return entries.count
            default: return 1
            }
        }
        let skipped = entries(.models) - store.models.count + entries(.devices) - store.devices.count
        guard skipped > 0 else { return nil }
        return "skipped \(skipped) unreadable device preference entr\(skipped == 1 ? "y" : "ies")"
    }

    /// Copies the raw saved value to a new backup key, unless an existing backup already holds it.
    private static func backUpUnreadable(in defaults: UserDefaults, reason: String, log: (String) -> Void, now: Date) {
        guard let object = defaults.object(forKey: defaultsKey) else { return }
        let data = defaults.data(forKey: defaultsKey)
        let existing = backupKeys(in: defaults)
        let alreadyKept = existing.contains { key in
            if let data { return defaults.data(forKey: key) == data }
            guard let kept = defaults.object(forKey: key) else { return false }
            return String(describing: kept) == String(describing: object)
        }
        guard !alreadyKept else { return }
        let stamp = ISO8601DateFormatter().string(from: now)
        var key = backupKeyPrefix + stamp
        var suffix = 1
        while defaults.object(forKey: key) != nil {
            suffix += 1
            key = backupKeyPrefix + "\(stamp)-\(suffix)"
        }
        defaults.set(object, forKey: key)
        log("Device preferences: \(reason); raw data backed up to \(key)")
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private enum CodingKeys: String, CodingKey {
        case models, devices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawModels = (try? c.decodeIfPresent([String: Lossy<DevicePreferences>].self, forKey: .models)) ?? nil
        let rawDevices = (try? c.decodeIfPresent([String: Lossy<DevicePreferences>].self, forKey: .devices)) ?? nil

        var models: [ModelKey: DevicePreferences] = [:]
        for (key, entry) in rawModels ?? [:] {
            guard let model = ModelKey(rawValue: key), let prefs = entry.value else { continue }
            models[model] = prefs
        }
        var devices: [DeviceID: DevicePreferences] = [:]
        for (key, entry) in rawDevices ?? [:] {
            let id = DeviceID(rawValue: key)
            guard !key.isEmpty, id.isStable, let prefs = entry.value else { continue }
            devices[id] = prefs
        }
        self.init(models: models, devices: devices)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var encodedModels: [String: DevicePreferences] = [:]
        for (model, prefs) in models { encodedModels[model.rawValue] = prefs }
        var encodedDevices: [String: DevicePreferences] = [:]
        for (id, prefs) in devices where id.isStable { encodedDevices[id.rawValue] = prefs }
        try c.encode(encodedModels, forKey: .models)
        try c.encode(encodedDevices, forKey: .devices)
    }
}
