import XCTest
@testable import UprightKit

final class DevicePreferencesTests: XCTestCase {
    private let verticalA = DeviceID.unit(0x1A2B_3C4D, model: .mxVertical)
    private let verticalB = DeviceID.unit(0x5E6F_7081, model: .mxVertical)
    private let master3S = ModelKey(productID: 0xB034)
    private var masterUnit: DeviceID { .unit(0x0BAD_CAFE, model: master3S) }
    private let transient = DeviceID.transient(DeviceAddress(link: 3, index: 2))

    private func snapshot(
        name: String = "MX Vertical",
        connection: ConnectionKind = .bluetooth,
        controls: [ControlInfo]? = nil
    ) -> DeviceSnapshot {
        let divertable: ControlFlags = [.mouseButton, .reprogrammable, .divertable]
        return DeviceSnapshot(
            name: name,
            connection: connection,
            deviceIndex: 0xFF,
            protocolVersion: "4.5",
            features: [],
            controls: controls ?? [
                ControlInfo(cid: 0x50, taskID: 0x38, flags: divertable),           // left click: never configurable
                ControlInfo(cid: 0x53, taskID: 0x3C, flags: divertable),           // Back
                ControlInfo(cid: 0x56, taskID: 0x3E, flags: divertable),           // Forward
                ControlInfo(cid: 0xFD, taskID: 0x00, flags: [.mouseButton, .virtual, .divertable]), // virtual
                ControlInfo(cid: 0x99, taskID: 0x00, flags: [.mouseButton]),       // not divertable
            ],
            battery: nil
        )
    }

    private func roundTrip(_ store: DevicePreferencesStore) throws -> DevicePreferencesStore {
        try JSONDecoder().decode(DevicePreferencesStore.self, from: JSONEncoder().encode(store))
    }

    // MARK: Legacy seed

    func testLegacyPreferredDPISeedsMXVerticalOnce() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        XCTAssertEqual(store.models[.mxVertical]?.preferredDPI, 1600)

        // A later launch still has the legacy key in place, possibly with another value: no re-seed.
        store.migrateLegacy(preferredDPI: 800)
        XCTAssertEqual(store.models[.mxVertical]?.preferredDPI, 1600)
        store.migrateLegacy(preferredDPI: nil)
        XCTAssertEqual(store.models[.mxVertical]?.preferredDPI, 1600)

