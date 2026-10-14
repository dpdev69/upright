import Foundation
import XCTest
@testable import UprightKit

/// Several mice on several interfaces, end to end (§G-2): simulated devices, real `HIDPPLink`s,
/// the registry, the planner, the mapping library and the engine, wired as the app wires them
/// (`FleetHarness`). Nothing done on one mouse may leak to another.
@MainActor
final class EndToEndRoutingTests: XCTestCase {
    private static let editor = EndToEndRoutingTestsFixtures.editor
    private static let other = EndToEndRoutingTestsFixtures.other
    private static let master3S = ModelKey(productID: 0xB034)
    private static let master3 = ModelKey(productID: 0xB023)
    private static let lift = ModelKey(productID: 0xB031)

    /// One key code per mapping, so the performer's log says which mapping fired.
    private enum Key {
        static let verticalBack: UInt16 = 0x00
        static let verticalTap: UInt16 = 0x01
        static let verticalUp: UInt16 = 0x02
        static let verticalDown: UInt16 = 0x03
        static let verticalLeft: UInt16 = 0x04
        static let verticalRight: UInt16 = 0x05
        static let masterBack: UInt16 = 0x10
        static let masterEditorBack: UInt16 = 0x11
        static let masterTap: UInt16 = 0x12
        static let masterUp: UInt16 = 0x13
        static let masterDown: UInt16 = 0x14
        static let masterLeft: UInt16 = 0x15
        static let masterRight: UInt16 = 0x16
        static let master3Back: UInt16 = 0x20
        static let liftBack: UInt16 = 0x30
    }

    private static func combo(_ code: UInt16) -> KeyCombo {
        KeyCombo(keyCode: code, modifiers: .command)
    }

    private static func action(_ code: UInt16) -> ButtonAction {
        .keyCombo(combo(code))
    }

    private static func effect(_ code: UInt16) -> ActionEffect {
        .keyCombo(combo(code))
    }

    /// Every model's setup for these tests. The same CID does something different on each model,
    /// and the editor app changes some of it.
    private static func library() -> MappingLibrary {
        var library = MappingLibrary()
        library[.mxVertical] = MappingProfiles(
            global: ButtonMappings([
                KnownControl.back: action(Key.verticalBack),
                KnownControl.dpiSwitch: .gestures(GestureSet(
                    tap: action(Key.verticalTap), up: action(Key.verticalUp), down: action(Key.verticalDown),
                    left: action(Key.verticalLeft), right: action(Key.verticalRight)
                )),
                KnownControl.middleClick: .device(.cycleDPI),
            ]),
            apps: [AppProfile(bundleID: editor, displayName: "Editor", overrides: [KnownControl.back: .deviceDefault])]
        )
        library[master3S] = MappingProfiles(
            global: ButtonMappings([
                KnownControl.back: action(Key.masterBack),
                KnownControl.gestureButton: .gestures(GestureSet(
                    tap: action(Key.masterTap), up: action(Key.masterUp), down: action(Key.masterDown),
                    left: action(Key.masterLeft), right: action(Key.masterRight)
                )),
                KnownControl.smartShift: .device(.cycleDPI),
            ]),
            apps: [AppProfile(bundleID: editor, displayName: "Editor", overrides: [
                KnownControl.back: action(Key.masterEditorBack),
                KnownControl.gestureButton: .deviceDefault,
            ])]
        )
        library[master3] = MappingProfiles(global: ButtonMappings([
            KnownControl.back: action(Key.master3Back),
            KnownControl.forward: .system(.volumeUp),
        ]))
        library[lift] = MappingProfiles(
            global: ButtonMappings([
                KnownControl.back: action(Key.liftBack),
                KnownControl.forward: .disabled,
                KnownControl.middleClick: .system(.middleClick),
            ]),
            apps: [AppProfile(bundleID: other, displayName: "Other", overrides: [KnownControl.back: .deviceDefault])]
        )
        return library
    }

    /// `library()` with more controls mapped (every kind of effect, gestures that fire device
    /// actions and effects without a held state), so random presses reach the engine more often.
    private static func fuzzLibrary() -> MappingLibrary {
        var library = library()
        library[.mxVertical].global[KnownControl.forward] = .system(.mouseForward)
        library[master3S].global[KnownControl.middleClick] = action(0x40)
        library[master3S].global[KnownControl.forward] = .system(.volumeDown)
        library[master3].global[KnownControl.middleClick] = .gestures(GestureSet(
            tap: action(0x41), up: action(0x42), down: .system(.mute), left: .device(.cycleDPI), right: .system(.missionControl)
        ))
        library[master3].global[KnownControl.gestureButton] = action(0x43)
        library[master3].global[KnownControl.smartShift] = .device(.setDPI(1600))
        library[lift].global[KnownControl.dpiSwitch] = .gestures(GestureSet(tap: action(0x44), up: action(0x45), left: action(0x46)))
        return library
    }

    private func makeFleet(library: MappingLibrary? = nil, tuning: ControllerTuning = .fastTests) -> FleetHarness {
        let fleet = FleetHarness(library: library ?? Self.library(), tuning: tuning)
        fleet.dpiPresets = [800, 1600, 2400]
        return fleet
    }

    private static let direct = DeviceAddress.direct

    // MARK: Routing

