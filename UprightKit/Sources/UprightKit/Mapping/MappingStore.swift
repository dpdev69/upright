import Foundation

/// Loads and saves `MappingProfiles` in UserDefaults, migrating Upright 1.x mappings and
/// backing up anything it can't read rather than silently discarding it.
public struct MappingStore {
    public static let profilesKey = "mappingProfiles.v2"
    public static let legacyKey = ButtonMappings.defaultsKey
    public static let backupKeyPrefix = "mappingProfiles.corruptBackup."

    /// Keys earlier versions of the app write. Any of them existing means this isn't a fresh install.
    public static let priorLaunchKeys = ["hasLaunchedBefore", "remappingEnabled", legacyKey]

    private let defaults: UserDefaults
    private let log: (String) -> Void
    private let now: () -> Date

    public init(defaults: UserDefaults, log: @escaping (String) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.log = log
        self.now = now
    }

    /// True when an earlier version of Upright has run with these defaults.
    public var hasPriorLaunch: Bool {
        Self.priorLaunchKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Reads the saved profiles, migrating or falling back as needed. Whatever it returns is
    /// also written back, so later launches take the plain path.
    public func load() -> MappingProfiles {
        let isUpgrade = hasPriorLaunch

        if let data = defaults.data(forKey: Self.profilesKey) {
            let report = MappingDecodingReport()
            if let profiles = try? Self.decoder(report: report).decode(MappingProfiles.self, from: data) {
                if !report.isClean {
                    report.issues.forEach { log("Mappings: \($0)") }
                    backUp(data, reason: "skipped \(report.issues.count) unreadable entr\(report.issues.count == 1 ? "y" : "ies")")
                    save(profiles)
                }
                return profiles
            }
            backUp(data, reason: "saved mappings could not be read")
            let profiles = MappingProfiles()
            save(profiles)
            return profiles
        }

        let profiles: MappingProfiles
        if let legacy = defaults.data(forKey: Self.legacyKey) {
            profiles = MappingProfiles(global: migrateLegacy(legacy))
        } else if isUpgrade {
            // 1.x never saved untouched defaults, so an upgrading user without saved data was using them.
            log("Mappings: no saved 1.x mappings; keeping the 1.x default setup")
            profiles = MappingProfiles(global: .legacyDefaults)
        } else {
            profiles = MappingProfiles()
        }
        save(profiles)
        return profiles
    }

    public func save(_ profiles: MappingProfiles) {
        do {
            defaults.set(try Self.encoder().encode(profiles), forKey: Self.profilesKey)
        } catch {
            log("Mappings: could not save (\(error))")
        }
    }

    /// Keys of every backup made so far, oldest first.
    public var backupKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.backupKeyPrefix) }.sorted()
    }

    private func migrateLegacy(_ data: Data) -> ButtonMappings {
        let report = MappingDecodingReport()
        guard let mappings = try? Self.decoder(report: report).decode(ButtonMappings.self, from: data) else {
            // 1.x fell back to its defaults when it couldn't read its table, so that's what this user had.
            backUp(data, reason: "1.x mappings could not be read")
            return .legacyDefaults
        }
        if !report.isClean {
            report.issues.forEach { log("Mappings: \($0)") }
            backUp(data, reason: "1.x mappings had unreadable entries")
        }
        log("Mappings: migrated \(mappings.mappedControls.count) mapping(s) from 1.x")
        return mappings
    }

    /// Stores raw mapping data under a new backup key and returns the key.
    @discardableResult
    public func backUp(_ data: Data, reason: String) -> String {
        let stamp = Int(now().timeIntervalSince1970)
        var key = Self.backupKeyPrefix + String(stamp)
        var suffix = 1
        while defaults.object(forKey: key) != nil {
            suffix += 1
            key = Self.backupKeyPrefix + "\(stamp)-\(suffix)"
        }
        defaults.set(data, forKey: key)
        log("Mappings: \(reason); raw data backed up to \(key)")
        return key
    }

    /// Backs up a set of profiles (in the saved format). Nil if they couldn't be encoded.
    @discardableResult
    public func backUp(_ profiles: MappingProfiles, reason: String) -> String? {
        do {
            return backUp(try Self.encoder().encode(profiles), reason: reason)
        } catch {
            log("Mappings: could not back up (\(error))")
            return nil
        }
    }

    /// Reads a backup made by `backUp`. Nil if the key holds nothing readable.
    public func loadBackup(_ key: String) -> MappingProfiles? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder(report: MappingDecodingReport()).decode(MappingProfiles.self, from: data)
    }

    // MARK: Export / import

    /// What an import would change to, read before anything is replaced.
    public struct ImportOutcome: Sendable {
        public let profiles: MappingProfiles
        /// Where the profiles the import replaces were backed up.
        public let backupKey: String?
        /// Imported actions that open apps, links or shortcuts, for the user to look over.
        public let actionsToReview: [ReviewItem]
    }

    /// An imported action that opens something outside Upright.
    public struct ReviewItem: Hashable, Sendable {
        public enum Slot: Hashable, Sendable {
            case button
            case gestureTap
            case gesture(GestureDirection)
        }

        /// Nil for the global table.
        public let bundleID: String?
        public let cid: UInt16
        public let slot: Slot
        public let action: ButtonAction
    }

    /// Reads an exported file meant to replace `current`, and backs `current` up first so the
    /// import can be undone. Throws (and backs up nothing) when the file can't be used.
    public func prepareImport(
        _ data: Data,
        replacing current: MappingProfiles,
        report: MappingDecodingReport = MappingDecodingReport()
    ) throws -> ImportOutcome {
        let imported = try Self.importData(data, report: report)
        let key = backUp(current, reason: "replacing mappings with an imported file")
        return ImportOutcome(profiles: imported, backupKey: key, actionsToReview: Self.actionsToReview(in: imported))
    }

    /// Every action, including gesture slots, that opens an app, a link or a shortcut:
    /// global first, then each app profile, by button.
    public static func actionsToReview(in profiles: MappingProfiles) -> [ReviewItem] {
        func items(_ actions: [UInt16: ButtonAction], bundleID: String?) -> [ReviewItem] {
            actions.sorted { $0.key < $1.key }.flatMap { cid, action -> [ReviewItem] in
                if case .gestures(let set) = action {
                    let slots: [(ReviewItem.Slot, ButtonAction)] = [(.gestureTap, set.tap)]
                        + GestureDirection.allCases.map { (.gesture($0), set[$0]) }
                    return slots.filter { $0.1.opensExternally }.map {
                        ReviewItem(bundleID: bundleID, cid: cid, slot: $0.0, action: $0.1)
                    }
                }
                return action.opensExternally ? [ReviewItem(bundleID: bundleID, cid: cid, slot: .button, action: action)] : []
            }
        }
        return items(profiles.global.mappedControls, bundleID: nil)
            + profiles.apps.flatMap { items($0.overrides, bundleID: $0.bundleID) }
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case unreadable
        case noMappings

        public var description: String {
            switch self {
            case .unreadable: return NSLocalizedString("The file isn’t an Upright mappings file.", comment: "Import error")
            case .noMappings: return NSLocalizedString("The file doesn’t contain any mappings Upright can use.", comment: "Import error")
            }
        }
    }

    /// Pretty-printed JSON with a schema version, suitable for sharing.
    public static func exportData(_ profiles: MappingProfiles) throws -> Data {
        try encoder(pretty: true).encode(profiles)
    }

    /// Reads an exported file (or a bare 1.x mapping table). Unreadable or invalid entries are
    /// dropped and listed in the report; primary clicks are never imported, so a shared file can't
    /// take away the left or right button, and links must be http, https or mailto. Throws
    /// `noMappings` when nothing usable is left, so an empty file can't wipe the current setup.
    public static func importData(_ data: Data, report: MappingDecodingReport = MappingDecodingReport()) throws -> MappingProfiles {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            throw ImportError.unreadable
        }
        var profiles: MappingProfiles
        if dictionary["schemaVersion"] != nil {
            guard let decoded = try? decoder(report: report).decode(MappingProfiles.self, from: data) else {
                throw ImportError.unreadable
            }
            profiles = decoded
        } else if dictionary["actions"] != nil, dictionary.count == 1 {
            guard let legacy = try? decoder(report: report).decode(ButtonMappings.self, from: data) else {
                throw ImportError.unreadable
            }
            profiles = MappingProfiles(global: legacy)
        } else {
            throw ImportError.unreadable
        }

        profiles.global = ButtonMappings(validated(profiles.global.mappedControls, context: "global", report: report))
        profiles.apps = profiles.apps.compactMap { profile in
            guard !profile.bundleID.trimmingCharacters(in: .whitespaces).isEmpty else {
                report.note("apps: skipped a profile without a bundle ID")
                return nil
            }
            var profile = profile
            profile.overrides = validated(profile.overrides, context: profile.bundleID, report: report)
            return profile
        }
        // Nothing to import (`{"schemaVersion":2}`, `{"actions":{}}`, or everything skipped): keep the current setup.
        if profiles.global.isEmpty, profiles.apps.isEmpty {
            throw ImportError.noMappings
        }
        return profiles
    }

    private static func validated(
        _ actions: [UInt16: ButtonAction],
        context: String,
        report: MappingDecodingReport
    ) -> [UInt16: ButtonAction] {
        actions.reduce(into: [:]) { result, entry in
            let (cid, action) = entry
            if KnownControl.primaryClicks.contains(cid) {
                report.note("\(context): skipped mapping for primary click control \(cid)")
                return
            }
            if !action.isValid {
                report.note("\(context): skipped invalid action for control \(cid)")
                return
            }
            if case .gestures(var set) = action {
                for slot in [\GestureSet.tap, \.up, \.down, \.left, \.right] where !isImportable(set[keyPath: slot]) {
                    report.note(unsupportedLinkNote(set[keyPath: slot], context: context, cid: cid))
                    set[keyPath: slot] = .disabled
                }
                result[cid] = .gestures(set)
                return
            }
            guard isImportable(action) else {
                report.note(unsupportedLinkNote(action, context: context, cid: cid))
                return
            }
            result[cid] = action
        }
    }

    /// Imported Open URL actions must use a web or mail link; see `ButtonAction.allowedURLSchemes`.
    private static func isImportable(_ action: ButtonAction) -> Bool {
        guard case .openURL(let url) = action else { return true }
        return ButtonAction.isAllowedURL(url)
    }

    private static func unsupportedLinkNote(_ action: ButtonAction, context: String, cid: UInt16) -> String {
        let scheme: String
        if case .openURL(let url) = action { scheme = url.scheme ?? "" } else { scheme = "" }
        return String(
            format: NSLocalizedString(
                "%1$@: skipped a link for control %2$d that uses “%3$@:” (only http, https and mailto links can be imported)",
                comment: "Import report entry; %1$@ is “global” or an app’s bundle ID, %2$d a control number, %3$@ a URL scheme such as file"
            ),
            context, Int(cid), scheme
        )
    }

    // MARK: Coders

    static func decoder(report: MappingDecodingReport) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.mappingReport] = report
        return decoder
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }
}
