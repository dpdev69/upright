import XCTest
@testable import UprightKit

/// Engine state is per device: the same button held on two mice is two independent holds.
@MainActor
final class RemapEngineMultiSourceTests: XCTestCase {
    /// Shared mutable state for the engine's `@MainActor` provider closures.
    @MainActor
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let a = DeviceAddress(link: 1, index: DeviceAddress.direct)
    private let b = DeviceAddress(link: 2, index: 2)
    private let back = KnownControl.back
    private let top = KnownControl.dpiSwitch
    private let backCombo = ActionEffect.keyCombo(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command))
    private let copyCombo = ActionEffect.keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: .command))
    private let gestureSet = GestureSet(
        tap: .system(.copy),
        up: .system(.missionControl),
        down: .system(.appExpose),
        left: .system(.spaceLeft),
        right: .device(.cycleDPI)
    )

    private func press(_ engine: RemapEngine, _ cid: UInt16, on source: DeviceAddress) {
        engine.handle(ButtonEvent(cid: cid, phase: .press, source: source))
    }

    private func release(_ engine: RemapEngine, _ cid: UInt16, on source: DeviceAddress) {
        engine.handle(ButtonEvent(cid: cid, phase: .release, source: source))
    }

    private func gestureEngine(_ performer: RecordingPerformer) -> RemapEngine {
        let engine = RemapEngine(mappings: ButtonMappings([top: .gestures(gestureSet)]), performer: performer)
        engine.rawGestureThreshold = 40
        return engine
    }

    // MARK: Holds

    func testSameCIDHeldOnTwoSourcesIsIndependent() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        press(engine, back, on: a)
        press(engine, back, on: b)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down], "B's press doesn't end A's hold")
        XCTAssertEqual(engine.pressedControls(for: a), [back])
        XCTAssertEqual(engine.pressedControls(for: b), [back])

        release(engine, back, on: a)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up])
        XCTAssertEqual(engine.pressedControls(for: a), [])
        XCTAssertEqual(engine.pressedControls(for: b), [back], "B is still held")
        XCTAssertEqual(engine.held.keys.sorted(), [ControlKey(source: b, cid: back)])

        release(engine, back, on: b)
        XCTAssertEqual(performer.log.map(\.0), [backCombo, backCombo, backCombo, backCombo])
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up, .up])
        XCTAssertTrue(engine.held.isEmpty)
        XCTAssertTrue(engine.pressedKeys.isEmpty)
    }

    func testInterleavedReleasesEndOnlyTheirOwnHold() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)
        engine.mappingsProvider = { [a] source in
            source == a
                ? ButtonMappings([KnownControl.back: .system(.navigateBack)])
                : ButtonMappings([KnownControl.back: .system(.copy)])
        }

        press(engine, back, on: a)
        press(engine, back, on: b)
        release(engine, back, on: a)
        XCTAssertEqual(performer.log.map(\.0), [backCombo, copyCombo, backCombo], "A's release ends A's effect, not B's")
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up])

        press(engine, back, on: a)
        release(engine, back, on: b)
        release(engine, back, on: a)
        XCTAssertEqual(performer.log.dropFirst(3).map(\.0), [backCombo, copyCombo, backCombo])
        XCTAssertEqual(performer.log.dropFirst(3).map(\.1), [.down, .up, .up])
    }

    func testLostReleaseHeuristicIsPerSource() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        press(engine, back, on: a)
        press(engine, back, on: b)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down], "a press on another mouse isn't a lost release")

        // A second press on A without a release: A's first hold ends, B's stays.
        press(engine, back, on: a)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up, .down])
        XCTAssertEqual(engine.held.count, 2)

        release(engine, back, on: a)
        release(engine, back, on: b)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up, .down, .up, .up])
        XCTAssertTrue(engine.held.isEmpty)
    }

    func testReleaseAllSourceLeavesOthersHeld() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)
        engine.rawGestureThreshold = 40
        engine.mappingsProvider = { [a, gestureSet] source in
            var mappings = ButtonMappings.legacyDefaults
            if source == a { mappings[KnownControl.dpiSwitch] = .gestures(gestureSet) }
            return mappings
        }

        press(engine, back, on: a)
        press(engine, top, on: a)
        press(engine, back, on: b)
        press(engine, KnownControl.forward, on: b)
        XCTAssertEqual(engine.gestureControls(for: a), [top])

        engine.releaseAll(source: a)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .down, .up], "only A's held key goes up")
        XCTAssertEqual(performer.log.last?.0, backCombo)
        XCTAssertEqual(engine.pressedControls(for: a), [])
        XCTAssertEqual(engine.gestureControls(for: a), [], "A's gesture is cancelled")
        XCTAssertEqual(engine.pressedControls(for: b), [back, KnownControl.forward])
        XCTAssertEqual(engine.held.keys.map(\.source), [b, b])

        // A's late movement and release do nothing; B's release still ends B's hold.
        engine.handlePointerDelta(PointerDelta(source: a, dx: 0, dy: -100))
        release(engine, top, on: a)
        release(engine, back, on: a)
        XCTAssertEqual(performer.log.count, 4)
        release(engine, back, on: b)
        release(engine, KnownControl.forward, on: b)
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .down, .up, .up, .up])
        XCTAssertTrue(engine.held.isEmpty)
    }

    func testDisablingEngineReleasesEverySource() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)

        press(engine, back, on: a)
        press(engine, back, on: b)
        engine.isEnabled = false
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up, .up])
        XCTAssertTrue(engine.pressedKeys.isEmpty)
        XCTAssertTrue(engine.held.isEmpty)
    }

    // MARK: Gestures

    func testGestureDeltasRouteBySource() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)

        press(engine, top, on: a)
        press(engine, top, on: b)
        XCTAssertEqual(engine.gestureControls(for: a), [top])
        XCTAssertEqual(engine.gestureControls(for: b), [top])

        engine.handlePointerDelta(PointerDelta(source: a, dx: 0, dy: -50))
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)], "only A's gesture moved")

        engine.handlePointerDelta(PointerDelta(source: b, dx: 0, dy: 50))
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl), .missionControl(.appExpose)])

        // A delta from a third mouse with no gesture held reaches nobody.
        engine.handlePointerDelta(PointerDelta(source: DeviceAddress(link: 3, index: 1), dx: -200, dy: 0))
        release(engine, top, on: a)
        release(engine, top, on: b)
        XCTAssertEqual(performer.log.count, 2, "both gestures fired a direction, so neither release is a tap")
    }

    func testGestureMovementOnOneSourceLeavesOtherATap() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)

        press(engine, top, on: a)
        press(engine, top, on: b)
        engine.handlePointerDelta(PointerDelta(source: b, dx: 0, dy: -50))
        release(engine, top, on: a)
        release(engine, top, on: b)

        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl), copyCombo, copyCombo])
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up])
    }

    func testCursorDeltasOnlyReachCursorGestures() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)
        engine.gestureSourceFor = { [b] source, _ in source == b ? .cursor : .rawSensor }

        press(engine, top, on: a)
        press(engine, top, on: b)
        XCTAssertTrue(engine.needsCursorDeltas)

        engine.handlePointerDelta(PointerDelta(source: b, dx: 0, dy: -500))
        XCTAssertTrue(performer.log.isEmpty, "raw deltas don't feed B's cursor-tracked gesture")

        engine.handleCursorDelta(dx: -Int(GestureRecognizer.cursorThreshold), dy: 0)
        let spaceLeft = ActionEffect.keyCombo(KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control))
        XCTAssertEqual(performer.log.map(\.0), [spaceLeft, spaceLeft], "cursor movement reaches only B's gesture, not A's raw one")

        release(engine, top, on: b)
        XCTAssertFalse(engine.needsCursorDeltas)
        engine.handlePointerDelta(PointerDelta(source: a, dx: 0, dy: 50))
        release(engine, top, on: a)
        XCTAssertEqual(performer.log.last?.0, .missionControl(.appExpose))
    }

    func testGestureSourceForTakesPrecedenceOverCompatGestureSource() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)
        engine.gestureSource = { _ in .cursor }
        engine.gestureSourceFor = { _, _ in .rawSensor }

        press(engine, top, on: a)
        XCTAssertFalse(engine.needsCursorDeltas)
        engine.handlePointerDelta(PointerDelta(source: a, dx: 0, dy: -50))
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testPerSourceThresholdCapturedAtPress() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)
        let thresholds = Box<[DeviceAddress: Double]>([a: 40, b: 400])
        engine.rawThresholdProvider = { thresholds.value[$0] ?? 1 }

        press(engine, top, on: a)
        press(engine, top, on: b)
        // A DPI change mid-hold doesn't move the goalposts of gestures already in progress.
        thresholds.value = [a: 1000, b: 10]

        engine.handlePointerDelta(PointerDelta(source: b, dx: 0, dy: -100))
        XCTAssertTrue(performer.log.isEmpty, "B's gesture keeps the 400-count distance from its press")
        engine.handlePointerDelta(PointerDelta(source: a, dx: 0, dy: -100))
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)], "A's gesture keeps 40")

        release(engine, top, on: a)
        release(engine, top, on: b)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl), copyCombo, copyCombo])

        // The next press reads the new distances.
        performer.log.removeAll()
        press(engine, top, on: b)
        engine.handlePointerDelta(PointerDelta(source: b, dx: 0, dy: -10))
        release(engine, top, on: b)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)])
    }

    func testCompatRawDeltaWithoutSourceReachesEveryRawGesture() async {
        let performer = RecordingPerformer()
        let engine = gestureEngine(performer)
        engine.gestureSourceFor = { [b] source, _ in source == b ? .cursor : .rawSensor }

        press(engine, top, on: a)
        press(engine, top, on: b)
        engine.handlePointerDelta(dx: 0, dy: -50)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl)], "unattributed raw movement skips cursor gestures")
        engine.handlePointerDelta(dx: 0, dy: 50, source: .cursor)
        XCTAssertEqual(performer.log.map(\.0), [.missionControl(.missionControl), .missionControl(.appExpose)])
    }

    // MARK: Device actions and mappings

    func testDeviceActionCarriesSource() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([
            back: .device(.cycleDPI),
            top: .gestures(gestureSet),
        ]), performer: performer)
        engine.rawGestureThreshold = 40
        var actions: [DeviceAction] = []
        var sources: [DeviceAddress] = []
        var compat: [DeviceAction] = []
        engine.onSourcedDeviceAction = { action, source in
            actions.append(action)
            sources.append(source)
        }

        press(engine, back, on: b)
        release(engine, back, on: b)
        press(engine, top, on: a)
        engine.handlePointerDelta(PointerDelta(source: a, dx: 60, dy: 0))
        release(engine, top, on: a)
        XCTAssertEqual(actions, [.cycleDPI, .cycleDPI])
        XCTAssertEqual(sources, [b, a], "a press and a gesture slot each name their mouse")
        XCTAssertTrue(performer.log.isEmpty)

        // The single-mouse callback still fires when set.
        engine.onDeviceAction = { compat.append($0) }
        press(engine, back, on: a)
        XCTAssertEqual(compat, [.cycleDPI])
        XCTAssertEqual(sources, [b, a, a])
    }

    func testPerSourceMappingsProvider() async {
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: ButtonMappings([back: .system(.paste)]), performer: performer)
        let asked = Box<[DeviceAddress]>([])
        engine.mappingsProvider = { [a] source in
            asked.value.append(source)
            return source == a ? .legacyDefaults : ButtonMappings([KnownControl.back: .system(.copy)])
        }

        press(engine, back, on: a)
        release(engine, back, on: a)
        press(engine, back, on: b)
        release(engine, back, on: b)
        XCTAssertEqual(asked.value, [a, b], "asked once per press, for the pressing mouse")
        XCTAssertEqual(performer.log.map(\.0), [backCombo, backCombo, copyCombo, copyCombo], "`mappings` is unused while a provider is set")

        // A provider change mid-hold doesn't affect the release (per mouse).
        performer.log.removeAll()
        press(engine, back, on: a)
        engine.mappingsProvider = { _ in ButtonMappings([KnownControl.back: .system(.copy)]) }
        release(engine, back, on: a)
        XCTAssertEqual(performer.log.map(\.0), [backCombo, backCombo])

        // Unmapped on one mouse stays native there while mapped on the other.
        performer.log.removeAll()
        engine.mappingsProvider = { [a] source in source == a ? .defaults : .legacyDefaults }
        press(engine, back, on: a)
        release(engine, back, on: a)
        XCTAssertTrue(performer.log.isEmpty)
        XCTAssertEqual(engine.pressedControls(for: a), [])

        // Removing the provider falls back to `mappings`.
        engine.mappingsProvider = nil
        press(engine, back, on: b)
        XCTAssertEqual(performer.log.first?.0, .keyCombo(KeyCombo(keyCode: KeyCode.v, modifiers: .command)))
    }

    func testCompatPressedControlsIsUnion() async {
        let engine = RemapEngine(mappings: ButtonMappings([top: .gestures(gestureSet)]), performer: RecordingPerformer())

        press(engine, back, on: a)
        press(engine, top, on: b)
        press(engine, back, on: b)
        XCTAssertEqual(engine.pressedControls, [back, top])
        XCTAssertEqual(engine.gestureControls, [top])
        XCTAssertEqual(engine.pressedControls(for: a), [back])
        XCTAssertEqual(engine.pressedControls(for: b), [back, top])
        XCTAssertEqual(engine.gestureControls(for: a), [])
        XCTAssertEqual(engine.gestureControls(for: b), [top])

        release(engine, back, on: b)
        XCTAssertEqual(engine.pressedControls, [back, top], "A still holds Back")
        release(engine, back, on: a)
        XCTAssertEqual(engine.pressedControls, [top])
        engine.releaseAll()
        XCTAssertEqual(engine.pressedControls, [])
        XCTAssertEqual(engine.gestureControls, [])
    }

    func testControlKeyOrdersBySourceThenCID() async {
        let keys = [
            ControlKey(source: b, cid: 0x53),
            ControlKey(source: a, cid: 0x56),
            ControlKey(source: b, cid: 0x52),
            ControlKey(source: a, cid: 0x53),
        ]
        XCTAssertEqual(keys.sorted().map(\.cid), [0x53, 0x56, 0x52, 0x53])
        XCTAssertEqual(keys.sorted().map(\.source), [a, a, b, b])
    }
}
