import XCTest
@testable import UprightKit

@MainActor
final class GestureTests: XCTestCase {
    private let cid = KnownControl.dpiSwitch
    private let set = GestureSet(
        tap: .system(.copy),
        up: .system(.missionControl),
        down: .system(.appExpose),
        left: .system(.spaceLeft),
        right: .device(.cycleDPI)
    )

    private func engine(_ performer: RecordingPerformer, set: GestureSet? = nil) -> RemapEngine {
        let engine = RemapEngine(mappings: ButtonMappings([cid: .gestures(set ?? self.set)]), performer: performer)
        engine.rawGestureThreshold = 40
        return engine
    }

    private func press(_ engine: RemapEngine) { engine.handle(ButtonEvent(cid: cid, phase: .press)) }
    private func release(_ engine: RemapEngine) { engine.handle(ButtonEvent(cid: cid, phase: .release)) }

    // MARK: Recognizer

    func testRecognizerWaitsForThreshold() async {
        var recognizer = GestureRecognizer(threshold: 40)
        XCTAssertNil(recognizer.add(dx: 0, dy: -20))
        XCTAssertNil(recognizer.add(dx: 0, dy: -19))
        XCTAssertEqual(recognizer.add(dx: 0, dy: -1), .up)
        XCTAssertFalse(recognizer.isTap)
    }

    func testRecognizerFiresOnceAndIgnoresLaterMovement() async {
        var recognizer = GestureRecognizer(threshold: 10)
        XCTAssertEqual(recognizer.add(dx: 12, dy: 0), .right)
        XCTAssertNil(recognizer.add(dx: -100, dy: 0))
        XCTAssertEqual(recognizer.firedDirection, .right)
    }

    func testRecognizerPicksDominantAxisOnDiagonals() async {
        var downish = GestureRecognizer(threshold: 40)
        XCTAssertEqual(downish.add(dx: 25, dy: 35), .down)
        var leftish = GestureRecognizer(threshold: 40)
        XCTAssertEqual(leftish.add(dx: -35, dy: -25), .left)
        var upish = GestureRecognizer(threshold: 40)
        XCTAssertEqual(upish.add(dx: 10, dy: -45), .up)
    }

    func testSmallJitterIsStillATap() async {
        var recognizer = GestureRecognizer()
        XCTAssertNil(recognizer.add(dx: 3, dy: -2))
        XCTAssertNil(recognizer.add(dx: -4, dy: 5))
        XCTAssertTrue(recognizer.isTap)
    }

    // MARK: Engine

