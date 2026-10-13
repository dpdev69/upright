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
    func testDefaultsMapSideAndTopButtons() async {
        let mappings = ButtonMappings.defaults
        XCTAssertEqual(mappings[KnownControl.back], .system(.navigateBack))
        XCTAssertEqual(mappings[KnownControl.forward], .system(.navigateForward))
        XCTAssertEqual(mappings[KnownControl.dpiSwitch], .system(.missionControl))
        XCTAssertEqual(mappings[KnownControl.middleClick], .deviceDefault)
    }

    func testDiversionRespectsAccessibility() async {
        var mappings = ButtonMappings.defaults
        mappings[KnownControl.middleClick] = .disabled
        XCTAssertEqual(mappings.divertedControls(accessibilityGranted: true), [0x52, 0x53, 0x56, 0xFD])
        // Mission Control and "do nothing" don't post events, so they work without Accessibility.
        XCTAssertEqual(mappings.divertedControls(accessibilityGranted: false), [0x52, 0xFD])

        mappings[KnownControl.back] = .deviceDefault
        XCTAssertFalse(mappings.mappedControls.keys.contains(KnownControl.back))
    }

    func testMappingsRoundTripThroughUserDefaults() async throws {
        let suite = "UprightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ButtonMappings.load(from: defaults), .defaults)

        var mappings = ButtonMappings()
        mappings[KnownControl.back] = .keyCombo(KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T"))
        mappings[KnownControl.dpiSwitch] = .system(.playPause)
        mappings.save(to: defaults)

        let loaded = ButtonMappings.load(from: defaults)
        XCTAssertEqual(loaded, mappings)
        XCTAssertEqual(loaded[KnownControl.back].title, "⇧⌘T")
    }

    func testKeyComboDisplay() async {
        XCTAssertEqual(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command).displayString, "⌘[")
        XCTAssertEqual(KeyCombo(keyCode: KeyCode.tab, modifiers: [.command, .control, .option, .shift]).displayString, "⌃⌥⇧⌘⇥")
        XCTAssertEqual(KeyCombo(keyCode: 0x7A).displayString, "F1")
        XCTAssertTrue(KeyCombo(keyCode: KeyCode.leftArrow).isNavigationKey)
    }

    func testEveryCategoryHasActions() async {
        for category in SystemAction.Category.allCases {
            XCTAssertFalse(SystemAction.actions(in: category).isEmpty, category.rawValue)
        }
    }

    func testEngineFollowsButtonStateForKeys() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        let combo = KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)
        XCTAssertEqual(performer.log.map(\.0), [.keyCombo(combo), .keyCombo(combo)])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
    }

    func testEngineFiresOneShotActionsOnce() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press))
        engine.handle(ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release))

        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testEngineReleasesWhatWasPressedEvenAfterRemap() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)

        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .press))
        engine.mappings[KnownControl.back] = .system(.copy)
        engine.handle(ButtonEvent(cid: KnownControl.back, phase: .release))

        let combo = KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)
        XCTAssertEqual(performer.log.map(\.0), [.keyCombo(combo), .keyCombo(combo)])
    }

    func testDisablingEngineReleasesHeldKeysAndIgnoresPresses() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)

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
}
