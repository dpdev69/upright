import XCTest
@testable import UprightKit

@MainActor
final class RecordingPerformer: ActionPerforming {
    var log: [(ActionEffect, ActionPhase)] = []

    func perform(_ effect: ActionEffect, phase: ActionPhase) {
        log.append((effect, phase))
    }
}

@MainActor
final class MappingTests: XCTestCase {
    func testFreshDefaultsDivertNothing() async {
        XCTAssertTrue(ButtonMappings.defaults.isEmpty)
        XCTAssertEqual(ButtonMappings.defaults.divertedControls(accessibilityGranted: true), [])
        XCTAssertEqual(ButtonMappings.defaults[KnownControl.back], .deviceDefault)
    }

    func testLegacyDefaultsMapSideAndTopButtons() async {
        let mappings = ButtonMappings.legacyDefaults
        XCTAssertEqual(mappings[KnownControl.back], .system(.navigateBack))
        XCTAssertEqual(mappings[KnownControl.forward], .system(.navigateForward))
        XCTAssertEqual(mappings[KnownControl.dpiSwitch], .system(.missionControl))
        XCTAssertEqual(mappings[KnownControl.middleClick], .deviceDefault)
    }

    func testInitDropsDeviceDefaultEntries() async {
        let mappings = ButtonMappings([KnownControl.back: .deviceDefault, KnownControl.forward: .disabled])
        XCTAssertEqual(mappings.mappedControls.keys.sorted(), [KnownControl.forward])
        XCTAssertEqual(mappings, ButtonMappings([KnownControl.forward: .disabled]))
    }

    func testDiversionRespectsAccessibility() async {
        var mappings = ButtonMappings.legacyDefaults
        mappings[KnownControl.middleClick] = .disabled
        XCTAssertEqual(mappings.divertedControls(accessibilityGranted: true), [0x52, 0x53, 0x56, 0xFD])
        // Mission Control and "do nothing" don't post events, so they work without Accessibility.
        XCTAssertEqual(mappings.divertedControls(accessibilityGranted: false), [0x52, 0xFD])

        mappings[KnownControl.back] = .deviceDefault
        XCTAssertFalse(mappings.mappedControls.keys.contains(KnownControl.back))
    }

    func testNewActionsDontNeedAccessibility() async {
        let mappings = ButtonMappings([
            0x52: .launchApp(AppReference(bundleID: "com.apple.Safari", displayName: "Safari")),
            0x53: .openURL(URL(string: "https://example.com")!),
            0x56: .runShortcut("Focus"),
            0xFD: .device(.cycleDPI),
        ])
        XCTAssertEqual(mappings.divertedControls(accessibilityGranted: false), [0x52, 0x53, 0x56, 0xFD])
    }

