import Foundation

/// Every model's mappings: schema v3. Each model holds the v2 shape (a global table plus
/// per-app profiles); a model without an entry keeps every button native.
///
///     { "schemaVersion": 3,
///       "models": { "046D:B020": { "name": "MX Vertical", "global": {…}, "apps": […] } },
///       "devices": {} }
///
/// The `devices` section and unknown top-level keys are preserved but unused. Exported files
/// (`MappingStore.exportData(_:)`) also carry top-level `global` and `apps` mirroring the MX
/// Vertical's setup, so a 2.x build can import them; they are ignored whenever `models` exists.
public struct MappingLibrary: Codable, Hashable, Sendable {
    public static let schemaVersion = 3

    public var models: [ModelKey: MappingProfiles]
    /// Display names, written next to every model key so exports stay readable. A name without
    /// a setup in `models` is kept on its own.
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
        modelNames[model] ?? Self.catalogName(of: model)
    }

    /// The catalog's name for a model, else its key.
    public static func catalogName(of model: ModelKey) -> String {
        DeviceCatalog.model(model)?.name ?? model.rawValue
    }

    // MARK: Coding

    /// What an encoding is for.
    enum Format {
        /// UserDefaults: stored names only, plus `devices` and unknown top-level keys.
        case storage
        /// A shareable file: every model with a setup and its name, plus the 2.x mirror of the
        /// MX Vertical. Never `devices` or unknown keys, which describe this Mac.
        case export
    }

    /// Encodes the export format (see `Format.export`).
    struct ExportFile: Encodable {
        let library: MappingLibrary

        func encode(to encoder: Encoder) throws {
            try library.encode(to: encoder, format: .export)
        }
    }

    private static let knownKeys: Set<String> = ["schemaVersion", "models", "devices", "global", "apps"]

    private enum SectionKeys: String, CodingKey { case name, global, apps }

    /// One model's section: `MappingProfiles` without `schemaVersion`, plus `name`. A section
    /// with neither `global` nor `apps` only names the model.
    private struct Section: Decodable {
        var name: String?
        var profiles: MappingProfiles?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SectionKeys.self)
            let name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
            self.name = name?.isEmpty == false ? name : nil
            let hasSetup = container.contains(.global) || container.contains(.apps)
            profiles = hasSetup ? try MappingProfiles(from: decoder) : nil
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
            var seen: Set<ModelKey> = []
            for key in table.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                guard let model = ModelKey(rawValue: key.stringValue) else {
                    report?.note("models: skipped entry with invalid model “\(key.stringValue)”")
                    continue
                }
                do {
                    let section = try table.decode(Section.self, forKey: key)
                    if !seen.insert(model).inserted {
                        report?.note("models: merged duplicate entry for \(model.rawValue)")
                    }
                    if let profiles = section.profiles { models[model] = profiles }
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
        try encode(to: encoder, format: .storage)
    }

    func encode(to encoder: Encoder, format: Format) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(Self.schemaVersion, forKey: AnyCodingKey("schemaVersion"))

        var table = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("models"))
        let keys = format == .storage ? Set(models.keys).union(modelNames.keys) : Set(models.keys)
        for model in keys {
            var section = table.nestedContainer(keyedBy: SectionKeys.self, forKey: AnyCodingKey(model.rawValue))
            try section.encodeIfPresent(format == .storage ? modelNames[model] : name(of: model), forKey: .name)
            if let profiles = models[model] {
                try section.encode(profiles.global, forKey: .global)
                try section.encode(profiles.apps, forKey: .apps)
            }
        }

        switch format {
        case .storage:
            try container.encode(reservedDevices, forKey: AnyCodingKey("devices"))
            for (key, value) in unknownTopLevel where !Self.knownKeys.contains(key) {
                try container.encode(value, forKey: AnyCodingKey(key))
            }
        case .export:
            if let mirror = models[.mxVertical] {
                try container.encode(mirror.global, forKey: AnyCodingKey("global"))
                try container.encode(mirror.apps, forKey: AnyCodingKey("apps"))
            }
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