        // The first MX Vertical identified, of any unit, inherits it...
        XCTAssertEqual(store.preferences(for: verticalA, model: .mxVertical).preferredDPI, 1600)
        XCTAssertEqual(store.preferences(for: verticalB, model: .mxVertical).preferredDPI, 1600)
        XCTAssertEqual(store.preferences(for: transient, model: .mxVertical).preferredDPI, 1600)
        // ...and recording it keeps the value on the unit.
        store.record(verticalA, snapshot: snapshot())
        XCTAssertEqual(store.devices[verticalA]?.preferredDPI, 1600)
    }

    func testLegacyWithoutAPreferredSpeedStillCountsAsMigrated() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: nil)
        XCTAssertNotNil(store.models[.mxVertical])
        XCTAssertNil(store.models[.mxVertical]?.preferredDPI)

        store.migrateLegacy(preferredDPI: 1200)
        XCTAssertNil(store.models[.mxVertical]?.preferredDPI)
    }

    func testLegacyIgnoresNonsensicalSpeeds() {
        var zero = DevicePreferencesStore()
        zero.migrateLegacy(preferredDPI: 0)
        XCTAssertNil(zero.models[.mxVertical]?.preferredDPI)

        var negative = DevicePreferencesStore()
        negative.migrateLegacy(preferredDPI: -400)
        XCTAssertNil(negative.models[.mxVertical]?.preferredDPI)
    }

    func testFirstSeenOtherModelKeepsOwnDPI() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)

        // Only the MX Vertical inherits the old setting; another model's mouse keeps its own speed.
        XCTAssertNil(store.preferences(for: masterUnit, model: master3S).preferredDPI)
        XCTAssertNil(store.preferences(for: transient, model: master3S).preferredDPI)
        store.record(masterUnit, snapshot: snapshot(name: "MX Master 3S", connection: .bolt))
        XCTAssertNil(store.devices[masterUnit]?.preferredDPI)
        XCTAssertEqual(store.devices[masterUnit]?.lastModel, master3S)
    }

    func testModelSeedAppliesOnlyToUnitsWithoutAnEntryAndOnlyCarriesSpeed() {
        var seed = DevicePreferences(nickname: "Seed nick", remapEnabled: false, preferredDPI: 2000, lastName: "Seed")
        seed.lastControls = [0x53]
        var store = DevicePreferencesStore(models: [master3S: seed])

        let first = store.preferences(for: masterUnit, model: master3S)
        XCTAssertEqual(first, DevicePreferences(preferredDPI: 2000))
        XCTAssertNil(first.trimmedNickname)
        XCTAssertTrue(first.remapEnabled)

        store.record(masterUnit, snapshot: snapshot(name: "MX Master 3S"))
        XCTAssertNil(store.devices[masterUnit]?.nickname)
        XCTAssertEqual(store.devices[masterUnit]?.remapEnabled, true)
        XCTAssertEqual(store.devices[masterUnit]?.preferredDPI, 2000)
        XCTAssertEqual(store.devices[masterUnit]?.lastControls, [0x53, 0x56])
    }

    func testOwnPreferencesWinOverTheSeedEvenWithoutASpeed() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        store.record(verticalA, snapshot: snapshot())

        // "Let the Mouse Decide" on this unit clears only its speed; the seed must not come back.
        var prefs = store.preferences(for: verticalA, model: .mxVertical)
        prefs.preferredDPI = nil
        store.setPreferences(prefs, for: verticalA)
        XCTAssertNil(store.preferences(for: verticalA, model: .mxVertical).preferredDPI)
        XCTAssertEqual(store.preferences(for: verticalB, model: .mxVertical).preferredDPI, 1600)
    }

    // MARK: Recording

    func testRecordStoresWhatWasLastSeen() throws {
        var store = DevicePreferencesStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(verticalA, snapshot: snapshot(connection: .unifying), now: now)

        let prefs = try XCTUnwrap(store.devices[verticalA])
        XCTAssertEqual(prefs.lastName, "MX Vertical")
        XCTAssertEqual(prefs.lastModel, .mxVertical)
        XCTAssertEqual(prefs.lastControls, [0x53, 0x56])   // configurable only, in the device's order
        XCTAssertEqual(prefs.lastConnection, "unifying")
        XCTAssertEqual(prefs.lastSeen, now)
        XCTAssertEqual(prefs.remapEnabled, true)
        XCTAssertNil(prefs.nickname)
        XCTAssertNil(prefs.preferredDPI)
    }

    func testRecordKeepsWhatTheUserChose() throws {
        var store = DevicePreferencesStore()
        store.record(verticalA, snapshot: snapshot(connection: .bluetooth), now: Date(timeIntervalSince1970: 100))
        var prefs = store.preferences(for: verticalA, model: .mxVertical)
        prefs.nickname = "Desk"
        prefs.remapEnabled = false
        prefs.preferredDPI = 1200
        store.setPreferences(prefs, for: verticalA)

        store.record(verticalA, snapshot: snapshot(connection: .usb, controls: []), now: Date(timeIntervalSince1970: 200))

        let after = try XCTUnwrap(store.devices[verticalA])
        XCTAssertEqual(after.nickname, "Desk")
        XCTAssertEqual(after.remapEnabled, false)
        XCTAssertEqual(after.preferredDPI, 1200)
        XCTAssertEqual(after.lastConnection, "usb")
        XCTAssertEqual(after.lastControls, [])
        XCTAssertEqual(after.lastSeen, Date(timeIntervalSince1970: 200))
    }

    func testTwoUnitsOfOneModelHaveIndependentPreferences() {
        var store = DevicePreferencesStore()
        store.record(verticalA, snapshot: snapshot())
        store.record(verticalB, snapshot: snapshot())
        var a = store.preferences(for: verticalA, model: .mxVertical)
        a.nickname = "Home"
        a.remapEnabled = false
        store.setPreferences(a, for: verticalA)

        XCTAssertEqual(store.preferences(for: verticalA, model: .mxVertical).nickname, "Home")
        XCTAssertNil(store.preferences(for: verticalB, model: .mxVertical).nickname)
        XCTAssertTrue(store.preferences(for: verticalB, model: .mxVertical).remapEnabled)
        XCTAssertEqual(store.devices.count, 2)
    }

    // MARK: Transient IDs

    func testTransientIDsNotPersisted() throws {
        var store = DevicePreferencesStore()
        store.record(transient, snapshot: snapshot())
        store.setPreferences(DevicePreferences(nickname: "Ghost"), for: transient)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertEqual(store.preferences(for: transient, model: .mxVertical), DevicePreferences())

        // Not even when handed in directly, set through the property, or sitting in saved data.
        XCTAssertTrue(DevicePreferencesStore(devices: [transient: DevicePreferences(nickname: "Ghost")]).devices.isEmpty)
        store.devices[transient] = DevicePreferences(nickname: "Ghost")
        let encoded = try JSONEncoder().encode(store)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Ghost"))
        XCTAssertTrue(try roundTrip(store).devices.isEmpty)

        let saved = #"{"devices":{"t:3.2":{"nickname":"Ghost"},"u:046D:B020:1A2B3C4D":{"nickname":"Real"}}}"#
        let decoded = try JSONDecoder().decode(DevicePreferencesStore.self, from: Data(saved.utf8))
        XCTAssertEqual(Array(decoded.devices.keys), [verticalA])
        XCTAssertEqual(decoded.devices[verticalA]?.nickname, "Real")
    }

    func testTransientIDsFallBackToTheModelSeed() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1000)
        XCTAssertEqual(store.preferences(for: transient, model: .mxVertical).preferredDPI, 1000)
        XCTAssertNil(store.preferences(for: transient, model: master3S).preferredDPI)
    }

    // MARK: Forget

    func testForget() {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        store.record(verticalA, snapshot: snapshot())
        store.record(verticalB, snapshot: snapshot())
        var prefs = store.preferences(for: verticalA, model: .mxVertical)
        prefs.preferredDPI = 400
        store.setPreferences(prefs, for: verticalA)

        store.forget(verticalA)
        XCTAssertNil(store.devices[verticalA])
        XCTAssertNotNil(store.devices[verticalB])
        // The model seed is not a unit's data: it survives, and the forgotten unit starts over from it.
        XCTAssertNotNil(store.models[.mxVertical])
        XCTAssertEqual(store.preferences(for: verticalA, model: .mxVertical).preferredDPI, 1600)

        store.forget(verticalA)   // forgetting twice, or an unknown unit, is harmless
        store.forget(transient)
        XCTAssertEqual(store.devices.count, 1)
    }

    func testRememberedDevicesAreNewestFirstAndExcludeConnectedOnes() {
        var store = DevicePreferencesStore()
        store.record(verticalA, snapshot: snapshot(), now: Date(timeIntervalSince1970: 100))
        store.record(verticalB, snapshot: snapshot(), now: Date(timeIntervalSince1970: 300))
        store.record(masterUnit, snapshot: snapshot(name: "MX Master 3S"), now: Date(timeIntervalSince1970: 200))
        let neverSeen = DeviceID.unit(0x1111_1111, model: .mxVertical)
        store.setPreferences(DevicePreferences(nickname: "Spare"), for: neverSeen)

        XCTAssertEqual(store.rememberedDevices().map(\.id), [verticalB, masterUnit, verticalA, neverSeen])
        XCTAssertEqual(store.rememberedDevices(excluding: [verticalB]).map(\.id), [masterUnit, verticalA, neverSeen])
        XCTAssertEqual(store.rememberedDevices(excluding: [verticalA, verticalB, masterUnit, neverSeen]).count, 0)
        XCTAssertEqual(store.rememberedDevices().last?.preferences.nickname, "Spare")
    }

    func testTrimmedNickname() {
        XCTAssertNil(DevicePreferences().trimmedNickname)
        XCTAssertNil(DevicePreferences(nickname: "").trimmedNickname)
        XCTAssertNil(DevicePreferences(nickname: "  \n ").trimmedNickname)
        XCTAssertEqual(DevicePreferences(nickname: "  Desk mouse ").trimmedNickname, "Desk mouse")
    }

    // MARK: Coding

    func testStoreRoundTripsThroughJSON() throws {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        store.record(verticalA, snapshot: snapshot(), now: Date(timeIntervalSince1970: 1_700_000_000))
        var prefs = store.preferences(for: verticalA, model: .mxVertical)
        prefs.nickname = "Desk"
        prefs.remapEnabled = false
        store.setPreferences(prefs, for: verticalA)
        store.record(masterUnit, snapshot: snapshot(name: "MX Master 3S", connection: .bolt), now: Date(timeIntervalSince1970: 1_700_000_500))

        XCTAssertEqual(try roundTrip(store), store)
    }

    func testStoredJSONUsesStringKeys() throws {
        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        store.setPreferences(DevicePreferences(nickname: "Desk"), for: verticalA)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [String: Any])
        let devices = try XCTUnwrap(object["devices"] as? [String: Any])
        XCTAssertEqual(Set(models.keys), ["046D:B020"])
        XCTAssertEqual(Set(devices.keys), ["u:046D:B020:1A2B3C4D"])
        XCTAssertEqual((models["046D:B020"] as? [String: Any])?["preferredDPI"] as? Int, 1600)
        XCTAssertEqual((devices["u:046D:B020:1A2B3C4D"] as? [String: Any])?["nickname"] as? String, "Desk")
    }

    func testDecodingSkipsBadEntriesAndKeepsTheRest() throws {
        let json = """
        {
          "futureTopLevel": [1, 2, 3],
          "models": {
            "046D:B020": {"preferredDPI": 1600, "futureField": true},
            "not a model": {"preferredDPI": 900},
            "046D:B034": "oops",
            "name:some mouse": {"preferredDPI": 700}
          },
          "devices": {
            "u:046D:B020:1A2B3C4D": {"nickname": "Desk", "remapEnabled": false, "lastModel": "046D:B020"},
            "u:046D:B020:5E6F7081": 42,
            "": {"nickname": "Empty key"},
            "s:046D:B034:ABC123": {"lastName": "MX Master 3S", "lastControls": [83, 86, "x", 70000, -1]}
          }
        }
        """
        let store = try JSONDecoder().decode(DevicePreferencesStore.self, from: Data(json.utf8))

        XCTAssertEqual(Set(store.models.keys), [.mxVertical, ModelKey(name: "some mouse")])
        XCTAssertEqual(store.models[.mxVertical]?.preferredDPI, 1600)
        XCTAssertEqual(Set(store.devices.keys), [verticalA, DeviceID.serial("ABC123", model: master3S)])
        XCTAssertEqual(store.devices[verticalA]?.nickname, "Desk")
        XCTAssertEqual(store.devices[verticalA]?.remapEnabled, false)
        XCTAssertEqual(store.devices[verticalA]?.lastModel, .mxVertical)
        // Unreadable list elements are dropped one by one.
        XCTAssertEqual(store.devices[DeviceID.serial("ABC123", model: master3S)]?.lastControls, [83, 86])
    }

    func testDecodingGarbageGivesDefaults() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DevicePreferencesStore.self, from: Data("{}".utf8)), DevicePreferencesStore())
        XCTAssertEqual(
            try decoder.decode(DevicePreferencesStore.self, from: Data(#"{"models":[1,2],"devices":"none"}"#.utf8)),
            DevicePreferencesStore()
        )
        XCTAssertThrowsError(try decoder.decode(DevicePreferencesStore.self, from: Data("[]".utf8)))
    }

    func testPreferencesDecodeTolerantly() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DevicePreferences.self, from: Data("{}".utf8)), DevicePreferences())

        let messy = """
        {"nickname": 5, "remapEnabled": "yes", "preferredDPI": "fast", "lastName": ["x"],
         "lastModel": "garbage", "lastControls": "none", "lastConnection": 1, "lastSeen": "yesterday"}
        """
        XCTAssertEqual(try decoder.decode(DevicePreferences.self, from: Data(messy.utf8)), DevicePreferences())

        let partial = #"{"nickname":"Desk","preferredDPI":1600,"lastModel":"046d:b034"}"#
        let prefs = try decoder.decode(DevicePreferences.self, from: Data(partial.utf8))
        XCTAssertEqual(prefs.nickname, "Desk")
        XCTAssertEqual(prefs.preferredDPI, 1600)
        XCTAssertEqual(prefs.lastModel, ModelKey(productID: 0xB034))   // keys are normalized to upper case
        XCTAssertTrue(prefs.remapEnabled)
        XCTAssertEqual(prefs.lastControls, [])
    }

    func testNonPositivePreferredSpeedDecodesAsNil() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(DevicePreferences.self, from: Data(#"{"preferredDPI":0}"#.utf8)).preferredDPI)
        XCTAssertNil(try decoder.decode(DevicePreferences.self, from: Data(#"{"preferredDPI":-800}"#.utf8)).preferredDPI)
    }

    func testPreferencesRoundTripIncludingDates() throws {
        let prefs = DevicePreferences(
            nickname: "Desk",
            remapEnabled: false,
            preferredDPI: 1600,
            lastName: "MX Vertical",
            lastModel: .mxVertical,
            lastControls: [0x53, 0x56, 0xC3],
            lastConnection: "bolt",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try JSONDecoder().decode(DevicePreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
    }

    // MARK: UserDefaults

    func testSaveAndLoadThroughUserDefaults() throws {
        let suiteName = "io.github.upright.tests.devicePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DevicePreferencesStore.load(from: defaults), DevicePreferencesStore())

        var store = DevicePreferencesStore()
        store.migrateLegacy(preferredDPI: 1600)
        store.record(verticalA, snapshot: snapshot(), now: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(to: defaults)

        XCTAssertNotNil(defaults.data(forKey: "devicePreferences.v1"))
        XCTAssertEqual(DevicePreferencesStore.defaultsKey, "devicePreferences.v1")
        XCTAssertEqual(DevicePreferencesStore.load(from: defaults), store)
    }

    func testUnreadableSavedDataLoadsAsEmpty() throws {
        let suiteName = "io.github.upright.tests.devicePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not json".utf8), forKey: DevicePreferencesStore.defaultsKey)
        XCTAssertEqual(DevicePreferencesStore.load(from: defaults), DevicePreferencesStore())
        defaults.set("a string, not data", forKey: DevicePreferencesStore.defaultsKey)
        XCTAssertEqual(DevicePreferencesStore.load(from: defaults), DevicePreferencesStore())
    }
}
