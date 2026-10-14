import Foundation

/// Per-app button overrides. A button without an override uses the global mapping.
public struct AppProfile: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var displayName: String
    public var isEnabled: Bool
    /// Explicit per-button actions. `.deviceDefault` here means "native in this app",
    /// which differs from having no override (inherit the global mapping).
    public var overrides: [UInt16: ButtonAction]

    public var id: String { bundleID }

    public init(bundleID: String, displayName: String, isEnabled: Bool = true, overrides: [UInt16: ButtonAction] = [:]) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.overrides = overrides
    }

    /// The override for a button, or nil to inherit the global mapping.
    public subscript(cid: UInt16) -> ButtonAction? {
        get { overrides[cid] }
        set { overrides[cid] = newValue }
    }

    func matches(bundleID other: String) -> Bool {
        bundleID.caseInsensitiveCompare(other) == .orderedSame
    }

    private enum CodingKeys: String, CodingKey { case bundleID, displayName, isEnabled, overrides }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)).flatMap { $0 } ?? bundleID
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)).flatMap { $0 } ?? true
        if let table = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .overrides) {
            overrides = ActionTable.decode(from: table, report: decoder.mappingReport, context: bundleID)
        } else {
            if container.contains(.overrides) {
                decoder.mappingReport?.note("\(bundleID): skipped unreadable overrides")
            }
            overrides = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(isEnabled, forKey: .isEnabled)
        var table = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .overrides)
        try ActionTable.encode(overrides, to: &table)
    }
}

/// One model's setup: the global table plus per-app overrides.
///
/// This is the whole of what Upright 2.x saved and exported (schema 2). Since schema 3 it is the
/// per-model payload of a `MappingLibrary`, whose sections carry it without `schemaVersion`.
public struct MappingProfiles: Codable, Hashable, Sendable {
    /// Version written with a standalone encoding (the 2.x format). A `MappingLibrary` writes its
    /// own version instead.
    public static let schemaVersion = 2

    public var global: ButtonMappings
    public var apps: [AppProfile]

    public init(global: ButtonMappings = .defaults, apps: [AppProfile] = []) {
        self.global = global
        self.apps = []
        apps.forEach { upsert($0) }
    }

    /// The table that applies while `bundleID` is the frontmost app.
    public func effectiveMappings(forBundleID bundleID: String?) -> ButtonMappings {
        guard let profile = enabledProfile(forBundleID: bundleID) else { return global }
        return global.applying(profile.overrides)
    }

    public func enabledProfile(forBundleID bundleID: String?) -> AppProfile? {
        guard let bundleID, let profile = self[app: bundleID], profile.isEnabled else { return nil }
        return profile
    }

    /// True when there is nothing to apply: no global mapping and no app profile.
    public var isEmpty: Bool { global.isEmpty && apps.isEmpty }

    /// Every action the user has configured in the global table or an enabled app profile.
    public var allActiveActions: [ButtonAction] {
        Array(global.mappedControls.values) + apps.filter(\.isEnabled).flatMap { $0.overrides.values }
    }

    public subscript(app bundleID: String) -> AppProfile? {
        get { apps.first { $0.matches(bundleID: bundleID) } }
        set {
            guard let newValue else {
                removeApp(bundleID: bundleID)
                return
            }
            if let index = apps.firstIndex(where: { $0.matches(bundleID: bundleID) }) {
                apps[index] = newValue
            } else {
                upsert(newValue)
            }
        }
    }

    /// Adds a profile, or replaces the existing one for the same bundle ID in place.
    public mutating func upsert(_ profile: AppProfile) {
        if let index = apps.firstIndex(where: { $0.matches(bundleID: profile.bundleID) }) {
            apps[index] = profile
        } else {
            apps.append(profile)
        }
    }

    /// Adds an empty profile for an app (keeping an existing one) and returns it.
    @discardableResult
    public mutating func addApp(bundleID: String, displayName: String) -> AppProfile {
        if let existing = self[app: bundleID] { return existing }
        let profile = AppProfile(bundleID: bundleID, displayName: displayName)
        apps.append(profile)
        return profile
    }

    public mutating func removeApp(bundleID: String) {
        apps.removeAll { $0.matches(bundleID: bundleID) }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case schemaVersion, global, apps }

    /// Tolerant: a missing or unreadable global table becomes empty, and unreadable app profiles
    /// are skipped. Only a payload that isn't a JSON object at all fails.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let report = decoder.mappingReport
        let version = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)).flatMap { $0 }
        if let version, version > Self.schemaVersion {
            report?.note("written by a newer version (schema \(version)); reading what this version understands")
        }

        var global = ButtonMappings()
        if container.contains(.global) {
            do {
                global = try container.decode(ButtonMappings.self, forKey: .global)
            } catch {
                report?.note("global: skipped unreadable table (\(error.briefDescription))")
            }
        }

        var apps: [AppProfile] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .apps) {
            while !list.isAtEnd {
                let index = list.currentIndex
                guard let element = try? list.decode(Failable<AppProfile>.self) else { break }
                switch element.result {
                case .success(let profile): apps.append(profile)
                case .failure(let error): report?.note("apps[\(index)]: skipped unreadable profile (\(error.briefDescription))")
                }
            }
        } else if container.contains(.apps) {
            report?.note("apps: skipped unreadable list")
        }

        self.init(global: global, apps: apps)
        let duplicates = apps.count - self.apps.count
        if duplicates > 0 {
            report?.note("apps: merged \(duplicates) duplicate profile(s)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(global, forKey: .global)
        try container.encode(apps, forKey: .apps)
    }
}

/// Always decodes, so a bad element in an unkeyed container can be skipped without losing its place.
private struct Failable<Value: Decodable>: Decodable {
    let result: Result<Value, Error>

    init(from decoder: Decoder) throws {
        result = Result { try Value(from: decoder) }
    }
}