    func testTwoHubsUSBVerticalAndReceiverMasterNoCrossTalk() async throws {
        let fleet = makeFleet()
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let bolt = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let a = fleet.attach(vertical).address(of: Self.direct)
        let b = fleet.attach(bolt).address(of: 1)
        await eventually("both connected") { fleet.isConnected(a) && fleet.isConnected(b) }
        await fleet.waitUntilIdle()

        // Two links, two active records, each mouse diverted for its own model only.
        XCTAssertNotEqual(a.link, b.link)
        XCTAssertEqual(fleet.registry.records.map(\.address), [a, b])
        XCTAssertEqual(fleet.registry.records.map(\.model), [.mxVertical, Self.master3S])
        XCTAssertEqual(fleet.registry.records.map(\.role), [.active, .active])
        XCTAssertEqual(vertical.diverted, [KnownControl.back, KnownControl.dpiSwitch, KnownControl.middleClick])
        XCTAssertEqual(vertical.rawXY, [KnownControl.dpiSwitch])
        XCTAssertEqual(bolt.diverted(slot: 1), [KnownControl.back, KnownControl.gestureButton, KnownControl.smartShift])
        XCTAssertEqual(bolt.rawXY(slot: 1), [KnownControl.gestureButton])
        XCTAssertEqual(vertical.requestCount(feature: 0x1B04, function: 3),
                       DeviceProfiles.mxVertical.controls.filter(\.isConfigurable).count,
                       "the vertical was only told about its own controls")

        // The same CID does what each mouse's model says.
        bolt.hold([KnownControl.back], slot: 1)
        bolt.release(slot: 1)
        await eventually("B's back") { fleet.performer.count(Self.effect(Key.masterBack), .up) == 1 }
        XCTAssertEqual(fleet.performer.count(Self.effect(Key.verticalBack), .down), 0)
        XCTAssertEqual(fleet.focusedDevice, b)

        // Both gesture buttons held: raw movement only decides the gesture of the mouse it came from.
        fleet.performer.removeAll()
        vertical.hold([KnownControl.dpiSwitch])
        bolt.hold([KnownControl.gestureButton], slot: 1)
        await eventually("both gestures held") {
            fleet.engine.gestureControls(for: a) == [KnownControl.dpiSwitch]
                && fleet.engine.gestureControls(for: b) == [KnownControl.gestureButton]
        }
        vertical.move(dx: 400, dy: 0)
        await eventually("A swiped right") { fleet.performer.count(Self.effect(Key.verticalRight), .up) == 1 }
        await fleet.settle()
        XCTAssertEqual(fleet.performer.log.count, 2, "nothing fired on B")
        // 0x1B04 v5: B's first raw report after the press is dropped (D16).
        bolt.move(dx: 0, dy: -400, slot: 1)
        bolt.move(dx: 0, dy: -400, slot: 1)
        await eventually("B swiped up") { fleet.performer.count(Self.effect(Key.masterUp), .up) == 1 }
        vertical.release()
        bolt.release(slot: 1)
        await eventually("both released") { fleet.engine.pressedKeys.isEmpty }
        await fleet.settle()

        XCTAssertEqual(fleet.performer.log.map(\.effect), [
            Self.effect(Key.verticalRight), Self.effect(Key.verticalRight),
            Self.effect(Key.masterUp), Self.effect(Key.masterUp),
        ], "one direction each, no taps")
        for event in fleet.events {
            switch event.cid {
            case KnownControl.dpiSwitch: XCTAssertEqual(event.source, a)
            case KnownControl.gestureButton, KnownControl.back: XCTAssertEqual(event.source, b)
            default: XCTFail("unexpected event \(event)")
            }
        }
        XCTAssertTrue(fleet.droppedPresses.isEmpty)
        XCTAssertTrue(fleet.performer.stuck.isEmpty)
    }

    func testBothHoldBackIndependentKeyEffects() async {
        let fleet = makeFleet()
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let unifying = SimulatedReceiver.unifying([1: DeviceProfiles.mxVerticalSecondUnit, 2: DeviceProfiles.mxMaster3])
        let a = fleet.attach(vertical).address(of: Self.direct)
        let receiver = fleet.attach(unifying)
        let a2 = receiver.address(of: 1)
        let c = receiver.address(of: 2)
        await eventually("all connected") { fleet.isConnected(a) && fleet.isConnected(a2) && fleet.isConnected(c) }
        await fleet.waitUntilIdle()
        let verticalBack = Self.effect(Key.verticalBack)
        let master3Back = Self.effect(Key.master3Back)

        // Three mice hold Back at once; two of them are the same model with the same effect.
        vertical.hold([KnownControl.back])
        unifying.hold([KnownControl.back], slot: 1)
        unifying.hold([KnownControl.back], slot: 2)
        await eventually("three holds") { fleet.engine.held.count == 3 }
        XCTAssertEqual(Set(fleet.engine.held.keys), [
            ControlKey(source: a, cid: KnownControl.back),
            ControlKey(source: a2, cid: KnownControl.back),
            ControlKey(source: c, cid: KnownControl.back),
        ])
        XCTAssertEqual(fleet.performer.outstanding, [verticalBack: 2, master3Back: 1])

        // Releasing the second vertical ends only its own hold.
        unifying.release(slot: 1)
        await eventually("A2 released") { fleet.engine.held.count == 2 }
        XCTAssertEqual(Set(fleet.engine.held.keys), [
            ControlKey(source: a, cid: KnownControl.back), ControlKey(source: c, cid: KnownControl.back),
        ])
        XCTAssertEqual(fleet.performer.outstanding, [verticalBack: 1, master3Back: 1])

        unifying.release(slot: 2)
        await eventually("C released") { fleet.engine.held.count == 1 }
        XCTAssertEqual(fleet.performer.outstanding, [verticalBack: 1])
        XCTAssertEqual(fleet.engine.pressedControls(for: a), [KnownControl.back])

        vertical.release()
        await eventually("A released") { fleet.engine.held.isEmpty }
        await fleet.settle()
        XCTAssertEqual(fleet.performer.log.map(\.phase), [.down, .down, .down, .up, .up, .up])
        XCTAssertEqual(fleet.performer.count(verticalBack, .down), 2)
        XCTAssertEqual(fleet.performer.count(verticalBack, .up), 2)
        XCTAssertTrue(fleet.performer.stuck.isEmpty)
        XCTAssertTrue(fleet.performer.violations.isEmpty, "\(fleet.performer.violations)")
    }

