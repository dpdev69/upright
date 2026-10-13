import Foundation

/// Loads and saves the `MappingLibrary` (schema 3) in UserDefaults, migrating Upright 2.x and 1.x
/// mappings into the MX Vertical's setup and backing up anything it can't read rather than
/// silently discarding it.
///
/// `loadLibrary()` takes the first of:
/// 1. `profilesKey` (`mappingProfiles.v3`).
/// 2. `v2Key` (2.x): copied once, byte for byte, to `preV3BackupKey`, then migrated into the MX
///    Vertical. The v2 key is never written or deleted, so a downgrade reads the last 2.x setup.
/// 3. `legacyKey` (1.x), migrated into the MX Vertical.
/// 4. An upgrade without saved data: the 1.x default setup on the MX Vertical.
/// 5. A fresh install: an empty library, so every mouse stays native.
public struct MappingStore {
    public static let profilesKey = "mappingProfiles.v3"
    /// Where 2.x saved its one setup. Read for migration only.
    public static let v2Key = "mappingProfiles.v2"
    /// A copy of the 2.x data, written once before the first v3 save.
    public static let preV3BackupKey = "mappingProfiles.v2.preV3Backup"
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

    // MARK: Load / save

    /// How `loadLibrary()` arrived at its library.
    public struct LoadReport: Hashable, Sendable {
        public enum Origin: Hashable, Sendable {
            /// Read from `profilesKey`.
            case library
            /// Migrated from 2.x (`v2Key`) into the MX Vertical.
            case migratedV2
            /// Migrated from 1.x (`legacyKey`) into the MX Vertical.
            case migratedV1
            /// An upgrade without saved data: the 1.x defaults on the MX Vertical.
            case upgradeDefaults
            case freshInstall
        }

        public var origin: Origin
        /// What couldn't be read and was left out (also logged).
        public var issues: [String]
        /// Raw data backed up during this load. The one-time `preV3BackupKey` copy isn't listed.
        public var backupKeys: [String]

        public init(origin: Origin, issues: [String] = [], backupKeys: [String] = []) {
            self.origin = origin
            self.issues = issues
            self.backupKeys = backupKeys
        }
    }

    /// Reads the saved library, migrating or falling back as needed (see the type's comment).
    /// A migrated, defaulted or cleaned-up library is also written back, so later launches take
    /// the plain path.
    public func loadLibrary() -> (library: MappingLibrary, report: LoadReport) {
        let isUpgrade = hasPriorLaunch
        var report = LoadReport(origin: .library)

        if let data = defaults.data(forKey: Self.profilesKey) {
            let decoding = MappingDecodingReport()
            guard let library = try? Self.decoder(report: decoding).decode(MappingLibrary.self, from: data) else {
                backUpUnreadable(data, reason: "saved mappings could not be read", into: &report)
                let library = MappingLibrary()
                save(library)
                return (library, report)
            }
            if !decoding.isClean {
                backUpSkipped(data, decoding, into: &report)
                save(library)
            }
            return (library, report)
        }

        let library: MappingLibrary
        if let data = defaults.data(forKey: Self.v2Key) {
            report.origin = .migratedV2
            library = MappingLibrary(migrating: migrateV2(data, report: &report))
        } else if let legacy = defaults.data(forKey: Self.legacyKey) {
            report.origin = .migratedV1
            library = MappingLibrary(migrating: MappingProfiles(global: migrateLegacy(legacy, report: &report)))
        } else if isUpgrade {
            // 1.x never saved untouched defaults, so an upgrading user without saved data was using them.
            report.origin = .upgradeDefaults
            log("Mappings: no saved 1.x mappings; keeping the 1.x default setup")
            library = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        } else {
            report.origin = .freshInstall
            library = MappingLibrary()
        }
        save(library)
        return (library, report)
    }

    /// The MX Vertical's setup, for callers that predate multi-mouse. Runs the same load (and
    /// migration) as `loadLibrary()`.
    public func load() -> MappingProfiles {
        loadLibrary().library[.mxVertical]
    }

