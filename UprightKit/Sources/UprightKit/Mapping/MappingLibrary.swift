import Foundation

// Wave 0 scaffold: final signatures and a first implementation of the §E format. W1.5 owns
// this file (MappingStore integration, export mirror, import, tests).

/// Every model's mappings: schema v3. Each model holds the v2 shape (a global table plus
/// per-app profiles); a model without an entry keeps every button native.
///
///     { "schemaVersion": 3,
///       "models": { "046D:B020": { "name": "MX Vertical", "global": {…}, "apps": […] } },
///       "devices": {} }
///
/// The `devices` section and unknown top-level keys are preserved but unused.
public struct MappingLibrary: Codable, Hashable, Sendable {
    public static let schemaVersion = 3

    public var models: [ModelKey: MappingProfiles]
    /// Display names, written next to every model key so exports stay readable.
    public var modelNames: [ModelKey: String]
    /// The reserved `devices` section (a later per-unit override): preserved, unused.
    public var reservedDevices: [String: JSONValue]
    /// Top-level keys this version doesn't know, kept for forward compatibility.
    public var unknownTopLevel: [String: JSONValue]

    public init(
        models: [ModelKey: MappingProfiles] = [:],
        modelNames: [ModelKey: String] = [:],
        reservedDevices: [String: JSONValue] = [:],
        unknownTopLevel: [String: JSONValue] = [:]
    ) {
        self.models = models
        self.modelNames = modelNames
        self.reservedDevices = reservedDevices
        self.unknownTopLevel = unknownTopLevel
    }

    /// Only an MX Vertical could have produced v2 data, so it becomes that model's setup.
    public init(migrating v2: MappingProfiles) {
        self.init(models: [.mxVertical: v2], modelNames: [.mxVertical: MXVertical.displayName])
    }

    /// A model's profiles; empty (every button native) when it has none.
    public subscript(model: ModelKey) -> MappingProfiles {
        get { models[model] ?? MappingProfiles(global: ButtonMappings(), apps: []) }
        set { models[model] = newValue }
    }

    /// The table in effect for `model` while `bundleID` is frontmost. Empty for a nil or
    /// unknown model.
    public func effectiveMappings(model: ModelKey?, bundleID: String?) -> ButtonMappings {
        guard let model, let profiles = models[model] else { return ButtonMappings() }
        return profiles.effectiveMappings(forBundleID: bundleID)
    }

    /// Every configured action across every model (for the Accessibility requirement).
    public var allActiveActions: [ButtonAction] {
        models.keys.sorted().flatMap { models[$0]?.allActiveActions ?? [] }
    }

    /// The name shown for a model: the stored one, else the catalog's, else its key.
    public func name(of model: ModelKey) -> String {
        modelNames[model] ?? DeviceCatalog.model(model)?.name ?? model.rawValue
    }

    // MARK: Coding

    private static let knownKeys: Set<String> = ["schemaVersion", "models", "devices", "global", "apps"]

    /// One model's section: `MappingProfiles` without `schemaVersion`, plus `name`.
    private struct Section: Codable {
        var name: String?
        var profiles: MappingProfiles

        init(name: String?, profiles: MappingProfiles) {
            self.name = name
            self.profiles = profiles
        }

        private enum CodingKeys: String, CodingKey { case name, global, apps }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
            profiles = try MappingProfiles(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(profiles.global, forKey: .global)
            try container.encode(profiles.apps, forKey: .apps)
        }
    }

    /// Tolerant: unreadable model sections are skipped (and noted in the decoder's
    /// `MappingDecodingReport`). A payload without `models` but with v2 `global`/`apps` is
    /// read as v2 and migrated.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let report = decoder.mappingReport
        let version = (try? container.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion"))).flatMap { $0 }
        if let version, version > Self.schemaVersion {
            report?.note("written by a newer version (schema \(version)); reading what this version understands")
        }

        var models: [ModelKey: MappingProfiles] = [:]
        var names: [ModelKey: String] = [:]
        if let table = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("models")) {
            for key in table.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                guard let model = ModelKey(rawValue: key.stringValue) else {
                    report?.note("models: skipped entry with invalid model “\(key.stringValue)”")
                    continue
                }
                do {
                    let section = try table.decode(Section.self, forKey: key)
                    models[model] = section.profiles
                    if let name = section.name { names[model] = name }
                } catch {
                    report?.note("models.\(key.stringValue): skipped unreadable section (\(error.briefDescription))")
                }
            }
        } else if container.contains(AnyCodingKey("models")) {
            report?.note("models: skipped unreadable table")
        } else if container.contains(AnyCodingKey("global")) || container.contains(AnyCodingKey("apps")) {
            models[.mxVertical] = try MappingProfiles(from: decoder)
            names[.mxVertical] = MXVertical.displayName
        }

        var devices: [String: JSONValue] = [:]
        if container.contains(AnyCodingKey("devices")) {
            if let value = try? container.decode([String: JSONValue].self, forKey: AnyCodingKey("devices")) {
                devices = value
            } else {
                report?.note("devices: skipped unreadable section")
            }
        }

        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = value
            }
        }

        self.init(models: models, modelNames: names, reservedDevices: devices, unknownTopLevel: unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(Self.schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        var table = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("models"))
        for (model, profiles) in models {
            try table.encode(Section(name: name(of: model), profiles: profiles), forKey: AnyCodingKey(model.rawValue))
        }
        try container.encode(reservedDevices, forKey: AnyCodingKey("devices"))
        for (key, value) in unknownTopLevel where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

/// Any JSON value, for preserving data this version doesn't interpret.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