    func testDetachingADoesNotReleaseB() async {
        let fleet = makeFleet()
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let bolt = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let linkA = fleet.attach(vertical).link
        let b = fleet.attach(bolt).address(of: 1)
        let a = fleet.address(link: linkA, index: Self.direct)
        await eventually("both connected") { fleet.isConnected(a) && fleet.isConnected(b) }
        await fleet.waitUntilIdle()

        vertical.hold([KnownControl.back])
        bolt.hold([KnownControl.back, KnownControl.gestureButton], slot: 1)
        await eventually("all held") { fleet.engine.held.count == 2 && fleet.engine.gestureControls(for: b) == [KnownControl.gestureButton] }
        let boltWrites = bolt.setReportingCount(slot: 1)
        let boltDiverted = bolt.diverted(slot: 1)

        // A's cable is pulled mid-hold.
        await fleet.detach(linkA)
        await fleet.settle()
        XCTAssertEqual(fleet.removals.map { $0.address }, [a])
        XCTAssertEqual(fleet.removals.map { $0.reason }, [.transportClosed])
        XCTAssertEqual(fleet.performer.count(Self.effect(Key.verticalBack), .up), 1, "A's effect ended")
        XCTAssertEqual(Set(fleet.engine.held.keys), [ControlKey(source: b, cid: KnownControl.back)], "B's hold is untouched")
        XCTAssertEqual(fleet.engine.gestureControls(for: b), [KnownControl.gestureButton])
        XCTAssertEqual(fleet.performer.count(Self.effect(Key.masterBack), .up), 0)
        XCTAssertEqual(fleet.registry.records.map(\.address), [b])
        XCTAssertTrue(fleet.isConnected(b))
        XCTAssertEqual(bolt.setReportingCount(slot: 1), boltWrites, "B wasn't reconfigured")
        XCTAssertEqual(bolt.diverted(slot: 1), boltDiverted)

        // B still ends its own hold and gesture normally.
        bolt.move(dx: -400, dy: 0, slot: 1) // dropped: first raw report after the press (D16)
        bolt.move(dx: -400, dy: 0, slot: 1)
        bolt.release(slot: 1)
        await eventually("B released") { fleet.engine.pressedKeys.isEmpty }
        await fleet.settle()
        XCTAssertEqual(fleet.performer.count(Self.effect(Key.masterBack), .up), 1)
        XCTAssertEqual(fleet.performer.count(Self.effect(Key.masterLeft), .up), 1)
        XCTAssertTrue(fleet.performer.stuck.isEmpty)

        // Plugged back in: a new address, but the unit keeps its place in the list.
        let replugged = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let a2 = fleet.attach(replugged).address(of: Self.direct)
        await eventually("A back") { fleet.isConnected(a2) }
        await fleet.waitUntilIdle()
        XCTAssertNotEqual(a2, a)
        XCTAssertEqual(fleet.registry.records.map(\.address), [a2, b])
        XCTAssertEqual(replugged.diverted, [KnownControl.back, KnownControl.dpiSwitch, KnownControl.middleClick])
    }

    // MARK: Pointer speed

    func testCycleDPIOnBChangesOnlyB() async throws {
        let fleet = makeFleet()
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let bolt = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let a = fleet.attach(vertical).address(of: Self.direct)
        let b = fleet.attach(bolt).address(of: 1)
        await eventually("both connected") { fleet.isConnected(a) && fleet.isConnected(b) }
        await fleet.waitUntilIdle()
        XCTAssertEqual(vertical.dpi, 1000)
        XCTAssertEqual(bolt.dpi(slot: 1), 1000)
        let idA = try XCTUnwrap(fleet.deviceID(of: a))
        let idB = try XCTUnwrap(fleet.deviceID(of: b))

        // B's SmartShift button cycles B's speed; A has a Cycle mapping too, and isn't touched.
        bolt.hold([KnownControl.smartShift], slot: 1)
        bolt.release(slot: 1)
        await eventually("B at 1600") { bolt.dpi(slot: 1) == 1600 }
        bolt.hold([KnownControl.smartShift], slot: 1)
        bolt.release(slot: 1)
        await eventually("B at 2400") { bolt.dpi(slot: 1) == 2400 }
        await fleet.waitUntilIdle()
        await fleet.settle()

        XCTAssertEqual(vertical.dpi, 1000)
        XCTAssertEqual(vertical.requestCount(feature: 0x2201, function: 3), 0, "no speed was written to A")
        XCTAssertNil(fleet.endpoint(a)?.desiredDPI)
        XCTAssertEqual(fleet.deviceActions.map { $0.source }, [b, b])
        XCTAssertEqual(fleet.deviceDPIChanges.map { $0.address }, [b, b])
        XCTAssertEqual(fleet.deviceDPIChanges.map { $0.dpi }, [1600, 2400])
        XCTAssertEqual(fleet.preferences.devices[idB]?.preferredDPI, 2400, "kept for B's unit")
        XCTAssertNil(fleet.preferences.devices[idA])
        XCTAssertNil(fleet.preferences.models[Self.master3S], "not for the whole model")

        // And A's own button cycles only A.
        vertical.hold([KnownControl.middleClick])
        vertical.release()
        await eventually("A at 1600") { vertical.dpi == 1600 }
        await fleet.waitUntilIdle()
        XCTAssertEqual(bolt.dpi(slot: 1), 2400)
        XCTAssertEqual(fleet.deviceActions.map { $0.source }, [b, b, a])
        XCTAssertEqual(fleet.preferences.devices[idA]?.preferredDPI, 1600)
        XCTAssertEqual(fleet.preferences.devices[idB]?.preferredDPI, 2400)
    }