    public func save(_ library: MappingLibrary) {
        do {
            defaults.set(try Self.encoder().encode(library), forKey: Self.profilesKey)
        } catch {
            log("Mappings: could not save (\(error))")
        }
    }

    /// Replaces only the MX Vertical's setup in the saved library, for callers that predate
    /// multi-mouse. Every other model is kept.
    public func save(_ profiles: MappingProfiles) {
        var library = savedLibrary() ?? MappingLibrary()
        library[.mxVertical] = profiles
        save(library)
    }

    /// The saved library as it is: no migration, logging or backups.
    private func savedLibrary() -> MappingLibrary? {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return nil }
        return try? Self.decoder(report: MappingDecodingReport()).decode(MappingLibrary.self, from: data)
    }

    private func migrateV2(_ data: Data, report: inout LoadReport) -> MappingProfiles {
        if defaults.object(forKey: Self.preV3BackupKey) == nil {
            defaults.set(data, forKey: Self.preV3BackupKey)
        }
        let decoding = MappingDecodingReport()
        guard let profiles = try? Self.decoder(report: decoding).decode(MappingProfiles.self, from: data) else {
            backUpUnreadable(data, reason: "saved 2.x mappings could not be read", into: &report)
            return MappingProfiles()
        }
        if !decoding.isClean {
            backUpSkipped(data, decoding, into: &report)
        }
        log("Mappings: moved the 2.x mappings to the MX Vertical; the 2.x copy is kept for downgrades")
        return profiles
    }

    private func migrateLegacy(_ data: Data, report: inout LoadReport) -> ButtonMappings {
        let decoding = MappingDecodingReport()
        guard let mappings = try? Self.decoder(report: decoding).decode(ButtonMappings.self, from: data) else {
            // 1.x fell back to its defaults when it couldn't read its table, so that's what this user had.
            backUpUnreadable(data, reason: "1.x mappings could not be read", into: &report)
            return .legacyDefaults
        }
        if !decoding.isClean {
            decoding.issues.forEach { log("Mappings: \($0)") }
            report.issues += decoding.issues
            report.backupKeys.append(backUp(data, reason: "1.x mappings had unreadable entries"))
        }
        log("Mappings: migrated \(mappings.mappedControls.count) mapping(s) from 1.x")
        return mappings
    }

    private func backUpUnreadable(_ data: Data, reason: String, into report: inout LoadReport) {
        report.issues.append(reason)
        report.backupKeys.append(backUp(data, reason: reason))
    }

    private func backUpSkipped(_ data: Data, _ decoding: MappingDecodingReport, into report: inout LoadReport) {
        let issues = decoding.issues
        issues.forEach { log("Mappings: \($0)") }
        report.issues += issues
        report.backupKeys.append(backUp(data, reason: "skipped \(issues.count) unreadable entr\(issues.count == 1 ? "y" : "ies")"))
    }

    // MARK: Backups

    /// Keys of every backup made so far, oldest first.
    public var backupKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.backupKeyPrefix) }.sorted()
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

    /// Backs up a library (in the saved format). Nil if it couldn't be encoded.
    @discardableResult
    public func backUp(_ library: MappingLibrary, reason: String) -> String? {
        do {
            return backUp(try Self.encoder().encode(library), reason: reason)
        } catch {
            log("Mappings: could not back up (\(error))")
            return nil
        }
    }

    /// Backs up one setup (in the 2.x format). Nil if it couldn't be encoded.
    @discardableResult
    public func backUp(_ profiles: MappingProfiles, reason: String) -> String? {
        do {
            return backUp(try Self.encoder().encode(profiles), reason: reason)
        } catch {
            log("Mappings: could not back up (\(error))")
            return nil
        }
    }

    /// Reads a backup made by `backUp` (either format; 2.x data becomes the MX Vertical's).
    /// Nil if the key holds nothing readable.
    public func loadLibraryBackup(_ key: String) -> MappingLibrary? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder(report: MappingDecodingReport()).decode(MappingLibrary.self, from: data)
    }

    /// The MX Vertical's setup in a backup made by `backUp`. Nil if the key holds nothing readable.
    public func loadBackup(_ key: String) -> MappingProfiles? {
        loadLibraryBackup(key)?[.mxVertical]
    }

    // MARK: Export / import

    /// An imported action that opens something outside Upright.
    public struct ReviewItem: Hashable, Sendable {
        public enum Slot: Hashable, Sendable {
            case button
            case gestureTap
            case gesture(GestureDirection)
        }

        /// The model whose setup holds the action.
        public let model: ModelKey
        public let modelName: String
        /// Nil for the global table.
        public let bundleID: String?
        public let cid: UInt16
        public let slot: Slot
        public let action: ButtonAction

        /// `modelName` defaults to the catalog's name for `model`.
        public init(
            model: ModelKey = .mxVertical,
            modelName: String? = nil,
            bundleID: String?,
            cid: UInt16,
            slot: Slot,
            action: ButtonAction
        ) {
            self.model = model
            self.modelName = modelName ?? MappingLibrary.catalogName(of: model)
            self.bundleID = bundleID
            self.cid = cid
            self.slot = slot
            self.action = action
        }
    }

    /// An import file read and validated, before anything is replaced.
    public struct ImportPreview: Hashable, Sendable {
        public enum Format: Hashable, Sendable {
            /// A schema 3 file: a setup per model, each replacing that model's own.
            case library
            /// A 2.x file or a 1.x table: one setup, made for the MX Vertical, imported into the
            /// model chosen in `prepareImport(_:targetModel:protecting:)`.
            case singleModel
        }

        public let format: Format
        /// The validated setups to import. Models the file leaves out (or whose setup had
        /// nothing usable) aren't listed and keep their current setup.
        public let models: [ModelKey: MappingProfiles]
        /// Names the file gives its models.
        public let modelNames: [ModelKey: String]
        /// Imported actions that open apps, links or shortcuts, for the user to look over.
        public let actionsToReview: [ReviewItem]
        /// Entries that couldn't be used and were left out.
        public let skipped: [String]

        /// The imported models, sorted by key.
        public var importedModels: [ModelKey] { models.keys.sorted() }

        /// `library` with every imported model's setup replaced and every other model kept.
        public func applied(to library: MappingLibrary) -> MappingLibrary {
            var result = library
            for (model, profiles) in models {
                result[model] = profiles
            }
            for (model, name) in modelNames where result.modelNames[model] == nil {
                result.modelNames[model] = name
            }
            return result
        }
    }

    /// Reads an exported file without changing anything. A schema 3 file is imported model by
    /// model; a 2.x file or 1.x table goes to `targetModel`. Entries are validated as by
    /// `importData(_:report:)`; `protected` adds, per model, controls the mouse needs for
    /// clicking (beyond `ControlCatalog.neverDivert`). Throws `ImportError` when the file
    /// can't be used.
    public func prepareImport(
        _ data: Data,
        targetModel: ModelKey,
        protecting protected: [ModelKey: Set<UInt16>] = [:]
    ) throws -> ImportPreview {
        try Self.preview(
            data,
            targetModel: targetModel,
            protected: protected,
            knownNames: savedLibrary()?.modelNames ?? [:],
            report: MappingDecodingReport()
        )
    }

    /// Applies a previewed import to `current`, backing `current` up first so the import can be
    /// undone.
    public func applyImport(_ preview: ImportPreview, to current: MappingLibrary) -> (library: MappingLibrary, backupKey: String?) {
        let key = backUp(current, reason: "replacing mappings with an imported file")
        return (preview.applied(to: current), key)
    }

    /// Pretty-printed JSON of every model's setup and name, plus the MX Vertical's setup at the
    /// top level for 2.x builds. Never the `devices` section. Empty (and logged) on failure.
    public func export(_ library: MappingLibrary) -> Data {
        do {
            return try Self.exportData(library)
        } catch {
            log("Mappings: could not export (\(error))")
            return Data()
        }
    }

    public static func exportData(_ library: MappingLibrary) throws -> Data {
        try encoder(pretty: true).encode(MappingLibrary.ExportFile(library: library))
    }

    // MARK: Single-model import (callers that predate multi-mouse)

    /// What an import would change to, read before anything is replaced.
    public struct ImportOutcome: Sendable {
        public let profiles: MappingProfiles
        /// Where the profiles the import replaces were backed up.
        public let backupKey: String?
        /// Imported actions that open apps, links or shortcuts, for the user to look over.
        public let actionsToReview: [ReviewItem]
    }

    /// Reads an exported file's MX Vertical setup to replace `current`, and backs `current` up
    /// first so the import can be undone. Throws (and backs up nothing) when the file can't be used.
    public func prepareImport(
        _ data: Data,
        replacing current: MappingProfiles,
        report: MappingDecodingReport = MappingDecodingReport()
    ) throws -> ImportOutcome {
        let imported = try Self.importData(data, report: report)
        let key = backUp(current, reason: "replacing mappings with an imported file")
        return ImportOutcome(profiles: imported, backupKey: key, actionsToReview: Self.actionsToReview(in: imported))
    }

    /// A file holding `profiles` as the MX Vertical's setup.
    public static func exportData(_ profiles: MappingProfiles) throws -> Data {
        try exportData(MappingLibrary(migrating: profiles))
    }

    /// Reads an exported file's MX Vertical setup (a 2.x file or 1.x table counts as one).
    /// Unreadable or invalid entries are dropped and listed in the report; primary clicks are
    /// never imported, so a shared file can't take away the left or right button, and links must
    /// be http, https or mailto. Throws `noMappings` when nothing usable is left, so an empty
    /// file can't wipe the current setup.
    public static func importData(_ data: Data, report: MappingDecodingReport = MappingDecodingReport()) throws -> MappingProfiles {
        let preview = try Self.preview(data, targetModel: .mxVertical, protected: [:], knownNames: [:], report: report)
        guard let profiles = preview.models[.mxVertical] else { throw ImportError.noMappings }
        return profiles
    }

    // MARK: Import helpers

    /// Every action, including gesture slots, that opens an app, a link or a shortcut:
    /// global first, then each app profile, by button.
    public static func actionsToReview(
        in profiles: MappingProfiles,
        model: ModelKey = .mxVertical,
        modelName: String? = nil
    ) -> [ReviewItem] {
        let modelName = modelName ?? MappingLibrary.catalogName(of: model)
        func items(_ actions: [UInt16: ButtonAction], bundleID: String?) -> [ReviewItem] {
            actions.sorted { $0.key < $1.key }.flatMap { cid, action -> [ReviewItem] in
                func item(_ slot: ReviewItem.Slot, _ action: ButtonAction) -> ReviewItem {
                    ReviewItem(model: model, modelName: modelName, bundleID: bundleID, cid: cid, slot: slot, action: action)
                }
                if case .gestures(let set) = action {
                    let slots: [(ReviewItem.Slot, ButtonAction)] = [(.gestureTap, set.tap)]
                        + GestureDirection.allCases.map { (.gesture($0), set[$0]) }
                    return slots.filter { $0.1.opensExternally }.map { item($0.0, $0.1) }
                }
                return action.opensExternally ? [item(.button, action)] : []
            }
        }
        return items(profiles.global.mappedControls, bundleID: nil)
            + profiles.apps.flatMap { items($0.overrides, bundleID: $0.bundleID) }
    }

    /// `actionsToReview(in:model:modelName:)` for every model, by model key.
    public static func actionsToReview(in library: MappingLibrary) -> [ReviewItem] {
        library.models.keys.sorted().flatMap { model in
            actionsToReview(in: library[model], model: model, modelName: library.name(of: model))
        }
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

    /// An import file before validation.
    private enum ImportFile {
        /// Schema 3: has `models`.
        case library(MappingLibrary)
        /// A 2.x file (has `schemaVersion`) or a bare 1.x table.
        case singleModel(MappingProfiles)
    }

    private static func readImport(_ data: Data, report: MappingDecodingReport) throws -> ImportFile {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            throw ImportError.unreadable
        }
        if dictionary["models"] != nil {
            guard let library = try? decoder(report: report).decode(MappingLibrary.self, from: data) else {
                throw ImportError.unreadable
            }
            return .library(library)
        }
        if dictionary["schemaVersion"] != nil {
            guard let profiles = try? decoder(report: report).decode(MappingProfiles.self, from: data) else {
                throw ImportError.unreadable
            }
            return .singleModel(profiles)
        }
        if dictionary["actions"] != nil, dictionary.count == 1 {
            guard let legacy = try? decoder(report: report).decode(ButtonMappings.self, from: data) else {
                throw ImportError.unreadable
            }
            return .singleModel(MappingProfiles(global: legacy))
        }
        throw ImportError.unreadable
    }

    private static func preview(
        _ data: Data,
        targetModel: ModelKey,
        protected: [ModelKey: Set<UInt16>],
        knownNames: [ModelKey: String],
        report: MappingDecodingReport
    ) throws -> ImportPreview {
        let format: ImportPreview.Format
        var sections: [ModelKey: MappingProfiles] = [:]
        var fileNames: [ModelKey: String] = [:]
        func displayName(_ model: ModelKey) -> String {
            fileNames[model] ?? knownNames[model] ?? MappingLibrary.catalogName(of: model)
        }

        switch try readImport(data, report: report) {
        case .library(let library):
            format = .library
            for (model, profiles) in library.models.sorted(by: { $0.key < $1.key }) {
                if let name = library.modelNames[model], name != model.rawValue {
                    fileNames[model] = name
                }
                let usable = validated(profiles, label: displayName(model), protected: protected[model] ?? [], report: report)
                if !usable.isEmpty { sections[model] = usable }
            }
        case .singleModel(let profiles):
            format = .singleModel
            let usable = validated(profiles, label: nil, protected: protected[targetModel] ?? [], report: report)
            if !usable.isEmpty { sections[targetModel] = usable }
        }
        // Nothing to import (`{"schemaVersion":2}`, `{"actions":{}}`, or everything skipped): keep the current setup.
        guard !sections.isEmpty else { throw ImportError.noMappings }

        let review = sections.keys.sorted().flatMap { model in
            actionsToReview(in: sections[model] ?? MappingProfiles(), model: model, modelName: displayName(model))
        }
        return ImportPreview(
            format: format,
            models: sections,
            modelNames: fileNames.filter { sections[$0.key] != nil },
            actionsToReview: review,
            skipped: report.issues
        )
    }

    /// `profiles` with unusable entries dropped and noted. `label` (a model name) prefixes the
    /// notes of a schema 3 file; single-model files keep the 2.x wording.
    private static func validated(
        _ profiles: MappingProfiles,
        label: String?,
        protected: Set<UInt16>,
        report: MappingDecodingReport
    ) -> MappingProfiles {
        func context(_ scope: String) -> String { label.map { "\($0) · \(scope)" } ?? scope }
        var profiles = profiles
        profiles.global = ButtonMappings(validated(profiles.global.mappedControls, context: context("global"), protected: protected, report: report))
        profiles.apps = profiles.apps.compactMap { profile in
            guard !profile.bundleID.trimmingCharacters(in: .whitespaces).isEmpty else {
                report.note("\(context("apps")): skipped a profile without a bundle ID")
                return nil
            }
            var profile = profile
            profile.overrides = validated(profile.overrides, context: context(profile.bundleID), protected: protected, report: report)
            return profile
        }
        return profiles
    }

    private static func validated(
        _ actions: [UInt16: ButtonAction],
        context: String,
        protected: Set<UInt16>,
        report: MappingDecodingReport
    ) -> [UInt16: ButtonAction] {
        actions.reduce(into: [:]) { result, entry in
            let (cid, action) = entry
            if ControlCatalog.neverDivert.contains(cid) {
                report.note("\(context): skipped mapping for primary click control \(cid)")
                return
            }
            if protected.contains(cid) {
                report.note("\(context): skipped mapping for control \(cid), which the mouse needs for clicking")
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
