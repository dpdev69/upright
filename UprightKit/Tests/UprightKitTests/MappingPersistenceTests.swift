import XCTest
@testable import UprightKit

/// Produced by encoding a `ButtonMappings` with the Upright 1.x sources: every SystemAction case
/// (CIDs 0x100…), a recorded shortcut, "Do Nothing", and the 1.x defaults.
private let v1Fixture = #"""
{"actions":{"253":{"system":{"_0":"missionControl"}},"256":{"system":{"_0":"navigateBack"}},"257":{"system":{"_0":"navigateForward"}},"258":{"system":{"_0":"previousTab"}},"259":{"system":{"_0":"nextTab"}},"260":{"system":{"_0":"missionControl"}},"261":{"system":{"_0":"appExpose"}},"262":{"system":{"_0":"showDesktop"}},"263":{"system":{"_0":"spaceLeft"}},"264":{"system":{"_0":"spaceRight"}},"265":{"system":{"_0":"spotlight"}},"266":{"system":{"_0":"screenshot"}},"267":{"system":{"_0":"lockScreen"}},"268":{"system":{"_0":"middleClick"}},"269":{"system":{"_0":"mouseBack"}},"270":{"system":{"_0":"mouseForward"}},"271":{"system":{"_0":"playPause"}},"272":{"system":{"_0":"nextTrack"}},"273":{"system":{"_0":"previousTrack"}},"274":{"system":{"_0":"volumeUp"}},"275":{"system":{"_0":"volumeDown"}},"276":{"system":{"_0":"mute"}},"277":{"system":{"_0":"copy"}},"278":{"system":{"_0":"paste"}},"279":{"system":{"_0":"undo"}},"280":{"system":{"_0":"redo"}},"82":{"disabled":{}},"83":{"system":{"_0":"navigateBack"}},"86":{"keyCombo":{"_0":{"keyCode":17,"keyLabel":"T","modifiers":12}}}}}
"""#

private let v1DeviceDefault = #"{"deviceDefault":{}}"#

final class MappingPersistenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var logged: [String] = []

    override func setUpWithError() throws {
        suiteName = "UprightTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        logged = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MappingStore {
        MappingStore(defaults: defaults, log: { [unowned self] in logged.append($0) }, now: { now })
    }

    private var expectedV1: ButtonMappings {
        var expected = ButtonMappings()
        for (index, action) in SystemAction.allCases.enumerated() {
            expected[UInt16(0x100 + index)] = .system(action)
        }
        expected[KnownControl.back] = .system(.navigateBack)
        expected[KnownControl.forward] = .keyCombo(KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T"))
        expected[KnownControl.middleClick] = .disabled
        expected[KnownControl.dpiSwitch] = .system(.missionControl)
        return expected
    }

    // MARK: v1 compatibility

    func testDecodesEveryV1Encoding() throws {
        let decoded = try JSONDecoder().decode(ButtonMappings.self, from: Data(v1Fixture.utf8))
        XCTAssertEqual(decoded, expectedV1)
        XCTAssertEqual(try JSONDecoder().decode(ButtonAction.self, from: Data(v1DeviceDefault.utf8)), .deviceDefault)
    }

    func testExistingCasesStillEncodeLikeV1() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(expectedV1), as: UTF8.self), v1Fixture)
        XCTAssertEqual(String(decoding: try encoder.encode(ButtonAction.deviceDefault), as: UTF8.self), v1DeviceDefault)
    }

    func testNewActionsRoundTrip() throws {
        let actions: [ButtonAction] = [
            .launchApp(AppReference(bundleID: "com.apple.Safari", displayName: "Safari")),
            .openURL(URL(string: "https://example.com/a?b=c")!),
            .runShortcut("Toggle Focus"),
            .device(.cycleDPI),
            .device(.setDPI(1200)),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(ButtonAction.self, from: data), action)
        }
    }

    func testKeyComboToleratesMissingFields() throws {
        let combo = try JSONDecoder().decode(KeyCombo.self, from: Data(#"{"keyCode":123}"#.utf8))
        XCTAssertEqual(combo, KeyCombo(keyCode: KeyCode.leftArrow))
        XCTAssertEqual(combo.keyLabel, "←")
        let odd = try JSONDecoder().decode(KeyCombo.self, from: Data(#"{"keyCode":8,"modifiers":"x","keyLabel":""}"#.utf8))
        XCTAssertEqual(odd, KeyCombo(keyCode: KeyCode.c))
    }

    // MARK: Tolerant decoding

    func testCorruptEntryIsSkippedNotTheWholeTable() throws {
        let json = #"{"actions":{"83":{"system":{"_0":"navigateBack"}},"86":{"keyCombo":{"_0":{"modifiers":8}}},"abc":{"disabled":{}},"82":42}}"#
        let report = MappingDecodingReport()
        let decoded = try MappingStore.decoder(report: report).decode(ButtonMappings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ButtonMappings([KnownControl.back: .system(.navigateBack)]))
        XCTAssertEqual(report.issues.count, 3)
    }

    func testUnknownSystemActionFromNewerVersionIsSkipped() throws {
        let json = #"{"schemaVersion":4,"global":{"actions":{"83":{"system":{"_0":"teleport"}},"86":{"warp":{"_0":{}}},"253":{"system":{"_0":"missionControl"}}}},"apps":[{"bundleID":"com.example","overrides":{"83":{"system":{"_0":"copy"}}}},{"nope":true},{"bundleID":"com.example.b","overrides":{"83":{"hologram":{}}}}]}"#
        let report = MappingDecodingReport()
        let decoded = try MappingStore.decoder(report: report).decode(MappingProfiles.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.global, ButtonMappings([KnownControl.dpiSwitch: .system(.missionControl)]))
        XCTAssertEqual(decoded.apps.map(\.bundleID), ["com.example", "com.example.b"])
        XCTAssertEqual(decoded.apps[0].displayName, "com.example")
        XCTAssertTrue(decoded.apps[0].isEnabled)
        XCTAssertEqual(decoded.apps[0][KnownControl.back], .system(.copy))
        XCTAssertTrue(decoded.apps[1].overrides.isEmpty)
        // Newer schema, two unknown actions, one profile without a bundle ID, one unknown override.
        XCTAssertEqual(report.issues.count, 5, "\(report.issues)")
    }

    func testStoreBacksUpRawDataWhenEntriesWereSkipped() throws {
        let json = #"{"schemaVersion":2,"global":{"actions":{"83":{"system":{"_0":"teleport"}},"86":{"disabled":{}}}},"apps":[]}"#
        defaults.set(Data(json.utf8), forKey: MappingStore.profilesKey)

        let store = makeStore()
        let profiles = store.load()
        XCTAssertEqual(profiles.global, ButtonMappings([KnownControl.forward: .disabled]))
        XCTAssertEqual(store.backupKeys.count, 1)
        XCTAssertEqual(store.backupKeys.first.flatMap { defaults.data(forKey: $0) }, Data(json.utf8))

        // The cleaned table was saved, so the next launch doesn't back up again.
        XCTAssertEqual(makeStore().load(), profiles)
        XCTAssertEqual(store.backupKeys.count, 1)
    }

    func testTotallyCorruptDataIsBackedUpBeforeFallingBack() throws {
        let garbage = Data("not json at all".utf8)
        defaults.set(garbage, forKey: MappingStore.profilesKey)
        defaults.set(true, forKey: "hasLaunchedBefore")

        let store = makeStore()
        let profiles = store.load()
        XCTAssertEqual(profiles, MappingProfiles())
        XCTAssertEqual(store.backupKeys, [MappingStore.backupKeyPrefix + "1700000000"])
        XCTAssertEqual(defaults.data(forKey: MappingStore.backupKeyPrefix + "1700000000"), garbage)
        XCTAssertFalse(logged.isEmpty)

        // A second corrupt write in the same second gets its own backup key.
        defaults.set(Data("[1,2".utf8), forKey: MappingStore.profilesKey)
        _ = makeStore().load()
        XCTAssertEqual(store.backupKeys.count, 2)
    }

    // MARK: Migration

    func testMigratesV1DataExactly() throws {
        defaults.set(Data(v1Fixture.utf8), forKey: MappingStore.legacyKey)
        let profiles = makeStore().load()
        XCTAssertEqual(profiles.global, expectedV1)
        XCTAssertTrue(profiles.apps.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: MappingStore.profilesKey))
        // The 1.x key is left alone so a downgrade still finds it.
        XCTAssertNotNil(defaults.data(forKey: MappingStore.legacyKey))
        XCTAssertEqual(makeStore().load(), profiles)
    }

    func testMigratesUserWhoClearedEverythingInV1() throws {
        defaults.set(Data(#"{"actions":{}}"#.utf8), forKey: MappingStore.legacyKey)
        XCTAssertEqual(makeStore().load().global, ButtonMappings())
    }

    func testUnreadableV1DataIsBackedUpAndKeepsOldDefaults() throws {
        defaults.set(Data("{oops".utf8), forKey: MappingStore.legacyKey)
        let store = makeStore()
        XCTAssertEqual(store.load().global, .legacyDefaults)
        XCTAssertEqual(store.backupKeys.count, 1)
    }

    func testUpgradeWithoutSavedDataKeepsOldDefaults() throws {
        defaults.set(true, forKey: "remappingEnabled")
        XCTAssertEqual(makeStore().load().global, .legacyDefaults)

        let other = try XCTUnwrap(UserDefaults(suiteName: suiteName + "-b"))
        defer { other.removePersistentDomain(forName: suiteName + "-b") }
        other.set(true, forKey: "hasLaunchedBefore")
        XCTAssertEqual(MappingStore(defaults: other).load().global, .legacyDefaults)
    }

    func testFreshInstallDivertsNothing() throws {
        let store = makeStore()
        XCTAssertFalse(store.hasPriorLaunch)
        let profiles = store.load()
        XCTAssertEqual(profiles, MappingProfiles())
        XCTAssertTrue(profiles.global.isEmpty)
        // Saved, so the next launch (now with prior-launch markers) doesn't switch to the old defaults.
        defaults.set(true, forKey: "hasLaunchedBefore")
        XCTAssertEqual(makeStore().load(), profiles)
        XCTAssertTrue(store.backupKeys.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        var profiles = MappingProfiles()
        profiles.global[KnownControl.back] = .keyCombo(KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T"))
        profiles.addApp(bundleID: "com.apple.Safari", displayName: "Safari")
        profiles[app: "com.apple.Safari"]?[KnownControl.back] = .deviceDefault
        let store = makeStore()
        store.save(profiles)
        XCTAssertEqual(store.load(), profiles)
        XCTAssertEqual(store.load().global[KnownControl.back].title, "⇧⌘T")
    }

    // MARK: Export / import

    func testExportIsPrettyVersionedJSONAndImportsBack() throws {
        var profiles = MappingProfiles(global: .legacyDefaults)
        profiles.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [
            KnownControl.back: .openURL(URL(string: "https://example.com/path")!),
        ]))
        let data = try MappingStore.exportData(profiles)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 3"), text)
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("https://example.com/path"))
        XCTAssertEqual(try MappingStore.importData(data), profiles)
    }

    func testImportValidatesAndDropsDangerousEntries() throws {
        let json = #"{"schemaVersion":2,"global":{"actions":{"80":{"disabled":{}},"83":{"runShortcut":{"_0":""}},"86":{"device":{"_0":{"setDPI":{"_0":99999}}}},"253":{"device":{"_0":{"cycleDPI":{}}}}}},"apps":[{"bundleID":"  ","overrides":{}}]}"#
        let report = MappingDecodingReport()
        let imported = try MappingStore.importData(Data(json.utf8), report: report)
        XCTAssertEqual(imported.global, ButtonMappings([KnownControl.dpiSwitch: .device(.cycleDPI)]))
        XCTAssertTrue(imported.apps.isEmpty)
        XCTAssertEqual(report.issues.count, 4, "\(report.issues)")
    }

    func testImportAcceptsV1TableAndRejectsJunk() throws {
        XCTAssertEqual(try MappingStore.importData(Data(v1Fixture.utf8)).global, expectedV1)
        XCTAssertThrowsError(try MappingStore.importData(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? MappingStore.ImportError, .unreadable)
        }
        XCTAssertThrowsError(try MappingStore.importData(Data(#"{"hello":"world"}"#.utf8)))
        XCTAssertThrowsError(try MappingStore.importData(Data(#"{"schemaVersion":2,"global":{"actions":{"83":{"zap":{}}}}}"#.utf8))) { error in
            XCTAssertEqual(error as? MappingStore.ImportError, .noMappings)
        }
    }

    func testEmptyImportsAreRejected() {
        for json in [#"{"schemaVersion":2}"#, #"{"actions":{}}"#, #"{"schemaVersion":2,"global":{"actions":{}},"apps":[]}"#] {
            XCTAssertThrowsError(try MappingStore.importData(Data(json.utf8)), json) { error in
                XCTAssertEqual(error as? MappingStore.ImportError, .noMappings, json)
            }
        }
        // An app profile alone is something to import.
        let appOnly = #"{"schemaVersion":2,"apps":[{"bundleID":"com.apple.Safari","overrides":{}}]}"#
        XCTAssertEqual(try MappingStore.importData(Data(appOnly.utf8)).apps.map(\.bundleID), ["com.apple.Safari"])
    }

    func testImportOnlyAcceptsWebAndMailLinks() throws {
        let json = #"""
        {"schemaVersion":2,"global":{"actions":{
            "83":{"openURL":{"_0":"file:///Users/me/Downloads/x.command"}},
            "86":{"openURL":{"_0":"mailto:me@example.com"}},
            "82":{"openURL":{"_0":"HTTPS://example.com"}},
            "253":{"gestures":{"_0":{"up":{"openURL":{"_0":"http://example.com"}},"down":{"openURL":{"_0":"vnc://host"}}}}}
        }},"apps":[{"bundleID":"com.apple.Safari","overrides":{"83":{"openURL":{"_0":"javascript:alert(1)"}}}}]}
        """#
        let report = MappingDecodingReport()
        let imported = try MappingStore.importData(Data(json.utf8), report: report)
        XCTAssertEqual(imported.global, ButtonMappings([
            KnownControl.forward: .openURL(URL(string: "mailto:me@example.com")!),
            KnownControl.middleClick: .openURL(URL(string: "HTTPS://example.com")!),
            KnownControl.dpiSwitch: .gestures(GestureSet(up: .openURL(URL(string: "http://example.com")!))),
        ]))
        XCTAssertEqual(imported[app: "com.apple.Safari"]?.overrides, [:])
        XCTAssertEqual(report.issues.count, 3, "\(report.issues)")
        XCTAssertTrue(report.issues.contains { $0.contains("file:") })
    }

    func testImportListsExternalActionsForReview() throws {
        let shortcut = ButtonAction.runShortcut("Make GIF")
        let link = ButtonAction.openURL(URL(string: "https://example.com")!)
        let app = ButtonAction.launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal"))
        var profiles = MappingProfiles(global: ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.forward: shortcut,
            KnownControl.dpiSwitch: .gestures(GestureSet(tap: link, up: .system(.missionControl), left: app)),
        ]))
        profiles.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [KnownControl.back: app]))

        let items = MappingStore.actionsToReview(in: profiles)
        XCTAssertEqual(items, [
            .init(bundleID: nil, cid: KnownControl.forward, slot: .button, action: shortcut),
            .init(bundleID: nil, cid: KnownControl.dpiSwitch, slot: .gestureTap, action: link),
            .init(bundleID: nil, cid: KnownControl.dpiSwitch, slot: .gesture(.left), action: app),
            .init(bundleID: "com.apple.Safari", cid: KnownControl.back, slot: .button, action: app),
        ])
    }

    func testPrepareImportBacksUpCurrentProfilesFirst() throws {
        let store = makeStore()
        var current = MappingProfiles(global: .legacyDefaults)
        current.upsert(AppProfile(bundleID: "com.apple.Safari", displayName: "Safari", overrides: [KnownControl.back: .disabled]))
        let file = try MappingStore.exportData(MappingProfiles(global: ButtonMappings([
            KnownControl.forward: .openURL(URL(string: "https://example.com")!),
        ])))

        let outcome = try store.prepareImport(file, replacing: current)
        XCTAssertEqual(outcome.profiles.global[KnownControl.forward], .openURL(URL(string: "https://example.com")!))
        XCTAssertEqual(outcome.actionsToReview.count, 1)
        let key = try XCTUnwrap(outcome.backupKey)
        XCTAssertEqual(store.backupKeys, [key])
        XCTAssertEqual(store.loadBackup(key), current)
    }

    func testFailedImportBacksUpNothing() {
        let store = makeStore()
        XCTAssertThrowsError(try store.prepareImport(Data(#"{"schemaVersion":2}"#.utf8), replacing: MappingProfiles(global: .legacyDefaults)))
        XCTAssertThrowsError(try store.prepareImport(Data("junk".utf8), replacing: MappingProfiles()))
        XCTAssertTrue(store.backupKeys.isEmpty)
    }
}