    func testNativeDPIChangeOnANotPropagated() async throws {
        let fleet = makeFleet()
        // The MX Vertical seed is what Upright 2.x's single preferred speed migrates into.
        fleet.preferences.models[.mxVertical] = DevicePreferences(preferredDPI: 1600)
        fleet.preferences.models[Self.master3] = DevicePreferences(preferredDPI: 1200)
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let unifying = SimulatedReceiver.unifying([1: DeviceProfiles.mxVerticalSecondUnit, 2: DeviceProfiles.mxMaster3])
        let a = fleet.attach(vertical).address(of: Self.direct)
        let receiver = fleet.attach(unifying)
        let a2 = receiver.address(of: 1)
        let c = receiver.address(of: 2)
        await eventually("all connected") { fleet.isConnected(a) && fleet.isConnected(a2) && fleet.isConnected(c) }
        await eventually("seed speeds applied") {
            vertical.dpi == 1600 && unifying.dpi(slot: 1) == 1600 && unifying.dpi(slot: 2) == 1200
        }
        await fleet.waitUntilIdle()
        XCTAssertTrue(fleet.deviceDPIChanges.isEmpty)
        let idA = try XCTUnwrap(fleet.deviceID(of: a))
        let idA2 = try XCTUnwrap(fleet.deviceID(of: a2))
        let writesA2 = unifying.requestCount(feature: 0x2201, function: 3, slot: 1)
        let writesC = unifying.requestCount(feature: 0x2201, function: 3, slot: 2)

        // The DPI button on A changes A's speed natively; the app notices on its next look.
        vertical.setDPINatively(2400)
        fleet.refreshDeviceInfo()
        await eventually("A's change adopted") { fleet.deviceDPIChanges.count == 1 }
        await fleet.waitUntilIdle()
        await fleet.settle()

        XCTAssertEqual(fleet.deviceDPIChanges.map { $0.address }, [a])
        XCTAssertEqual(fleet.deviceDPIChanges.map { $0.dpi }, [2400])
        XCTAssertEqual(vertical.dpi, 2400)
        XCTAssertEqual(unifying.dpi(slot: 1), 1600, "the other MX Vertical keeps its speed")
        XCTAssertEqual(unifying.dpi(slot: 2), 1200)
        XCTAssertEqual(unifying.requestCount(feature: 0x2201, function: 3, slot: 1), writesA2)
        XCTAssertEqual(unifying.requestCount(feature: 0x2201, function: 3, slot: 2), writesC)
        XCTAssertEqual(fleet.preferences.devices[idA]?.preferredDPI, 2400)
        XCTAssertNil(fleet.preferences.devices[idA2])
        XCTAssertEqual(fleet.preferences.models[.mxVertical]?.preferredDPI, 1600, "the model seed is untouched")
        XCTAssertEqual(fleet.preferences.preferences(for: idA2, model: .mxVertical).preferredDPI, 1600)

        // A resync for an unrelated reason doesn't put any mouse back to an old speed.
        let writesA = vertical.requestCount(feature: 0x2201, function: 3)
        fleet.frontmostBundleID = Self.editor
        await fleet.waitUntilIdle()
        await fleet.settle()
        XCTAssertEqual(vertical.dpi, 2400)
        XCTAssertEqual(vertical.requestCount(feature: 0x2201, function: 3), writesA)
        XCTAssertEqual(unifying.requestCount(feature: 0x2201, function: 3, slot: 1), writesA2)
        XCTAssertEqual(unifying.requestCount(feature: 0x2201, function: 3, slot: 2), writesC)
    }

    // MARK: Profiles

    func testAppSwitchMidHoldOnAKeepsADivertedAndBFollowsNewApp() async {
        let fleet = makeFleet()
        let vertical = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .usb)
        let bolt = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let a = fleet.attach(vertical).address(of: Self.direct)
        let b = fleet.attach(bolt).address(of: 1)
        await eventually("both connected") { fleet.isConnected(a) && fleet.isConnected(b) }
        await fleet.waitUntilIdle()
        XCTAssertTrue(vertical.diverted.contains(KnownControl.back))
        XCTAssertEqual(bolt.diverted(slot: 1), [KnownControl.back, KnownControl.gestureButton, KnownControl.smartShift])

        vertical.hold([KnownControl.back])
        await eventually("A pressed") { fleet.performer.count(Self.effect(Key.verticalBack), .down) == 1 }

        // The editor leaves Back native on the MX Vertical and gives the Master's Back another
        // shortcut and its gesture button back to the mouse.
        fleet.frontmostBundleID = Self.editor
        await eventually("B follows the editor") {
            bolt.diverted(slot: 1) == [KnownControl.back, KnownControl.smartShift] && bolt.rawXY(slot: 1).isEmpty
        }
        await fleet.waitUntilIdle()
        await fleet.settle()
        XCTAssertTrue(vertical.diverted.contains(KnownControl.back), "A keeps Back diverted while it is held")
        XCTAssertEqual(fleet.appliedConfig[a]?.divert, [KnownControl.back, KnownControl.dpiSwitch, KnownControl.middleClick])

        // B uses the editor's mapping right away.
        bolt.hold([KnownControl.back], slot: 1)
        bolt.release(slot: 1)
        await eventually("B's editor back") { fleet.performer.count(Self.effect(Key.masterEditorBack), .up) == 1 }