    func testKeyComboDisplay() async {
        XCTAssertEqual(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command).displayString, "⌘[")
        XCTAssertEqual(KeyCombo(keyCode: KeyCode.tab, modifiers: [.command, .control, .option, .shift]).displayString, "⌃⌥⇧⌘⇥")
        XCTAssertEqual(KeyCombo(keyCode: 0x7A).displayString, "F1")
        XCTAssertTrue(KeyCombo(keyCode: KeyCode.leftArrow).isNavigationKey)
    }

    func testKeyFlagsMatchRealKeyboards() async {
        for arrow in [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow] {
            let combo = KeyCombo(keyCode: arrow)
            XCTAssertTrue(combo.carriesFunctionFlag)
            XCTAssertTrue(combo.carriesNumericPadFlag)
        }
        for key in [KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown, KeyCode.forwardDelete, KeyCode.help, 0x7A] {
            let combo = KeyCombo(keyCode: key)
            XCTAssertTrue(combo.carriesFunctionFlag, "\(key)")
            XCTAssertFalse(combo.carriesNumericPadFlag, "\(key)")
        }
        let keypadEnter = KeyCombo(keyCode: 0x4C)
        XCTAssertFalse(keypadEnter.carriesFunctionFlag)
        XCTAssertTrue(keypadEnter.carriesNumericPadFlag)
        let letter = KeyCombo(keyCode: KeyCode.c, modifiers: .command)
        XCTAssertFalse(letter.carriesFunctionFlag)
        XCTAssertFalse(letter.carriesNumericPadFlag)
    }

    func testModifierElementsAreInMenuOrder() async {
        let all: KeyModifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(all.elements, [.control, .option, .shift, .command])
        XCTAssertEqual(all.elements.compactMap(KeyCode.modifierKey(for:)), [0x3B, 0x3A, 0x38, 0x37])
    }

    func testEveryCategoryHasActions() async {
        for category in SystemAction.Category.allCases {
            XCTAssertFalse(SystemAction.actions(in: category).isEmpty, category.rawValue)
        }
    }

    func testActionValidation() async {
        XCTAssertTrue(ButtonAction.device(.setDPI(1000)).isValid)
        XCTAssertFalse(ButtonAction.device(.setDPI(50)).isValid)
        XCTAssertFalse(ButtonAction.runShortcut("  ").isValid)
        XCTAssertFalse(ButtonAction.launchApp(AppReference(bundleID: "", displayName: "x")).isValid)
        XCTAssertFalse(ButtonAction.openURL(URL(string: "relative/path")!).isValid)
        XCTAssertTrue(ButtonAction.openURL(URL(string: "https://example.com")!).isValid)
    }

    // MARK: Engine

    func testEngineFollowsButtonStateForKeys() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        let combo = KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)
        XCTAssertEqual(performer.log.map(\.0), [.keyCombo(combo), .keyCombo(combo)])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
    }

    func testEngineFiresOneShotActionsOnce() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release))

        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testVolumeKeysTrackButtonStateSoTheyCanRepeat() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([KnownControl.back: .system(.volumeUp), KnownControl.forward: .system(.mute)]), performer: performer)

        for cid in [KnownControl.back, KnownControl.forward] {
            engine.handle(ButtonEvent(cid: cid, phase: .press))
            engine.handle(ButtonEvent(cid: cid, phase: .release))
        }
        XCTAssertEqual(performer.log.map(\.0), [.media(.volumeUp), .media(.volumeUp), .media(.mute)])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up, .down])
    }

    func testEngineReleasesWhatWasPressedEvenAfterRemap() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.mappings[KnownControl.back] = .system(.copy)
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        let combo = KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)
        XCTAssertEqual(performer.log.map(\.0), [.keyCombo(combo), .keyCombo(combo)])
    }

    func testDisablingEngineReleasesHeldKeysAndIgnoresPresses() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.forward, phase: .press))
        engine.isEnabled = false
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))

        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
    }

    func testDisabledActionDoesNothing() async {
        let performer = RecordingPerformer()
        var mappings = ButtonMappings()
        mappings[KnownControl.middleClick] = .disabled
        let engine = RemapEngine(mappings: mappings, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.middleClick, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.middleClick, phase: .release))
        XCTAssertTrue(performer.log.isEmpty)
    }

    func testDeviceActionsGoToTheDeviceHandlerOncePerPress() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([KnownControl.dpiSwitch: .device(.setDPI(1600))]), performer: performer)
        var received: [DeviceAction] = []
        engine.onDeviceAction = { received.append($0) }

        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release))

        XCTAssertEqual(received, [.setDPI(1600)])
        XCTAssertTrue(performer.log.isEmpty)
    }

    func testRepeatedPressReleasesThePreviousOne() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        XCTAssertEqual(performer.log.map(\.1), [.down, .up, .down, .up])
    }

    func testPressedControlsTrackPhysicalButtons() async {
        let engine = RemapEngine(mappings: .defaults, performer: RecordingPerformer())
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.forward, phase: .press))
        XCTAssertEqual(engine.pressedControls, [KnownControl.back, KnownControl.forward])
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))
        XCTAssertEqual(engine.pressedControls, [KnownControl.forward])
        engine.releaseAll()
        XCTAssertEqual(engine.pressedControls, [])
    }
}
