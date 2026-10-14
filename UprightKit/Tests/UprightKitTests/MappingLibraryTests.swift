import XCTest
@testable import UprightKit

private let master = ModelKey(productID: 0xB034)
private let lift = ModelKey(productID: 0xB031)
private let prototype = ModelKey(productID: 0xABCD)

/// A 2.x save (`MappingProfiles` encoded by `MappingStore.encoder()`) with every action kind, a
/// full gesture set, `.deviceDefault` and gesture overrides, a disabled profile and a mixed-case
/// bundle ID.
private let everyKindV2 = #"""
{"apps":[{"bundleID":"com.apple.Safari","displayName":"Safari","isEnabled":true,"overrides":{"253":{"deviceDefault":{}},"83":{"system":{"_0":"previousTab"}},"86":{"gestures":{"_0":{"down":{"deviceDefault":{}},"left":{"disabled":{}},"right":{"disabled":{}},"tap":{"disabled":{}},"up":{"system":{"_0":"nextTab"}}}}}}},{"bundleID":"com.apple.dt.Xcode","displayName":"Xcode","isEnabled":false,"overrides":{"83":{"keyCombo":{"_0":{"keyCode":17,"keyLabel":"T","modifiers":12}}}}},{"bundleID":"com.Example.MixedCase","displayName":"Mixed","isEnabled":true,"overrides":{"195":{"deviceDefault":{}},"82":{"system":{"_0":"copy"}}}}],"global":{"actions":{"195":{"device":{"_0":{"cycleDPI":{}}}},"196":{"device":{"_0":{"setDPI":{"_0":1200}}}},"208":{"openURL":{"_0":"mailto:me@example.com"}},"237":{"runShortcut":{"_0":"Toggle Focus"}},"253":{"gestures":{"_0":{"down":{"launchApp":{"_0":{"bundleID":"com.apple.Terminal","displayName":"Terminal"}}},"left":{"openURL":{"_0":"https:\/\/example.com\/left?a=b"}},"right":{"runShortcut":{"_0":"Make GIF"}},"tap":{"system":{"_0":"missionControl"}},"up":{"keyCombo":{"_0":{"keyCode":8,"keyLabel":"C","modifiers":10}}}}}},"256":{"system":{"_0":"volumeUp"}},"257":{"system":{"_0":"middleClick"}},"258":{"system":{"_0":"appExpose"}},"82":{"disabled":{}},"83":{"system":{"_0":"navigateBack"}},"86":{"keyCombo":{"_0":{"keyCode":17,"keyLabel":"T","modifiers":12}}},"91":{"device":{"_0":{"switchHost":{"_0":2}}}},"93":{"launchApp":{"_0":{"bundleID":"com.apple.Safari","displayName":"Safari"}}}}},"schemaVersion":2}
"""#

/// `everyKindV2`, built in code.
private var everyKindProfiles: MappingProfiles {
    let combo = KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T")
    let gestures = GestureSet(
        tap: .system(.missionControl),
        up: .keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: [.command, .option])),
        down: .launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal")),
        left: .openURL(URL(string: "https://example.com/left?a=b")!),
        right: .runShortcut("Make GIF")
    )
    var profiles = MappingProfiles(global: ButtonMappings([
        KnownControl.back: .system(.navigateBack),
        KnownControl.forward: .keyCombo(combo),
        KnownControl.middleClick: .disabled,
        KnownControl.dpiSwitch: .gestures(gestures),
        KnownControl.gestureButton: .device(.cycleDPI),
        KnownControl.smartShift: .device(.setDPI(1200)),
        KnownControl.tiltLeft: .device(.switchHost(2)),
        KnownControl.tiltRight: .launchApp(AppReference(bundleID: "com.apple.Safari", displayName: "Safari")),
        KnownControl.multiPlatformGesture: .openURL(URL(string: "mailto:me@example.com")!),
        KnownControl.dpiChange: .runShortcut("Toggle Focus"),
        0x0100: .system(.volumeUp),
        0x0101: .system(.middleClick),
        0x0102: .system(.appExpose),
    ]))
    profiles.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
        KnownControl.back: .system(.previousTab),
        KnownControl.dpiSwitch: .deviceDefault,
        KnownControl.forward: .gestures(GestureSet(up: .system(.nextTab), down: .deviceDefault)),
    ]))
    profiles.upsert(AppProfile(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isEnabled: false, overrides: [
        KnownControl.back: .keyCombo(combo),
    ]))
    profiles.upsert(AppProfile(bundleID: "com.Example.MixedCase", displayName: "Mixed", overrides: [
        KnownControl.middleClick: .system(.copy),
        KnownControl.gestureButton: .deviceDefault,
    ]))
    return profiles
}

/// Every v2 payload in MappingPersistenceTests and ProfileTests, as 2.x would have read it from
/// `mappingProfiles.v2`.
private let existingV2Fixtures: [(name: String, json: String)] = [
    ("newer schema with unknown entries", #"{"schemaVersion":4,"global":{"actions":{"83":{"system":{"_0":"teleport"}},"86":{"warp":{"_0":{}}},"253":{"system":{"_0":"missionControl"}}}},"apps":[{"bundleID":"com.example","overrides":{"83":{"system":{"_0":"copy"}}}},{"nope":true},{"bundleID":"com.example.b","overrides":{"83":{"hologram":{}}}}]}"#),
    ("skipped entries", #"{"schemaVersion":2,"global":{"actions":{"83":{"system":{"_0":"teleport"}},"86":{"disabled":{}}}},"apps":[]}"#),
    ("dangerous entries", #"{"schemaVersion":2,"global":{"actions":{"80":{"disabled":{}},"83":{"runShortcut":{"_0":""}},"86":{"device":{"_0":{"setDPI":{"_0":99999}}}},"253":{"device":{"_0":{"cycleDPI":{}}}}}},"apps":[{"bundleID":"  ","overrides":{}}]}"#),
    ("version only", #"{"schemaVersion":2}"#),
    ("empty tables", #"{"schemaVersion":2,"global":{"actions":{}},"apps":[]}"#),
    ("app only", #"{"schemaVersion":2,"apps":[{"bundleID":"com.apple.Safari","overrides":{}}]}"#),
    ("unknown action only", #"{"schemaVersion":2,"global":{"actions":{"83":{"zap":{}}}}}"#),
    ("links", #"""
    {"schemaVersion":2,"global":{"actions":{
        "83":{"openURL":{"_0":"file:///Users/me/Downloads/x.command"}},
        "86":{"openURL":{"_0":"mailto:me@example.com"}},
        "82":{"openURL":{"_0":"HTTPS://example.com"}},
        "253":{"gestures":{"_0":{"up":{"openURL":{"_0":"http://example.com"}},"down":{"openURL":{"_0":"vnc://host"}}}}}
    }},"apps":[{"bundleID":"com.apple.Safari","overrides":{"83":{"openURL":{"_0":"javascript:alert(1)"}}}}]}
    """#),
    ("duplicate profiles", #"{"schemaVersion":2,"global":{"actions":{}},"apps":[{"bundleID":"a","displayName":"A","isEnabled":true,"overrides":{}},{"bundleID":"A","displayName":"A2","isEnabled":true,"overrides":{}}]}"#),
    ("every kind", everyKindV2),
]

/// The setups the existing suites build in code, saved as 2.x saved them.
private var existingV2Setups: [(name: String, profiles: MappingProfiles)] {
    let combo = KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T")
    var profileTests = MappingProfiles(global: .legacyDefaults)
    profileTests.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
        KnownControl.back: .system(.previousTab),
        KnownControl.dpiSwitch: .deviceDefault,
    ]))
    profileTests.upsert(AppProfile(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isEnabled: false, overrides: [
        KnownControl.back: .system(.undo),
    ]))
    var roundTrip = MappingProfiles()
    roundTrip.global[KnownControl.back] = .keyCombo(combo)
    roundTrip.addApp(bundleID: "com.apple.Safari", displayName: "Safari")
    roundTrip[app: "com.apple.Safari"]?[KnownControl.back] = .deviceDefault
    var export = MappingProfiles(global: .legacyDefaults)
    export.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
        KnownControl.back: .openURL(URL(string: "https://example.com/path")!),
    ]))
    var review = MappingProfiles(global: ButtonMappings([
        KnownControl.back: .system(.navigateBack),
        KnownControl.forward: .runShortcut("Make GIF"),
        KnownControl.dpiSwitch: .gestures(GestureSet(
            tap: .openURL(URL(string: "https://example.com")!),
            up: .system(.missionControl),
            left: .launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal"))
        )),
    ]))
    review.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
        KnownControl.back: .launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal")),
    ]))
    return [
        ("ProfileTests.profiles", profileTests),
        ("testSaveAndLoadRoundTrip", roundTrip),
        ("testExportIsPrettyVersionedJSONAndImportsBack", export),
        ("testImportListsExternalActionsForReview", review),
        ("legacy defaults", MappingProfiles(global: .legacyDefaults)),
        ("fresh", MappingProfiles()),
    ]
}

private let v1Table = #"{"actions":{"83":{"system":{"_0":"navigateBack"}},"86":{"keyCombo":{"_0":{"keyCode":17,"keyLabel":"T","modifiers":12}}},"82":{"disabled":{}}}}"#

private struct SchemaVersion: Decodable {
    let schemaVersion: Int
}

final class MappingLibraryTests: XCTestCase {
    private var suites: [(name: String, defaults: UserDefaults)] = []
    private var defaults: UserDefaults!
    private var logged: [String] = []

    override func setUpWithError() throws {
        logged = []
        defaults = try makeDefaults()
    }

    override func tearDown() {
        suites.forEach { $0.defaults.removePersistentDomain(forName: $0.name) }
        suites = []
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "UprightLibraryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        suites.append((name, defaults))
        return defaults
    }

    private func makeStore(_ defaults: UserDefaults? = nil) -> MappingStore {
        MappingStore(defaults: defaults ?? self.defaults, log: { [unowned self] in logged.append($0) }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func schemaVersion(_ data: Data?) throws -> Int {
        try JSONDecoder().decode(SchemaVersion.self, from: XCTUnwrap(data)).schemaVersion
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Migration

    func testV2MigratesToMXVerticalEquivalentForEveryBundle() throws {
        // The literal fixture is exactly what 2.x saved for `everyKindProfiles`.
        XCTAssertEqual(try MappingStore.decoder(report: MappingDecodingReport()).decode(MappingProfiles.self, from: Data(everyKindV2.utf8)), everyKindProfiles)

        var fixtures = existingV2Fixtures.map { ($0.name, Data($0.json.utf8)) }
        for setup in existingV2Setups {
            fixtures.append((setup.name, try MappingStore.encoder().encode(setup.profiles)))
        }
        XCTAssertEqual(fixtures.count, 16)

        for (name, data) in fixtures {
            // What 2.x's load returned for this data.
            let today = try MappingStore.decoder(report: MappingDecodingReport()).decode(MappingProfiles.self, from: data)

            let defaults = try makeDefaults()
            defaults.set(data, forKey: MappingStore.v2Key)
            let (library, report) = makeStore(defaults).loadLibrary()
            XCTAssertEqual(report.origin, .migratedV2, name)
            XCTAssertEqual(Array(library.models.keys), [.mxVertical], name)
            XCTAssertEqual(library[.mxVertical], today, name)

            let (reloaded, again) = makeStore(defaults).loadLibrary()
            XCTAssertEqual(again.origin, .library, name)
            XCTAssertTrue(again.backupKeys.isEmpty, name)
            XCTAssertEqual(reloaded, library, name)

            let bundles: [String?] = [nil, "", "com.example.unknown"]
                + today.apps.flatMap { [$0.bundleID, $0.bundleID.uppercased(), $0.bundleID.lowercased()] }
            for bundleID in bundles {
                let expected = today.effectiveMappings(forBundleID: bundleID)
                for candidate in [library, reloaded] {
                    let effective = candidate.effectiveMappings(model: .mxVertical, bundleID: bundleID)
                    XCTAssertEqual(effective, expected, "\(name) / \(bundleID ?? "nil")")
                    for trusted in [false, true] {
                        XCTAssertEqual(effective.divertedControls(accessibilityGranted: trusted), expected.divertedControls(accessibilityGranted: trusted), name)
                        XCTAssertEqual(effective.gestureControls(accessibilityGranted: trusted), expected.gestureControls(accessibilityGranted: trusted), name)
                    }
                    // Every other model, connected or not, stays native.
                    XCTAssertTrue(candidate.effectiveMappings(model: master, bundleID: bundleID).isEmpty, name)
                }
            }
            XCTAssertEqual(library.allActiveActions.count, today.allActiveActions.count, name)
            XCTAssertEqual(Set(library.allActiveActions), Set(today.allActiveActions), name)
            XCTAssertEqual(
                library.allActiveActions.contains { $0.requiresAccessibility },
                today.allActiveActions.contains { $0.requiresAccessibility },
                name
            )
        }
    }

    func testV2WithUnreadableEntriesIsBackedUpThenMigrated() throws {
        let raw = Data(existingV2Fixtures[1].json.utf8)
        defaults.set(raw, forKey: MappingStore.v2Key)
        let store = makeStore()
        let (library, report) = store.loadLibrary()
        XCTAssertEqual(library[.mxVertical].global, ButtonMappings([KnownControl.forward: .disabled]))
        XCTAssertEqual(report.issues.count, 1, "\(report.issues)")
        XCTAssertEqual(report.backupKeys, store.backupKeys)
        XCTAssertEqual(store.backupKeys.count, 1)
        XCTAssertEqual(store.backupKeys.first.flatMap { defaults.data(forKey: $0) }, raw)
        XCTAssertEqual(defaults.data(forKey: MappingStore.preV3BackupKey), raw)

        XCTAssertEqual(makeStore().loadLibrary().library, library)
        XCTAssertEqual(store.backupKeys.count, 1)
    }

    func testUnreadableV2IsBackedUpAndMigratesEmpty() throws {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: MappingStore.v2Key)
        defaults.set(Data(v1Table.utf8), forKey: MappingStore.legacyKey)
        let store = makeStore()
        let (library, report) = store.loadLibrary()
        // As in 2.x: unreadable saved mappings start over empty, without falling back to 1.x data.
        XCTAssertEqual(report.origin, .migratedV2)
        XCTAssertTrue(library.effectiveMappings(model: .mxVertical, bundleID: nil).isEmpty)
        XCTAssertEqual(store.backupKeys.count, 1)
        XCTAssertEqual(defaults.data(forKey: MappingStore.preV3BackupKey), garbage)
        XCTAssertEqual(defaults.data(forKey: MappingStore.v2Key), garbage)
    }

    func testV1LegacyMigratesIntoMXVertical() throws {
        defaults.set(Data(v1Table.utf8), forKey: MappingStore.legacyKey)
        let (library, report) = makeStore().loadLibrary()
        XCTAssertEqual(report.origin, .migratedV1)
        XCTAssertEqual(Array(library.models.keys), [.mxVertical])
        XCTAssertEqual(library[.mxVertical], MappingProfiles(global: try JSONDecoder().decode(ButtonMappings.self, from: Data(v1Table.utf8))))
        XCTAssertEqual(library.name(of: .mxVertical), "MX Vertical")
        // The 1.x key stays for downgrades; nothing is written under the 2.x keys.
        XCTAssertEqual(defaults.data(forKey: MappingStore.legacyKey), Data(v1Table.utf8))
        XCTAssertNil(defaults.object(forKey: MappingStore.v2Key))
        XCTAssertNil(defaults.object(forKey: MappingStore.preV3BackupKey))
        XCTAssertEqual(makeStore().loadLibrary().library, library)
    }

    func testUpgradeWithoutDataGivesLegacyDefaultsOnMXVertical() throws {
        defaults.set(true, forKey: "hasLaunchedBefore")
        let (library, report) = makeStore().loadLibrary()
        XCTAssertEqual(report.origin, .upgradeDefaults)
        XCTAssertEqual(library[.mxVertical], MappingProfiles(global: .legacyDefaults))
        XCTAssertTrue(library.effectiveMappings(model: master, bundleID: nil).isEmpty)
        XCTAssertNil(defaults.object(forKey: MappingStore.v2Key))
        XCTAssertEqual(makeStore().loadLibrary().report.origin, .library)
    }

    func testFreshInstallIsEmptyForEveryModel() throws {
        let store = makeStore()
        XCTAssertFalse(store.hasPriorLaunch)
        let (library, report) = store.loadLibrary()
        XCTAssertEqual(report.origin, .freshInstall)
        XCTAssertEqual(library, MappingLibrary())
        for model in [ModelKey.mxVertical, master, lift, ModelKey(name: "Some Mouse")] {
            XCTAssertTrue(library.effectiveMappings(model: model, bundleID: nil).isEmpty)
            XCTAssertTrue(library.effectiveMappings(model: model, bundleID: "com.apple.Safari").isEmpty)
        }
        XCTAssertTrue(library.allActiveActions.isEmpty)

        // Saved, so the next launch (now with prior-launch markers) doesn't switch to the 1.x defaults.
        defaults.set(true, forKey: "hasLaunchedBefore")
        let next = makeStore().loadLibrary()
        XCTAssertEqual(next.report.origin, .library)
        XCTAssertEqual(next.library, library)
        XCTAssertNil(defaults.object(forKey: MappingStore.v2Key))
        XCTAssertTrue(store.backupKeys.isEmpty)
    }

    func testV2KeyNeverWrittenAfterMigration() throws {
        let original = try MappingStore.encoder().encode(everyKindProfiles)
        defaults.set(original, forKey: MappingStore.v2Key)
        let store = makeStore()
        var library = store.loadLibrary().library

        library[.mxVertical].global[KnownControl.back] = .system(.copy)
        library[master] = MappingProfiles(global: ButtonMappings([KnownControl.forward: .disabled]))
        store.save(library)
        store.save(MappingProfiles(global: .legacyDefaults))
        _ = store.load()
        _ = store.loadLibrary()

        XCTAssertEqual(defaults.data(forKey: MappingStore.v2Key), original)
        XCTAssertEqual(defaults.data(forKey: MappingStore.preV3BackupKey), original)
        let saved = store.loadLibrary().library
        XCTAssertEqual(saved[.mxVertical].global, .legacyDefaults)
        XCTAssertEqual(saved[master], library[master])

        // Once a library exists it wins, even if a downgraded build changes the 2.x data later.
        defaults.set(Data(#"{"schemaVersion":2,"global":{"actions":{}},"apps":[]}"#.utf8), forKey: MappingStore.v2Key)
        XCTAssertEqual(makeStore().loadLibrary().library, saved)
    }

    func testPreV3BackupWrittenOnce() throws {
        let first = try MappingStore.encoder().encode(MappingProfiles(global: .legacyDefaults))
        defaults.set(first, forKey: MappingStore.v2Key)
        let store = makeStore()
        XCTAssertNil(defaults.object(forKey: MappingStore.preV3BackupKey))
        _ = store.loadLibrary()
        XCTAssertEqual(defaults.data(forKey: MappingStore.preV3BackupKey), first)
        // It isn't one of the corrupt-data backups.
        XCTAssertTrue(store.backupKeys.isEmpty)

        // A second migration (the library was removed and 2.x data changed) keeps the first copy.
        let second = try MappingStore.encoder().encode(MappingProfiles(global: ButtonMappings([KnownControl.back: .disabled])))
        defaults.removeObject(forKey: MappingStore.profilesKey)
        defaults.set(second, forKey: MappingStore.v2Key)
        let library = store.loadLibrary().library
        XCTAssertEqual(library[.mxVertical].global, ButtonMappings([KnownControl.back: .disabled]))
        XCTAssertEqual(defaults.data(forKey: MappingStore.preV3BackupKey), first)
    }

    func testCorruptLibraryIsBackedUpAndStartsEmpty() throws {
        let garbage = Data("{\"models\":".utf8)
        defaults.set(garbage, forKey: MappingStore.profilesKey)
        let v2 = try MappingStore.encoder().encode(MappingProfiles(global: .legacyDefaults))
        defaults.set(v2, forKey: MappingStore.v2Key)
        let store = makeStore()
        let (library, report) = store.loadLibrary()
        // First match wins: the 2.x data was already migrated once and isn't read again.
        XCTAssertEqual(report.origin, .library)
        XCTAssertEqual(library, MappingLibrary())
        XCTAssertEqual(report.issues, ["saved mappings could not be read"])
        XCTAssertEqual(report.backupKeys, [MappingStore.backupKeyPrefix + "1700000000"])
        XCTAssertEqual(defaults.data(forKey: MappingStore.backupKeyPrefix + "1700000000"), garbage)
        XCTAssertEqual(defaults.data(forKey: MappingStore.v2Key), v2)
        XCTAssertFalse(logged.isEmpty)
        XCTAssertEqual(makeStore().loadLibrary().library, MappingLibrary())
    }

    // MARK: Schema 3

    func testRoundTripPreservesUnknownModelsDevicesAndTopLevel() throws {
        let stored = #"""
        {"schemaVersion":3,
         "models":{
           "046D:B020":{"name":"MX Vertical","global":{"actions":{"83":{"system":{"_0":"navigateBack"}}}},"apps":[]},
           "046d:abcd":{"name":"Prototype","global":{"actions":{"86":{"disabled":{}}}},"apps":[{"bundleID":"com.apple.Safari","displayName":"Safari","isEnabled":true,"overrides":{"86":{"deviceDefault":{}}}}]},
           "name:mystery mouse":{"global":{"actions":{"82":{"system":{"_0":"copy"}}}},"apps":[]},
           "046D:B034":{"name":"Desk mouse"}
         },
         "devices":{"u:046D:B020:1A2B3C4D":{"nickname":"Desk","remap":false,"dpi":1600,"ratio":0.5,"tags":["a",null,true]}},
         "futureFeature":{"enabled":true,"levels":[1,2,3]},
         "note":"hello"}
        """#
        defaults.set(Data(stored.utf8), forKey: MappingStore.profilesKey)
        let store = makeStore()
        let (library, report) = store.loadLibrary()
        XCTAssertEqual(report.origin, .library)
        XCTAssertTrue(report.issues.isEmpty, "\(report.issues)")
        XCTAssertTrue(store.backupKeys.isEmpty)

        let mystery = ModelKey(name: "Mystery Mouse")
        XCTAssertEqual(Set(library.models.keys), [.mxVertical, prototype, mystery])
        XCTAssertEqual(library.modelNames, [.mxVertical: "MX Vertical", prototype: "Prototype", master: "Desk mouse"])
        XCTAssertEqual(library.name(of: master), "Desk mouse")
        XCTAssertEqual(library.name(of: mystery), "name:mystery mouse")
        XCTAssertEqual(library.effectiveMappings(model: prototype, bundleID: "com.apple.Safari")[KnownControl.forward], .deviceDefault)
        XCTAssertEqual(library.effectiveMappings(model: mystery, bundleID: nil)[KnownControl.middleClick], .system(.copy))
        XCTAssertEqual(library.reservedDevices, ["u:046D:B020:1A2B3C4D": .object([
            "nickname": .string("Desk"),
            "remap": .bool(false),
            "dpi": .number(1600),
            "ratio": .number(0.5),
            "tags": .array([.string("a"), .null, .bool(true)]),
        ])])
        XCTAssertEqual(library.unknownTopLevel, [
            "futureFeature": .object(["enabled": .bool(true), "levels": .array([.number(1), .number(2), .number(3)])]),
            "note": .string("hello"),
        ])

        store.save(library)
        XCTAssertEqual(makeStore().loadLibrary().library, library)
        XCTAssertEqual(try schemaVersion(defaults.data(forKey: MappingStore.profilesKey)), 3)
        let saved = try json(defaults.data(forKey: MappingStore.profilesKey))
        XCTAssertNotNil(saved["devices"])
        XCTAssertNotNil(saved["futureFeature"])
        XCTAssertNil(saved["global"], "the 2.x mirror is for exports only")
        let models = try XCTUnwrap(saved["models"] as? [String: Any])
        XCTAssertEqual(Set(models.keys), ["046D:B020", "046D:ABCD", "name:mystery mouse", "046D:B034"])
        XCTAssertEqual((models["046D:B034"] as? [String: Any])?.keys.sorted(), ["name"])
        XCTAssertNil((models["name:mystery mouse"] as? [String: Any])?["name"], "only stored names are saved")
    }

    func testNewerSchemaNoteAndBackup() throws {
        let newer = Data(#"{"schemaVersion":4,"models":{"046D:B020":{"name":"MX Vertical","global":{"actions":{"83":{"system":{"_0":"navigateBack"}},"86":{"hologram":{}}}},"apps":[]}},"devices":{},"perUnitOverrides":{"x":1}}"#.utf8)
        defaults.set(newer, forKey: MappingStore.profilesKey)
        let store = makeStore()
        let (library, report) = store.loadLibrary()
        XCTAssertEqual(report.issues.count, 2, "\(report.issues)")
        XCTAssertTrue(report.issues[0].contains("newer version (schema 4)"), report.issues[0])
        XCTAssertEqual(store.backupKeys.count, 1)
        XCTAssertEqual(store.backupKeys.first.flatMap { defaults.data(forKey: $0) }, newer)
        XCTAssertEqual(library[.mxVertical].global, ButtonMappings([KnownControl.back: .system(.navigateBack)]))
        XCTAssertEqual(library.unknownTopLevel, ["perUnitOverrides": .object(["x": .number(1)])])

        // Rewritten as schema 3 (keeping what it understood), so the next launch reads it cleanly.
        XCTAssertEqual(try schemaVersion(defaults.data(forKey: MappingStore.profilesKey)), 3)
        let next = makeStore().loadLibrary()
        XCTAssertTrue(next.report.issues.isEmpty)
        XCTAssertEqual(next.library, library)
        XCTAssertEqual(store.backupKeys.count, 1)
    }

    func testInvalidAndDuplicateModelKeysAreNoted() throws {
        let data = Data(#"{"schemaVersion":3,"models":{"nonsense":{"global":{"actions":{}}},"046d:b020":{"global":{"actions":{"83":{"disabled":{}}}}},"046D:B020":{"global":{"actions":{"86":{"disabled":{}}}}},"046D:B034":7}}"#.utf8)
        let report = MappingDecodingReport()
        let library = try MappingStore.decoder(report: report).decode(MappingLibrary.self, from: data)
        XCTAssertEqual(Array(library.models.keys), [.mxVertical])
        XCTAssertEqual(report.issues.count, 3, "\(report.issues)")
    }

    func testCompatLoadAndSaveOnlyTouchMXVertical() throws {
        let store = makeStore()
        var library = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        library[master] = MappingProfiles(global: ButtonMappings([KnownControl.back: .system(.copy)]))
        library.modelNames[master] = "Desk mouse"
        library.reservedDevices = ["u:046D:B034:00000001": .object(["nickname": .string("Desk")])]
        library.unknownTopLevel = ["future": .bool(true)]
        store.save(library)

        let replacement = MappingProfiles(global: ButtonMappings([KnownControl.forward: .disabled]))
        store.save(replacement)
        XCTAssertEqual(store.load(), replacement)
        var expected = library
        expected[.mxVertical] = replacement
        XCTAssertEqual(store.loadLibrary().library, expected)
        XCTAssertNil(defaults.object(forKey: MappingStore.v2Key))
    }

    func testUnknownModelResolvesToEmpty() throws {
        var library = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        XCTAssertTrue(library.effectiveMappings(model: nil, bundleID: nil).isEmpty)
        XCTAssertTrue(library.effectiveMappings(model: prototype, bundleID: "com.apple.Safari").isEmpty)
        XCTAssertTrue(library.effectiveMappings(model: ModelKey(name: "Gadget"), bundleID: nil).isEmpty)
        XCTAssertEqual(library[prototype], MappingProfiles())
        XCTAssertNil(library.models[prototype], "reading a model doesn't add it")
        XCTAssertEqual(library.name(of: prototype), "046D:ABCD")
        XCTAssertEqual(library.name(of: .mxVertical), "MX Vertical")

        library[prototype].global[KnownControl.back] = .disabled
        XCTAssertEqual(library.effectiveMappings(model: prototype, bundleID: nil), ButtonMappings([KnownControl.back: .disabled]))
        XCTAssertEqual(library.effectiveMappings(model: .mxVertical, bundleID: nil), .legacyDefaults)
    }

    func testAllActiveActionsUnionsModels() throws {
        let combo = ButtonAction.keyCombo(KeyCombo(keyCode: KeyCode.t, modifiers: [.command]))
        var vertical = MappingProfiles(global: ButtonMappings([KnownControl.back: .system(.missionControl)]))
        vertical.upsert(AppProfile(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isEnabled: false, overrides: [KnownControl.back: combo]))
        var library = MappingLibrary(migrating: vertical)
        // Only the MX Vertical: exactly that setup's actions, so nothing needs Accessibility.
        XCTAssertEqual(library.allActiveActions, vertical.allActiveActions)
        XCTAssertFalse(library.allActiveActions.contains { $0.requiresAccessibility })

        library[master] = MappingProfiles(global: ButtonMappings([KnownControl.forward: combo]))
        XCTAssertEqual(library.allActiveActions, vertical.allActiveActions + [combo])
        XCTAssertTrue(library.allActiveActions.contains { $0.requiresAccessibility })
    }

    func testSuggestedPerModel() throws {
        let prototypeControls: [UInt16] = [KnownControl.leftClick, KnownControl.rightClick, KnownControl.middleClick,
                                           KnownControl.back, KnownControl.forward, KnownControl.gestureButton, KnownControl.smartShift]
        XCTAssertEqual(ButtonMappings.suggested(for: .mxVertical, controls: []), .legacyDefaults)
        XCTAssertEqual(ButtonMappings.suggested(for: .mxVertical, controls: prototypeControls), .legacyDefaults)
        XCTAssertEqual(ButtonMappings.suggested(for: prototype, controls: prototypeControls), ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.forward: .system(.navigateForward),
            KnownControl.gestureButton: .system(.missionControl),
        ]))
        XCTAssertEqual(ButtonMappings.suggested(for: prototype, controls: [KnownControl.multiPlatformGesture, KnownControl.back]), ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.multiPlatformGesture: .system(.missionControl),
        ]))
        XCTAssertEqual(ButtonMappings.suggested(for: prototype, controls: [KnownControl.multiPlatformGesture, KnownControl.gestureButton]), ButtonMappings([
            KnownControl.gestureButton: .system(.missionControl),
        ]))
        XCTAssertTrue(ButtonMappings.suggested(for: prototype, controls: [KnownControl.leftClick, KnownControl.rightClick, KnownControl.middleClick]).isEmpty)
        XCTAssertTrue(ButtonMappings.suggested(for: master, controls: []).isEmpty)
        // Back is ⌘[ and Forward ⌘], as on the MX Vertical.
        XCTAssertEqual(SystemAction.navigateBack.effect, .keyCombo(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)))
        XCTAssertEqual(SystemAction.navigateForward.effect, .keyCombo(KeyCombo(keyCode: KeyCode.rightBracket, modifiers: .command)))
    }

    // MARK: Export

    func testExportHasCompatMirrorAndNames() throws {
        var vertical = MappingProfiles(global: .legacyDefaults)
        vertical.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
            KnownControl.back: .openURL(URL(string: "https://example.com/path")!),
        ]))
        var library = MappingLibrary(migrating: vertical)
        library[master] = MappingProfiles(global: ButtonMappings([KnownControl.gestureButton: .system(.missionControl)]))
        library[prototype] = MappingProfiles(global: ButtonMappings([KnownControl.back: .disabled]))
        library.modelNames[lift] = "Desk mouse"
        library.reservedDevices = ["u:046D:B020:1A2B3C4D": .object(["nickname": .string("Desk")])]
        library.unknownTopLevel = ["future": .bool(true)]

        let data = makeStore().export(library)
        XCTAssertEqual(data, try MappingStore.exportData(library))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 3"), text)
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("https://example.com/path"))

        let file = try json(data)
        XCTAssertNil(file["devices"], "per-Mac data isn't exported")
        XCTAssertNil(file["future"])
        let models = try XCTUnwrap(file["models"] as? [String: Any])
        XCTAssertEqual(Set(models.keys), ["046D:B020", "046D:B034", "046D:ABCD"], "a name without a setup isn't exported")
        XCTAssertEqual((models["046D:B020"] as? [String: Any])?["name"] as? String, "MX Vertical")
        XCTAssertEqual((models["046D:B034"] as? [String: Any])?["name"] as? String, MappingLibrary.catalogName(of: master))
        XCTAssertEqual((models["046D:ABCD"] as? [String: Any])?["name"] as? String, "046D:ABCD")

        // A 2.x build reads the top-level mirror: the MX Vertical's setup, after one "newer version" note.
        let report = MappingDecodingReport()
        XCTAssertEqual(try MappingStore.decoder(report: report).decode(MappingProfiles.self, from: data), vertical)
        XCTAssertEqual(report.issues.count, 1, "\(report.issues)")
        // This build reads the sections and ignores the mirror.
        XCTAssertEqual(try MappingStore.decoder(report: MappingDecodingReport()).decode(MappingLibrary.self, from: data).models, library.models)
        XCTAssertEqual(try MappingStore.importData(data), vertical)

        // Without an MX Vertical setup there is nothing to mirror.
        library.models[.mxVertical] = nil
        let other = try json(MappingStore.exportData(library))
        XCTAssertNil(other["global"])
        XCTAssertNil(other["apps"])
        XCTAssertThrowsError(try MappingStore.importData(MappingStore.exportData(library))) { error in
            XCTAssertEqual(error as? MappingStore.ImportError, .noMappings)
        }
    }

    func testLibraryBackupsRoundTrip() throws {
        let store = makeStore()
        var library = MappingLibrary(migrating: everyKindProfiles)
        library[master] = MappingProfiles(global: ButtonMappings([KnownControl.back: .disabled]))
        library.reservedDevices = ["x": .null]
        let key = try XCTUnwrap(store.backUp(library, reason: "test"))
        XCTAssertEqual(store.loadLibraryBackup(key), library)
        XCTAssertEqual(store.loadBackup(key), everyKindProfiles)

        // 2.x-format backups read as the MX Vertical's setup.
        let v2Key = try XCTUnwrap(store.backUp(MappingProfiles(global: .legacyDefaults), reason: "test"))
        XCTAssertEqual(store.loadLibraryBackup(v2Key)?.models, [.mxVertical: MappingProfiles(global: .legacyDefaults)])
        XCTAssertEqual(store.loadBackup(v2Key), MappingProfiles(global: .legacyDefaults))
        XCTAssertNil(store.loadBackup("missing"))
    }

    // MARK: Import

    func testImportV3MergesPerModel() throws {
        var current = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        current[master] = MappingProfiles(global: ButtonMappings([KnownControl.back: .system(.copy)]))
        current[lift] = MappingProfiles(global: ButtonMappings([KnownControl.forward: .system(.paste)]))
        current.reservedDevices = ["u:046D:B020:1A2B3C4D": .object(["nickname": .string("Mine")])]
        current.unknownTopLevel = ["future": .bool(true)]

        let file = Data(#"""
        {"schemaVersion":3,
         "models":{
           "046D:B020":{"name":"MX Vertical","global":{"actions":{"83":{"runShortcut":{"_0":"Make GIF"}}}},"apps":[{"bundleID":"com.apple.Safari","displayName":"Safari","isEnabled":true,"overrides":{"86":{"openURL":{"_0":"https://example.com"}}}}]},
           "046D:B034":{"name":"MX Master 3S","global":{"actions":{}},"apps":[]},
           "046D:ABCD":{"name":"Prototype","global":{"actions":{"80":{"disabled":{}},"83":{"launchApp":{"_0":{"bundleID":"com.apple.Terminal","displayName":"Terminal"}}}}},"apps":[]}
         },
         "devices":{"u:046D:B020:00000001":{"nickname":"Theirs"}},
         "theirFlag":true,
         "global":{"actions":{"83":{"disabled":{}}}},"apps":[]}
        """#.utf8)

        let store = makeStore()
        let preview = try store.prepareImport(file, targetModel: .mxVertical)
        XCTAssertTrue(store.backupKeys.isEmpty, "previewing changes nothing")
        XCTAssertEqual(preview.format, .library)
        // The empty MX Master section has nothing to import: that model keeps its setup.
        XCTAssertEqual(preview.importedModels, [prototype, .mxVertical])
        XCTAssertEqual(preview.modelNames, [prototype: "Prototype", .mxVertical: "MX Vertical"])
        XCTAssertEqual(preview.skipped, ["Prototype · global: skipped mapping for primary click control 80"])
        let shortcut = ButtonAction.runShortcut("Make GIF")
        let link = ButtonAction.openURL(URL(string: "https://example.com")!)
        let terminal = ButtonAction.launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal"))
        XCTAssertEqual(preview.actionsToReview, [
            .init(model: prototype, modelName: "Prototype", bundleID: nil, cid: KnownControl.back, slot: .button, action: terminal),
            .init(model: .mxVertical, modelName: "MX Vertical", bundleID: nil, cid: KnownControl.back, slot: .button, action: shortcut),
            .init(model: .mxVertical, modelName: "MX Vertical", bundleID: "com.apple.Safari", cid: KnownControl.forward, slot: .button, action: link),
        ])

        let (merged, backupKey) = store.applyImport(preview, to: current)
        XCTAssertEqual(store.loadLibraryBackup(try XCTUnwrap(backupKey)), current)
        XCTAssertEqual(merged[.mxVertical].global, ButtonMappings([KnownControl.back: shortcut]))
        XCTAssertEqual(merged[.mxVertical][app: "com.apple.Safari"]?[KnownControl.forward], link)
        XCTAssertEqual(merged[prototype].global, ButtonMappings([KnownControl.back: terminal]))
        XCTAssertEqual(merged[master], current[master])
        XCTAssertEqual(merged[lift], current[lift])
        XCTAssertEqual(merged.name(of: prototype), "Prototype")
        // The file's devices and unknown keys describe someone else's Mac; ours stay.
        XCTAssertEqual(merged.reservedDevices, current.reservedDevices)
        XCTAssertEqual(merged.unknownTopLevel, current.unknownTopLevel)
    }

    func testImportV2IntoChosenModel() throws {
        let link = ButtonAction.openURL(URL(string: "https://example.com")!)
        let shortcut = ButtonAction.runShortcut("Make GIF")
        var profiles = MappingProfiles(global: ButtonMappings([KnownControl.back: link, KnownControl.leftClick: .disabled]))
        profiles.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [KnownControl.forward: shortcut]))
        let file = try MappingStore.encoder().encode(profiles)
        var expected = profiles
        expected.global[KnownControl.leftClick] = .deviceDefault

        let store = makeStore()
        let preview = try store.prepareImport(file, targetModel: master)
        XCTAssertEqual(preview.format, .singleModel)
        XCTAssertEqual(preview.models, [master: expected])
        XCTAssertTrue(preview.modelNames.isEmpty)
        XCTAssertEqual(preview.skipped, ["global: skipped mapping for primary click control 80"])
        let name = MappingLibrary.catalogName(of: master)
        XCTAssertEqual(preview.actionsToReview, [
            .init(model: master, modelName: name, bundleID: nil, cid: KnownControl.back, slot: .button, action: link),
            .init(model: master, modelName: name, bundleID: "com.apple.Safari", cid: KnownControl.forward, slot: .button, action: shortcut),
        ])
        let current = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        let merged = preview.applied(to: current)
        XCTAssertEqual(merged[.mxVertical], current[.mxVertical])
        XCTAssertEqual(merged[master], expected)

        // Review items use the name this Mac knows the target model by.
        var saved = MappingLibrary()
        saved.modelNames[lift] = "Desk mouse"
        store.save(saved)
        XCTAssertEqual(try store.prepareImport(file, targetModel: lift).actionsToReview.first?.modelName, "Desk mouse")

        // A 1.x table works the same way; by default it goes to the MX Vertical.
        let legacy = try store.prepareImport(Data(v1Table.utf8), targetModel: .mxVertical)
        XCTAssertEqual(legacy.format, .singleModel)
        XCTAssertEqual(legacy.importedModels, [.mxVertical])
        XCTAssertEqual(legacy.models[.mxVertical]?.global, try JSONDecoder().decode(ButtonMappings.self, from: Data(v1Table.utf8)))
    }

    func testImportProtectsPrimaryAndDeviceControlsPerModel() throws {
        let file = Data(#"{"schemaVersion":3,"models":{"046D:B034":{"global":{"actions":{"81":{"disabled":{}},"82":{"disabled":{}},"83":{"disabled":{}}}},"apps":[{"bundleID":"com.apple.Safari","overrides":{"82":{"system":{"_0":"copy"}}}}]},"046D:B020":{"global":{"actions":{"82":{"disabled":{}}}},"apps":[]}}}"#.utf8)
        let preview = try makeStore().prepareImport(file, targetModel: .mxVertical, protecting: [master: [KnownControl.middleClick]])
        XCTAssertEqual(preview.models[master]?.global, ButtonMappings([KnownControl.back: .disabled]))
        XCTAssertEqual(preview.models[master]?[app: "com.apple.Safari"]?.overrides, [:])
        XCTAssertEqual(preview.models[.mxVertical]?.global, ButtonMappings([KnownControl.middleClick: .disabled]), "protection is per model")
        XCTAssertEqual(preview.skipped.count, 3, "\(preview.skipped)")
    }

    func testImportRejectsEmptyAndJunkLibraries() throws {
        let store = makeStore()
        let empty = [
            #"{"schemaVersion":3,"models":{}}"#,
            #"{"models":{"046D:B020":{"global":{"actions":{}},"apps":[]}}}"#,
            #"{"schemaVersion":3,"models":{"046D:B020":{"global":{"actions":{"80":{"disabled":{}}}}}}}"#,
            #"{"schemaVersion":3,"models":5,"global":{"actions":{"83":{"disabled":{}}}}}"#,
            #"{"schemaVersion":3,"models":{"046D:B034":{"name":"MX Master 3S"}}}"#,
        ]
        for text in empty {
            XCTAssertThrowsError(try store.prepareImport(Data(text.utf8), targetModel: .mxVertical), text) { error in
                XCTAssertEqual(error as? MappingStore.ImportError, .noMappings, text)
            }
        }
        for junk in ["[]", "junk", #"{"hello":"world"}"#] {
            XCTAssertThrowsError(try store.prepareImport(Data(junk.utf8), targetModel: .mxVertical), junk) { error in
                XCTAssertEqual(error as? MappingStore.ImportError, .unreadable, junk)
            }
        }
        XCTAssertTrue(store.backupKeys.isEmpty)
    }

    func testReviewItemsForLibraryCarryModelNames() throws {
        let shortcut = ButtonAction.runShortcut("Make GIF")
        let link = ButtonAction.openURL(URL(string: "https://example.com")!)
        var library = MappingLibrary(migrating: MappingProfiles(global: ButtonMappings([KnownControl.back: shortcut])))
        library[prototype] = MappingProfiles(global: ButtonMappings([KnownControl.forward: link, KnownControl.middleClick: .system(.copy)]))
        library.modelNames[prototype] = "Prototype"
        XCTAssertEqual(MappingStore.actionsToReview(in: library), [
            .init(model: prototype, modelName: "Prototype", bundleID: nil, cid: KnownControl.forward, slot: .button, action: link),
            .init(model: .mxVertical, modelName: "MX Vertical", bundleID: nil, cid: KnownControl.back, slot: .button, action: shortcut),
        ])
        // Items made without a model are the MX Vertical's.
        let item = MappingStore.ReviewItem(bundleID: nil, cid: KnownControl.back, slot: .button, action: shortcut)
        XCTAssertEqual(item.model, .mxVertical)
        XCTAssertEqual(item.modelName, "MX Vertical")
    }
}