        // A's release ends the effect its press started, then Back goes back to the mouse.
        vertical.release()
        await eventually("A's back handed back") { !vertical.diverted.contains(KnownControl.back) }
        await fleet.waitUntilIdle()
        await fleet.settle()
        XCTAssertEqual(fleet.performer.log, [
            .init(effect: Self.effect(Key.verticalBack), phase: .down),
            .init(effect: Self.effect(Key.masterEditorBack), phase: .down),
            .init(effect: Self.effect(Key.masterEditorBack), phase: .up),
            .init(effect: Self.effect(Key.verticalBack), phase: .up),
        ])
        XCTAssertEqual(vertical.diverted, [KnownControl.dpiSwitch, KnownControl.middleClick])

        // Pressing Back on A now is native: nothing reaches the engine.
        vertical.hold([KnownControl.back])
        vertical.release()
        await fleet.settle()
        XCTAssertEqual(fleet.performer.log.count, 4)

        // Leaving the editor diverts both Backs again.
        fleet.frontmostBundleID = nil
        await eventually("global again") {
            vertical.diverted.contains(KnownControl.back) && bolt.diverted(slot: 1).contains(KnownControl.gestureButton)
        }
        XCTAssertTrue(fleet.performer.stuck.isEmpty)
    }

    // MARK: Fuzz

    /// 1000 seeded random steps over a fleet of three interfaces plus a Bluetooth twin of one of
    /// the mice: presses, releases and movement, sleep and wake, unpair, pair and re-pair,
    /// unplugging and re-plugging, app switches, speed changes on the mice, and the "Remap this
    /// mouse" switch. After every settled step no held effect may belong to an endpoint that is
    /// gone; at the end, with every button let go, nothing may be held and every down must have
    /// had its up. Every connected, awake mouse must also be configured as the planner says.
    ///
    /// The step plan depends only on the seed: every choice is made from the simulated hardware's
    /// state, never from what the app has observed, so a failure replays with its seed (thread
    /// timing can still shift details). `UPRIGHT_FUZZ_SEED` and `UPRIGHT_FUZZ_STEPS` replay or
    /// extend a run; `UPRIGHT_FUZZ_TRACE` prints every step.
    func testSeededLinkLossFuzzNeverLeavesStuckEffects() async {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["UPRIGHT_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x05EE_D0FF_1EE7
        let steps = environment["UPRIGHT_FUZZ_STEPS"].flatMap { Int($0) } ?? 1000

        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.05
        tuning.retryBaseDelay = 0.02
        tuning.retryMaxDelay = 0.1
        tuning.announcementWait = 0.02
        tuning.batteryRefreshInterval = 0
        let fleet = makeFleet(library: Self.fuzzLibrary(), tuning: tuning)
        var fuzz = FleetFuzzer(fleet: fleet, seed: seed)
        let began = Date()

        fuzz.plugEverything()
        // Every mouse (the keyboard isn't one) on its own link, the Bluetooth twin included.
        await eventually("the fleet connected", timeout: 5) { fleet.registry.records.filter(\.isConnected).count == 7 }
        await fleet.waitUntilIdle()
        fuzz.rememberUnits()

        for step in 0..<steps {
            let settles = fuzz.step()
            guard settles else { continue }
            await fleet.settle()
            fleet.forgetClosedLinks()
            if let problem = fuzz.problemAfterSettling() {
                XCTFail("seed \(seed), step \(step): \(problem)\n\(fuzz.recentHistory)")
                return
            }
        }

        // Everyone lets go, and the fleet comes to rest.
        fuzz.releaseEverything()
        for _ in 0..<2 {
            await fleet.settle(quietPolls: 5)
            await fleet.waitUntilIdle()
        }
        fleet.forgetClosedLinks()
        let context = "seed \(seed) after \(steps) steps\n\(fuzz.recentHistory)"

        XCTAssertTrue(fleet.performer.violations.isEmpty, "\(fleet.performer.violations) — \(context)")
        XCTAssertTrue(fleet.performer.stuck.isEmpty, "effects left down: \(fleet.performer.stuck) — \(context)")
        XCTAssertTrue(fleet.engine.held.isEmpty, "held: \(fleet.engine.held) — \(context)")
        XCTAssertTrue(fleet.engine.gestures.isEmpty, "gestures: \(Array(fleet.engine.gestures.keys)) — \(context)")
        XCTAssertTrue(fleet.engine.pressedKeys.isEmpty, "pressed: \(fleet.engine.pressedKeys) — \(context)")
        for problem in fuzz.configurationProblems() {
            XCTFail("\(problem) — \(context)")
        }
        XCTAssertGreaterThan(fleet.performer.log.count, steps / 20, "the run exercised the engine")
        XCTAssertGreaterThan(fleet.removals.count, 0, "the run removed endpoints")

        // Quitting hands every connected, awake mouse its buttons back.
        let served = fuzz.connectedAwakeDevices()
        fleet.shutdown()
        for device in served where !device.simulator.diverted(slot: device.slot).isEmpty {
            XCTFail("\(device.name) still diverted after shutdown: \(device.simulator.diverted(slot: device.slot)) — \(context)")
        }

        if environment["UPRIGHT_FUZZ_TRACE"] != nil { print(fuzz.fullHistory) }
        let elapsed = Date().timeIntervalSince(began)
        print("Fuzz: seed \(seed), \(steps) steps, \(fleet.events.count) button events (\(fleet.droppedPresses.count) presses dropped), \(fleet.performer.log.count) effects, \(fleet.deviceActions.count) device actions, \(fleet.removals.count) removals, \(String(format: "%.1f", elapsed)) s")
    }
}

// MARK: - Fuzzer

/// SplitMix64: a small seeded generator with a fixed algorithm on every platform and toolchain.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<bound.
    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[below(items.count)]
    }

    mutating func range(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + below(range.count)
    }
}