    func testTapFiresTapActionOnRelease() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)

        press(engine)
        XCTAssertTrue(performer.log.isEmpty, "nothing fires until the hold ends")
        XCTAssertEqual(engine.gestureControls, [cid])
        release(engine)

        let combo = KeyCombo(keyCode: KeyCode.c, modifiers: .command)
        XCTAssertEqual(performer.log.map(\.0), [.keyCombo(combo), .keyCombo(combo)])
        XCTAssertEqual(performer.log.map(\.1), [.down, .up])
        XCTAssertEqual(engine.gestureControls, [])
    }

    func testEachDirectionFiresItsAction() async {
        let cases: [(Int, Int, ActionEffect)] = [
            (0, -50, .missionControl(.missionControl)),
            (0, 50, .missionControl(.appExpose)),
            (-50, 0, .keyCombo(KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control))),
        ]
        for (dx, dy, expected) in cases {
            let performer = RecordingPerformer()
            let engine = engine(performer)
            press(engine)
            engine.handlePointerDelta(dx: dx, dy: dy)
            release(engine)
            XCTAssertEqual(performer.log.first?.0, expected)
            if expected.tracksButtonState {
                XCTAssertEqual(performer.log.map(\.1), [.down, .up])
            } else {
                XCTAssertEqual(performer.log.map(\.1), [.down])
            }
        }
    }

    func testDeviceActionSlotGoesToDeviceHandler() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)
        var received: [DeviceAction] = []
        engine.onDeviceAction = { received.append($0) }

        press(engine)
        engine.handlePointerDelta(dx: 60, dy: 0)
        release(engine)

        XCTAssertEqual(received, [.cycleDPI])
        XCTAssertTrue(performer.log.isEmpty)
    }

    func testDirectionFiresOnceAndSuppressesTap() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)

        press(engine)
        engine.handlePointerDelta(dx: 0, dy: -30)
        engine.handlePointerDelta(dx: 0, dy: -30)
        engine.handlePointerDelta(dx: 0, dy: 200)
        release(engine)

        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testMovementBelowThresholdIsATap() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)
        engine.rawGestureThreshold = 100

        press(engine)
        engine.handlePointerDelta(dx: 60, dy: 60)
        release(engine)

        XCTAssertEqual(performer.log.count, 2)
        XCTAssertEqual(performer.log.first?.0, .keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: .command)))
    }

    func testRawThresholdIsAPhysicalDistance() async {
        XCTAssertEqual(GestureRecognizer.rawThreshold(dpi: 1000), 6 / 25.4 * 1000, accuracy: 0.001)
        XCTAssertEqual(GestureRecognizer.rawThreshold(dpi: 4000), 4 * GestureRecognizer.rawThreshold(dpi: 1000), accuracy: 0.001)
        XCTAssertEqual(GestureRecognizer.rawThreshold(dpi: nil), GestureRecognizer.rawThreshold(dpi: 1000))
        XCTAssertEqual(GestureRecognizer.rawThreshold(dpi: 0), GestureRecognizer.rawThreshold(dpi: 1000))
    }

    func testSmallHandMovementAtHighDPIIsATap() async {
        // 120 counts at 4000 DPI is under 1 mm: a click, not a gesture.
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([cid: .gestures(set)]), performer: performer)
        engine.rawGestureThreshold = GestureRecognizer.rawThreshold(dpi: 4000)
        press(engine)
        engine.handlePointerDelta(dx: 0, dy: -120, source: .rawSensor)
        release(engine)
        XCTAssertEqual(performer.log.first?.0, .keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: .command)))

        performer.log.removeAll()
        press(engine)
        engine.handlePointerDelta(dx: 0, dy: -1000, source: .rawSensor)
        release(engine)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testCursorFallbackUsesPointThresholdAndItsOwnDeltas() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([cid: .gestures(set)]), performer: performer)
        engine.rawGestureThreshold = 1000
        engine.gestureSource = { _ in .cursor }

        press(engine)
        engine.handlePointerDelta(dx: 0, dy: -500, source: .rawSensor)
        XCTAssertTrue(performer.log.isEmpty, "raw deltas don't feed a cursor-tracked gesture")
        engine.handlePointerDelta(dx: 0, dy: -Int(GestureRecognizer.cursorThreshold), source: .cursor)
        release(engine)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testMovementWithoutHeldGestureButtonIsIgnored() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)
        engine.handlePointerDelta(dx: 0, dy: -100)
        XCTAssertTrue(performer.log.isEmpty)
    }

    func testEmptySlotsDoNothing() async {
        let performer = RecordingPerformer()
        let engine = engine(performer, set: GestureSet(up: .system(.missionControl)))

        press(engine)
        release(engine)
        press(engine)
        engine.handlePointerDelta(dx: 0, dy: 100)
        release(engine)

        XCTAssertTrue(performer.log.isEmpty)
    }

    func testProfileSwitchMidHoldKeepsTheGestureFromThePress() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)

        press(engine)
        engine.mappings = ButtonMappings([cid: .system(.paste)])
        engine.handlePointerDelta(dx: 0, dy: -50)
        release(engine)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])

        // The reverse: a plain press stays plain even if gestures arrive mid-hold.
        performer.log.removeAll()
        engine.mappings = ButtonMappings([cid: .system(.missionControl)])
        press(engine)
        engine.mappings = ButtonMappings([cid: .gestures(set)])
        engine.handlePointerDelta(dx: 0, dy: -50)
        release(engine)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testReleaseAllCancelsGesturesWithoutFiring() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)

        press(engine)
        engine.releaseAll()
        XCTAssertEqual(engine.gestureControls, [])
        engine.handlePointerDelta(dx: 0, dy: -100)
        release(engine)

        XCTAssertTrue(performer.log.isEmpty)
    }

    func testDisablingEngineCancelsGestures() async {
        let performer = RecordingPerformer()
        let engine = engine(performer)

        press(engine)
        engine.isEnabled = false
        engine.handlePointerDelta(dx: 0, dy: -100)
        release(engine)

        XCTAssertTrue(performer.log.isEmpty)
    }

    // MARK: Model

    func testGestureActionProperties() async {
        let action = ButtonAction.gestures(set)
        XCTAssertEqual(action.kind, .gestures)
        XCTAssertNil(action.effect)
        XCTAssertTrue(action.isGestures)
        XCTAssertTrue(action.requiresDiversion)
        XCTAssertTrue(action.requiresAccessibility, "the tap slot posts a key combo")
        XCTAssertTrue(action.isValid)
        XCTAssertFalse(ButtonAction.gestures(GestureSet(up: .system(.missionControl))).requiresAccessibility)
        XCTAssertEqual(
            ButtonMappings([cid: action]).divertedControls(accessibilityGranted: false), [],
            "needs Accessibility, so it stays native until granted"
        )
    }

    func testGestureControlsFollowDiversionRules() async {
        let mappings = ButtonMappings([
            cid: .gestures(set),
            KnownControl.back: .gestures(GestureSet(up: .system(.missionControl))),
            KnownControl.forward: .system(.missionControl),
        ])
        XCTAssertEqual(mappings.gestureControls(accessibilityGranted: true), [cid, KnownControl.back])
        XCTAssertEqual(mappings.gestureControls(accessibilityGranted: false), [KnownControl.back])
    }

    func testNestedOrInvalidSlotsAreInvalid() async {
        XCTAssertFalse(ButtonAction.gestures(GestureSet(tap: .gestures(GestureSet()))).isValid)
        XCTAssertFalse(ButtonAction.gestures(GestureSet(left: .runShortcut(" "))).isValid)
        XCTAssertTrue(ButtonAction.gestures(GestureSet()).isValid)
        XCTAssertTrue(GestureSet().isEmpty)
        XCTAssertTrue(GestureSet.standard.isValid)
    }

    func testGesturesRoundTripThroughJSON() async throws {
        let mappings = ButtonMappings([cid: .gestures(set), KnownControl.back: .system(.navigateBack)])
        let data = try JSONEncoder().encode(mappings)
        XCTAssertEqual(try JSONDecoder().decode(ButtonMappings.self, from: data), mappings)
    }

    func testExistingEncodingsStillDecode() async throws {
        let json = #"{"actions":{"83":{"system":{"_0":"navigateBack"}},"86":{"device":{"_0":{"setDPI":{"_0":800}}}}}}"#
        let mappings = try JSONDecoder().decode(ButtonMappings.self, from: Data(json.utf8))
        XCTAssertEqual(mappings[83], .system(.navigateBack))
        XCTAssertEqual(mappings[86], .device(.setDPI(800)))
    }

    func testGestureSlotsDecodeTolerantly() async throws {
        // Missing slots, an unknown action and a nested gesture all become Do Nothing.
        let json = #"""
        {"actions":{"253":{"gestures":{"_0":{
            "up":{"system":{"_0":"missionControl"}},
            "down":{"teleport":{}},
            "left":{"gestures":{"_0":{}}}
        }}}}}
        """#
        let report = MappingDecodingReport()
        let decoder = JSONDecoder()
        decoder.userInfo[.mappingReport] = report
        let mappings = try decoder.decode(ButtonMappings.self, from: Data(json.utf8))
        XCTAssertEqual(mappings[253], .gestures(GestureSet(up: .system(.missionControl))))
        XCTAssertEqual(report.issues.count, 2)
    }
}
