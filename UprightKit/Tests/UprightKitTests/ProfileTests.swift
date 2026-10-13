import XCTest
@testable import UprightKit

@MainActor
final class ProfileTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let xcode = "com.apple.dt.Xcode"

    private var profiles: MappingProfiles {
        var profiles = MappingProfiles(global: .legacyDefaults)
        profiles.upsert(AppProfile(bundleID: safari, displayName: "Safari", overrides: [
            KnownControl.back: .system(.previousTab),
            KnownControl.dpiSwitch: .deviceDefault,
        ]))
        profiles.upsert(AppProfile(bundleID: xcode, displayName: "Xcode", isEnabled: false, overrides: [
            KnownControl.back: .system(.undo),
        ]))
        return profiles
    }

    func testEffectiveMappingsFallBackToGlobalPerButton() async {
        let effective = profiles.effectiveMappings(forBundleID: safari)
        XCTAssertEqual(effective[KnownControl.back], .system(.previousTab))
        XCTAssertEqual(effective[KnownControl.forward], .system(.navigateForward))
        // An explicit "Default" override hands the button back to the mouse in this app.
        XCTAssertEqual(effective[KnownControl.dpiSwitch], .deviceDefault)
        XCTAssertEqual(effective.divertedControls(accessibilityGranted: true), [KnownControl.back, KnownControl.forward])
    }

    func testUnknownOrDisabledAppsUseGlobal() async {
        XCTAssertEqual(profiles.effectiveMappings(forBundleID: nil), .legacyDefaults)
        XCTAssertEqual(profiles.effectiveMappings(forBundleID: "com.example.unknown"), .legacyDefaults)
        XCTAssertEqual(profiles.effectiveMappings(forBundleID: xcode), .legacyDefaults)
    }

    func testBundleIDMatchingIgnoresCase() async {
        XCTAssertEqual(profiles.effectiveMappings(forBundleID: "COM.APPLE.SAFARI")[KnownControl.back], .system(.previousTab))
    }

    func testAddRemoveAndUpsertKeepOneProfilePerApp() async {
        var profiles = self.profiles
        profiles.addApp(bundleID: safari, displayName: "Other Name")
        XCTAssertEqual(profiles.apps.count, 2)
        XCTAssertEqual(profiles[app: safari]?.displayName, "Safari")

        profiles[app: "COM.apple.safari"]?.isEnabled = false
        XCTAssertEqual(profiles.apps.count, 2)
        XCTAssertEqual(profiles.effectiveMappings(forBundleID: safari), .legacyDefaults)

        profiles.removeApp(bundleID: xcode)
        XCTAssertEqual(profiles.apps.map(\.bundleID), [safari])
        profiles[app: safari] = nil
        XCTAssertTrue(profiles.apps.isEmpty)
    }

    func testDuplicateProfilesInStoredDataAreMerged() async throws {
        let json = #"{"schemaVersion":2,"global":{"actions":{}},"apps":[{"bundleID":"a","displayName":"A","isEnabled":true,"overrides":{}},{"bundleID":"A","displayName":"A2","isEnabled":true,"overrides":{}}]}"#
        let report = MappingDecodingReport()
        let decoded = try MappingStore.decoder(report: report).decode(MappingProfiles.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.apps.count, 1)
        XCTAssertEqual(decoded.apps.first?.displayName, "A2")
        XCTAssertEqual(report.issues.count, 1)
    }

    func testAllActiveActionsIgnoreDisabledProfiles() async {
        let actions = profiles.allActiveActions
        XCTAssertTrue(actions.contains(.system(.previousTab)))
        XCTAssertFalse(actions.contains(.system(.undo)))
    }

    // MARK: Switching profiles mid-press

    func testReleaseMatchesPressAcrossProfileSwitch() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: profiles.effectiveMappings(forBundleID: safari), performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.mappings = profiles.effectiveMappings(forBundleID: nil)
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        let previousTab = SystemAction.previousTab.effect
        XCTAssertEqual(performer.log.map(\.0), [previousTab, previousTab])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
    }

    func testButtonNativeInOldAppDoesNotFireInNewApp() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: profiles.effectiveMappings(forBundleID: safari), performer: performer)

        // Top button is native in Safari; the user switches to an app where it opens Mission Control.
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press))
        engine.mappings = profiles.effectiveMappings(forBundleID: nil)
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release))

        // And a held key in the new app isn't released by the old app's press.
        engine.handle(ButtonEvent(cid: KnownControl.forward, phase: .press))
        engine.mappings = profiles.effectiveMappings(forBundleID: safari)
        engine.handle(ButtonEvent(cid: KnownControl.forward, phase: .release))

        let forward = SystemAction.navigateForward.effect
        XCTAssertEqual(performer.log.map(\.0), [forward, forward])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
    }

    func testSwitchKeepsPressedControlsUntilRelease() async {
        let engine = RemapEngine(mappings: profiles.effectiveMappings(forBundleID: nil), performer: RecordingPerformer())
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press))
        engine.mappings = profiles.effectiveMappings(forBundleID: safari)
        // The app model keeps this diverted until it's released, so the release still arrives.
        XCTAssertEqual(engine.pressedControls, [KnownControl.dpiSwitch])
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release))
        XCTAssertTrue(engine.pressedControls.isEmpty)
    }
}