/// One interface of the fuzzed fleet, across unplugging and plugging back in. Holds the
/// physical truth: which devices are paired where and which buttons a hand is holding.
@MainActor
private final class FuzzPort {
    enum Kind {
        case direct(ConnectionKind)
        case receiver(PairingLayout)
    }

    let name: String
    let kind: Kind
    /// Slot → device (0xFF on a direct link). Survives unplugging, like a receiver's pairings.
    var pairings: [UInt8: SimulatedDeviceProfile]
    var simulator: SimulatedHIDPPTransport?
    var link: UInt32?
    /// Buttons a hand holds right now, per slot, in press order.
    var held: [UInt8: [UInt16]] = [:]

    init(name: String, kind: Kind, pairings: [UInt8: SimulatedDeviceProfile]) {
        self.name = name
        self.kind = kind
        self.pairings = pairings
    }

    var isDirect: Bool {
        if case .direct = kind { return true }
        return false
    }

    var receiver: SimulatedReceiver? { simulator as? SimulatedReceiver }

    var occupiedSlots: [UInt8] { pairings.keys.sorted() }

    var freeSlots: [UInt8] {
        isDirect ? [] : ReceiverDirectory.slots.filter { pairings[$0] == nil }
    }

    /// A fresh interface with the current pairings (devices come back awake, nothing diverted).
    func makeSimulator() -> SimulatedHIDPPTransport {
        switch kind {
        case .direct(let connection):
            return SimulatedDirect(profile: pairings[DeviceAddress.direct]!, connection: connection)
        case .receiver(.bolt):
            return SimulatedReceiver.bolt(pairings)
        case .receiver(.unifying):
            return SimulatedReceiver.unifying(pairings)
        }
    }
}

/// Drives a `FleetHarness` with seeded random steps and checks its invariants.
@MainActor
private struct FleetFuzzer {
    struct Device {
        var name: String
        var simulator: SimulatedHIDPPTransport
        var slot: UInt8
        var address: DeviceAddress
    }

    let fleet: FleetHarness
    let seed: UInt64
    private var rng: SplitMix64
    private let ports: [FuzzPort]
    /// Devices un-paired from a receiver, waiting to be paired back to it.
    private var unpaired: [(port: Int, profile: SimulatedDeviceProfile)] = []
    /// Every unit with a stable ID, fixed at the start, so choosing one never depends on what
    /// happens to be connected (thread timing) and the plan only depends on the seed.
    private var units: [(id: DeviceID, model: ModelKey)] = []
    private var history: [String] = []
    private var stepNumber = 0

    init(fleet: FleetHarness, seed: UInt64) {
        self.fleet = fleet
        self.seed = seed
        rng = SplitMix64(seed: seed)
        ports = [
            FuzzPort(name: "USB", kind: .direct(.usb), pairings: [DeviceAddress.direct: DeviceProfiles.mxVertical]),
            FuzzPort(name: "Bolt", kind: .receiver(.bolt), pairings: [1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift]),
            FuzzPort(name: "Unifying", kind: .receiver(.unifying), pairings: [
                1: DeviceProfiles.mxVerticalSecondUnit, 3: DeviceProfiles.mxMaster3,
                4: DeviceProfiles.mxKeys, 5: DeviceProfiles.mouseWithoutUnitID,
            ]),
            // The Bolt slot 1 mouse again, over Bluetooth: same unit, so one of the two is standby.
            FuzzPort(name: "BT", kind: .direct(.bluetooth), pairings: [DeviceAddress.direct: DeviceProfiles.mxMaster3S]),
        ]
    }

    var fullHistory: String {
        history.joined(separator: "\n")
    }

    var recentHistory: String {
        "last steps:\n" + history.suffix(30).joined(separator: "\n")
    }

    mutating func plugEverything() {
        for index in ports.indices { plug(index) }
    }

    mutating func rememberUnits() {
        var seen: Set<DeviceID> = []
        units = fleet.registry.records
            .compactMap { record -> (id: DeviceID, model: ModelKey)? in
                guard let id = record.deviceID, id.isStable, let model = record.model, seen.insert(id).inserted else { return nil }
                return (id, model)
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: Steps

    private enum Kind: CaseIterable {
        case press, release, move, sleep, wake, unpair, pair, repair, unplug, plug, switchApp, nativeDPI, refreshInfo, macWake, toggleRemap
    }

    /// Takes one random step. Returns whether to let the fleet settle before the next one (most
    /// steps; some follow each other immediately, so link loss lands mid-operation).
    mutating func step() -> Bool {
        stepNumber += 1
        let weights: [(Kind, Int)] = [
            (.press, 31), (.release, 22), (.move, 8), (.sleep, 5), (.wake, 7), (.unpair, 2), (.pair, 3), (.repair, 2),
            (.unplug, 2), (.plug, 4), (.switchApp, 5), (.nativeDPI, 3), (.refreshInfo, 2), (.macWake, 1), (.toggleRemap, 1),
        ]
        var possible = weights.filter { isPossible($0.0) }
        if possible.isEmpty { possible = [(.switchApp, 1)] }
        var roll = rng.below(possible.reduce(0) { $0 + $1.1 })
        var chosen = possible[0].0
        for (kind, weight) in possible {
            if roll < weight {
                chosen = kind
                break
            }
            roll -= weight
        }
        let description = perform(chosen)
        let settles = rng.chance(85)
        history.append("\(stepNumber): \(description)\(settles ? "" : " (no settle)")")
        return settles
    }

    private func isPossible(_ kind: Kind) -> Bool {
        switch kind {
        case .press, .sleep, .nativeDPI: return !awakeSlots().isEmpty
        case .release, .move: return !holdingSlots().isEmpty
        case .wake: return !asleepSlots().isEmpty
        case .unpair, .repair: return !receiverMice().isEmpty
        case .pair: return unpaired.contains { ports[$0.port].simulator != nil && !ports[$0.port].freeSlots.isEmpty }
        case .unplug: return ports.contains { $0.simulator != nil }
        case .plug: return ports.contains { $0.simulator == nil }
        case .toggleRemap: return !units.isEmpty
        case .switchApp, .refreshInfo, .macWake: return true
        }
    }

    private mutating func perform(_ kind: Kind) -> String {
        switch kind {
        case .press:
            let (port, slot) = rng.pick(awakeSlots())!
            let profile = ports[port].pairings[slot]!
            let candidates = profile.controls.filter(\.isConfigurable).map(\.cid)
                .filter { !(ports[port].held[slot] ?? []).contains($0) }
            guard let cid = rng.pick(candidates), (ports[port].held[slot] ?? []).count < 3 else {
                return "press on \(label(port, slot)): nothing more to press"
            }
            ports[port].held[slot, default: []].append(cid)
            let simulator = ports[port].simulator!
            simulator.hold(ports[port].held[slot]!, slot: slot)
            let reported = simulator.diverted(slot: slot).contains(cid) ? "diverted" : "native"
            return "press \(hex(cid)) on \(label(port, slot)) (\(reported); held \(describe(ports[port].held[slot]!)))"
        case .release:
            let (port, slot) = rng.pick(holdingSlots())!
            var held = ports[port].held[slot]!
            if rng.chance(20) {
                held.removeAll()
            } else {
                held.remove(at: rng.below(held.count))
            }
            ports[port].held[slot] = held.isEmpty ? nil : held
            ports[port].simulator!.hold(held, slot: slot)
            return "release on \(label(port, slot)) (held \(describe(held)))"
        case .move:
            let (port, slot) = rng.pick(holdingSlots())!
            let dx = rng.range(-300...300)
            let dy = rng.range(-300...300)
            ports[port].simulator!.move(dx: dx, dy: dy, slot: slot)
            return "move \(dx),\(dy) on \(label(port, slot))"
        case .sleep:
            let (port, slot) = rng.pick(awakeSlots())!
            let simulator = ports[port].simulator!
            if ports[port].isDirect, ports[port].held[slot] != nil {
                // A directly connected mouse only sleeps after the hand has let go; nothing tells
                // the Mac it went. (Losing the link mid-hold is unplugging.)
                simulator.hold([], slot: slot)
            }
            ports[port].held[slot] = nil
            simulator.goToSleep(slot: slot)
            return "sleep \(label(port, slot))"
        case .wake:
            let (port, slot) = rng.pick(asleepSlots())!
            let clearing = rng.chance(70)
            let simulator = ports[port].simulator!
            if ports[port].isDirect {
                // Mice report a reconnect when they lost their configuration.
                simulator.wakeUp(slot: slot, clearingDiversion: clearing, announce: false, reportReconnect: clearing || rng.chance(30))
            } else {
                simulator.wakeUp(slot: slot, clearingDiversion: clearing, announce: true, reportReconnect: rng.chance(30))
            }
            return "wake \(label(port, slot))\(clearing ? " (forgot its diversion)" : "")"
        case .unpair:
            let (port, slot) = rng.pick(receiverMice())!
            let profile = ports[port].pairings.removeValue(forKey: slot)!
            ports[port].held[slot] = nil
            unpaired.append((port, profile))
            ports[port].receiver!.unpair(slot: slot)
            return "unpair \(profile.codename) from \(label(port, slot))"
        case .pair:
            let candidates = unpaired.indices.filter { ports[unpaired[$0].port].simulator != nil && !ports[unpaired[$0].port].freeSlots.isEmpty }
            let index = rng.pick(candidates)!
            let (port, profile) = unpaired.remove(at: index)
            let slot = rng.pick(ports[port].freeSlots)!
            ports[port].pairings[slot] = profile
            ports[port].receiver!.pair(profile, slot: slot, announce: true)
            return "pair \(profile.codename) to \(label(port, slot))"
        case .repair:
            let (port, from) = rng.pick(receiverMice())!
            guard let to = rng.pick(ports[port].freeSlots) else { return "re-pair on \(ports[port].name): no free slot" }
            let profile = ports[port].pairings.removeValue(forKey: from)!
            ports[port].pairings[to] = profile
            ports[port].held[from] = nil
            let announce = rng.chance(50)
            ports[port].receiver!.repair(from: from, to: to, announceUnpair: announce)
            return "re-pair \(profile.codename) \(label(port, from)) → slot \(to)\(announce ? " (0x40 first)" : "")"
        case .unplug:
            let port = rng.pick(ports.indices.filter { ports[$0].simulator != nil })!
            ports[port].simulator!.disconnect()
            ports[port].simulator = nil
            ports[port].link = nil
            ports[port].held.removeAll()
            return "unplug \(ports[port].name)"
        case .plug:
            let port = rng.pick(ports.indices.filter { ports[$0].simulator == nil })!
            plug(port)
            return "plug \(ports[port].name) in as link \(ports[port].link!)"
        case .switchApp:
            let app = rng.pick([nil, EndToEndRoutingTestsFixtures.editor, EndToEndRoutingTestsFixtures.other] as [String?])!
            fleet.frontmostBundleID = app
            return "frontmost app: \(app ?? "none")"
        case .nativeDPI:
            let (port, slot) = rng.pick(awakeSlots())!
            let supported = ports[port].pairings[slot]!.supportedDPI
            guard let dpi = rng.pick([800, 1200, 1600, 2400].filter(supported.contains)) else {
                return "speed on \(label(port, slot)): no speed to set"
            }
            ports[port].simulator!.setDPINatively(dpi, slot: slot)
            return "speed \(dpi) set on \(label(port, slot))"
        case .refreshInfo:
            fleet.refreshDeviceInfo()
            return "refresh device info"
        case .macWake:
            fleet.refreshAll()
            return "Mac woke"
        case .toggleRemap:
            let (id, model) = rng.pick(units)!
            var prefs = fleet.preferences.preferences(for: id, model: model)
            prefs.remapEnabled.toggle()
            fleet.preferences.setPreferences(prefs, for: id)
            return "remap \(id.rawValue): \(prefs.remapEnabled ? "on" : "off")"
        }
    }

    private mutating func plug(_ port: Int) {
        let simulator = ports[port].makeSimulator()
        ports[port].simulator = simulator
        ports[port].held.removeAll()
        ports[port].link = fleet.attach(simulator).link
    }

    /// Everyone lets go of every button.
    mutating func releaseEverything() {
        for port in ports {
            guard let simulator = port.simulator else { continue }
            for slot in port.held.keys.sorted() where simulator.isAwake(slot: slot) {
                simulator.hold([], slot: slot)
            }
            port.held.removeAll()
        }
        history.append("everyone lets go")
    }

    // MARK: Candidates (sorted, so the plan only depends on the seed)

    private func awakeSlots() -> [(Int, UInt8)] {
        ports.indices.flatMap { port -> [(Int, UInt8)] in
            guard let simulator = ports[port].simulator else { return [] }
            return ports[port].occupiedSlots.filter { simulator.isAwake(slot: $0) }.map { (port, $0) }
        }
    }

    private func asleepSlots() -> [(Int, UInt8)] {
        ports.indices.flatMap { port -> [(Int, UInt8)] in
            guard let simulator = ports[port].simulator else { return [] }
            return ports[port].occupiedSlots.filter { !simulator.isAwake(slot: $0) }.map { (port, $0) }
        }
    }

    private func holdingSlots() -> [(Int, UInt8)] {
        ports.indices.flatMap { port -> [(Int, UInt8)] in
            guard let simulator = ports[port].simulator else { return [] }
            return ports[port].held.keys.sorted().filter { simulator.isAwake(slot: $0) }.map { (port, $0) }
        }
    }

    /// Pointing devices paired to a plugged-in receiver (the keyboard stays where it is).
    private func receiverMice() -> [(Int, UInt8)] {
        ports.indices.flatMap { port -> [(Int, UInt8)] in
            guard ports[port].receiver != nil else { return [] }
            return ports[port].occupiedSlots.filter { ports[port].pairings[$0]?.kind != .keyboard }.map { (port, $0) }
        }
    }

    // MARK: Invariants

    /// After the fleet settled: nothing went wrong in the performer, and no hold belongs to an
    /// endpoint that is gone.
    func problemAfterSettling() -> String? {
        if let violation = fleet.performer.violations.first { return violation }
        let keys = Set(fleet.engine.held.keys).union(fleet.engine.gestures.keys).union(fleet.engine.pressedKeys)
        if let orphan = keys.sorted().first(where: { fleet.endpoint($0.source) == nil }) {
            return "a hold outlived its endpoint: \(orphan)"
        }
        return nil
    }

    /// Every connected endpoint carries the configuration the planner gives it now, and every
    /// awake device behind one is diverted exactly that way.
    func configurationProblems() -> [String] {
        var problems: [String] = []
        for record in fleet.registry.records where record.isConnected {
            guard let snapshot = fleet.snapshot(of: record.address) else { continue }
            let expected = fleet.configuration(for: record.address, snapshot: snapshot, isActive: record.role == .active)
            if fleet.appliedConfig[record.address] != expected {
                problems.append("\(record.displayName) at \(record.address): applied \(String(describing: fleet.appliedConfig[record.address])), planner says \(expected)")
            }
            guard let device = device(at: record.address), device.simulator.isAwake(slot: device.slot) else { continue }
            if device.simulator.diverted(slot: device.slot) != expected.divert || device.simulator.rawXY(slot: device.slot) != expected.rawXY {
                problems.append("\(device.name) at \(record.address): device diverts \(describe(device.simulator.diverted(slot: device.slot))) raw \(describe(device.simulator.rawXY(slot: device.slot))), expected \(describe(expected.divert)) raw \(describe(expected.rawXY))")
            }
        }
        return problems
    }

    /// Devices whose endpoint is connected and who are awake.
    func connectedAwakeDevices() -> [Device] {
        fleet.registry.records.filter(\.isConnected).compactMap { device(at: $0.address) }
            .filter { $0.simulator.isAwake(slot: $0.slot) }
    }

    private func device(at address: DeviceAddress) -> Device? {
        guard let port = ports.first(where: { $0.link == address.link }), let simulator = port.simulator,
              let profile = port.pairings[address.index] else { return nil }
        return Device(name: "\(port.name) \(profile.codename)", simulator: simulator, slot: address.index, address: address)
    }

    // MARK: Descriptions

    private func label(_ port: Int, _ slot: UInt8) -> String {
        let device = ports[port].pairings[slot]?.codename ?? "empty"
        return ports[port].isDirect ? "\(ports[port].name) \(device)" : "\(ports[port].name) slot \(slot) \(device)"
    }

    private func describe(_ cids: [UInt16]) -> String {
        "[" + cids.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ") + "]"
    }

    private func hex(_ cid: UInt16) -> String {
        "0x" + String(cid, radix: 16, uppercase: true)
    }

    private func describe(_ cids: Set<UInt16>) -> String {
        describe(cids.sorted())
    }
}

/// Bundle IDs shared by the tests and the fuzzer.
private enum EndToEndRoutingTestsFixtures {
    static let editor = "com.example.editor"
    static let other = "com.example.other"
}
