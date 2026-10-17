import XCTest
@testable import UprightKit

/// `HIDPPLink` with several devices behind one interface (§G-2): discovery, routing, the
/// capability gate, per-slot state, re-pairing, the request gate and teardown.
@MainActor
final class MultiDeviceControllerTests: XCTestCase {
    /// Diverts every configurable control of whatever connects.
    nonisolated static func divertAll(_ snapshot: DeviceSnapshot) -> EndpointConfiguration {
        EndpointConfiguration(divert: Set(snapshot.configurableControls.map(\.cid)))
    }

    private func makeHub(
        _ simulator: SimulatedHIDPPTransport,
        link: UInt32 = 1,
        tuning: ControllerTuning = .fastTests,
        configuration: @escaping @MainActor (DeviceSnapshot) -> EndpointConfiguration = MultiDeviceControllerTests.divertAll
    ) -> HIDPPLink {
        let hub = makeLink(simulator, link: link, tuning: tuning)
        hub.client.defaultTimeout = tuning.probeTimeout
        hub.client.busyRetryDelay = 0.01
        hub.configurationProvider = { _, snapshot in configuration(snapshot) }
        return hub
    }

    private func configurable(_ profile: SimulatedDeviceProfile) -> Set<UInt16> {
        Set(profile.controls.filter(\.isConfigurable).map(\.cid))
    }

    private func state(_ hub: HIDPPLink, at index: UInt8) -> EndpointController.State? {
        hub.endpoints[index]?.state
    }

    private func unsupportedReason(_ hub: HIDPPLink, at index: UInt8) -> UnsupportedReason? {
        if case .unsupported(let reason, _) = state(hub, at: index) { return reason }
        return nil
    }

    /// setCidReporting requests to device index `index`, read from the raw traffic (works for
    /// slots whose device is gone, unlike the simulator's per-feature counters).
    private func setReportingRequests(_ simulator: SimulatedHIDPPTransport, index: UInt8, reprogIndex: UInt8) -> [[UInt8]] {
        simulator.sentReports.filter { $0.count >= 7 && $0[1] == index && $0[2] == reprogIndex && $0[3] >> 4 == 3 }
    }

    // MARK: Several mice

    func testTwoMXVerticalsOnOneReceiverAreBothServed() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxVerticalSecondUnit])
        let hub = makeHub(receiver)
        let events = Recorder<ButtonEvent>()
        hub.onButtonEvent = { events.append($0) }
        hub.start()

        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        let expected = configurable(DeviceProfiles.mxVertical)
        XCTAssertEqual(receiver.diverted(slot: 1), expected)
        XCTAssertEqual(receiver.diverted(slot: 2), expected)
        let first = try XCTUnwrap(hub.endpoints[1]?.snapshot?.identity)
        let second = try XCTUnwrap(hub.endpoints[2]?.snapshot?.identity)
        XCTAssertEqual(first.model, .mxVertical)
        XCTAssertEqual(second.model, .mxVertical)
        XCTAssertNotEqual(first.deviceID(at: hub.address(of: 1)), second.deviceID(at: hub.address(of: 2)))

        receiver.hold([KnownControl.back], slot: 2)
        await eventually("press from slot 2") { events.count == 1 }
        XCTAssertEqual(events.records, [ButtonEvent(cid: KnownControl.back, phase: .press, source: hub.address(of: 2))])
    }

    func testMixedModelsOnUnifyingEachGetOwnDiversion() async {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3, 3: DeviceProfiles.mxKeys,
        ])
        let hub = makeHub(receiver) { snapshot in
            snapshot.modelKey == .mxVertical
                ? EndpointConfiguration(divert: [KnownControl.back])
                : EndpointConfiguration(divert: [KnownControl.forward, KnownControl.gestureButton])
        }
        hub.start()

        await eventually("both mice connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.diverted(slot: 1), [KnownControl.back])
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.forward, KnownControl.gestureButton])
        XCTAssertEqual(hub.endpoints[2]?.snapshot?.modelKey, ModelKey(productID: 0xB023))
        XCTAssertNil(hub.endpoints[3])
        XCTAssertEqual(receiver.setReportingCount(slot: 3), 0)
        XCTAssertTrue(receiver.diverted(slot: 3).isEmpty)
    }

    func testKeyboardOnSharedReceiverIsNeverWritten() async {
        // Slot 1: listed as a keyboard. Slot 3: the same keyboard with no kind in the pairing
        // table or 0x0005, so only its control table (no mouse buttons) gives it away.
        var disguised = DeviceProfiles.mxKeys.unit(0x8A2B_3C4E, serialNumber: "DEMO-0011")
        disguised.kind = .unknown
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxKeys, 2: DeviceProfiles.mxVertical, 3: disguised])
        let hub = makeHub(receiver)
        hub.start()

        await eventually("mouse connected") { isConnected(hub, at: 2) }
        await eventually("disguised keyboard rejected") { unsupportedReason(hub, at: 3) != nil }
        XCTAssertEqual(unsupportedReason(hub, at: 3), .notAPointer(.unknown))
        XCTAssertNil(hub.endpoints[1])

        // Reports and link-ups from the keyboards change nothing.
        receiver.reportBattery(percentage: 40, slot: 1)
        receiver.announceLink(slot: 1, up: true)
        receiver.announceLink(slot: 3, up: true)
        receiver.reportBattery(percentage: 40, slot: 3)
        await pause(0.2)
        await hub.waitUntilIdle()
        XCTAssertNil(hub.endpoints[1])
        XCTAssertEqual(receiver.pingCount(slot: 1), 0)
        XCTAssertEqual(receiver.setReportingCount(slot: 1), 0)
        XCTAssertEqual(receiver.setReportingCount(slot: 3), 0)
        XCTAssertTrue(receiver.diverted(slot: 1).isEmpty)
        XCTAssertTrue(receiver.diverted(slot: 3).isEmpty)
        XCTAssertEqual(receiver.diverted(slot: 2), configurable(DeviceProfiles.mxVertical))
    }

    // MARK: Observers (upright-probe)

    func testObserverWithoutConfigurationNeverWritesReporting() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3])
        let hub = makeLink(receiver)
        hub.client.defaultTimeout = ControllerTuning.fastTests.probeTimeout
        hub.client.busyRetryDelay = 0.01
        hub.leavesReportingAlone = true
        hub.start()

        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        await hub.waitUntilIdle()
        // A link-up reconfigures the slot; still nothing is written.
        receiver.announceLink(slot: 1, up: true)
        await pause(0.2)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.setReportingCount(slot: 1), 0)
        XCTAssertEqual(receiver.setReportingCount(slot: 2), 0)
    }

    func testObserverStillDivertsWhatItIsAskedTo() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3])
        let hub = makeHub(receiver) { snapshot in
            snapshot.modelKey == .mxVertical ? MultiDeviceControllerTests.divertAll(snapshot) : .native
        }
        hub.leavesReportingAlone = true
        hub.start()

        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxVertical))
        XCTAssertEqual(receiver.setReportingCount(slot: 2), 0)
    }

    func testAppHubForcesNativeReportingOnConnect() async {
        // Not an observer: a natively served mouse still has every control written native, so
        // a diversion left behind by a crashed earlier session is cleared.
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let hub = makeHub(receiver) { _ in .native }
        hub.start()

        await eventually("connected") { isConnected(hub, at: 1) }
        await hub.waitUntilIdle()
        XCTAssertGreaterThan(receiver.setReportingCount(slot: 1), 0)
        XCTAssertTrue(receiver.diverted(slot: 1).isEmpty)
    }

    // MARK: Unsupported devices

    func testHIDPP10DeviceIsUnsupportedAndNotRetried() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.m510HIDPP10])
        let hub = makeHub(receiver)
        hub.start()

        await eventually("unsupported") { unsupportedReason(hub, at: 1) != nil }
        XCTAssertEqual(unsupportedReason(hub, at: 1), .hidpp10(major: 1, minor: 0))
        await hub.waitUntilIdle()
        let pings = receiver.pingCount(slot: 1)

        receiver.announceLink(slot: 1, up: true)
        hub.refresh()
        hub.reconnect(index: 1)
        await pause(0.4)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.pingCount(slot: 1), pings, "terminal: never asked again")
        XCTAssertEqual(unsupportedReason(hub, at: 1), .hidpp10(major: 1, minor: 0))
    }

    func testMouseWithoutReprogControlsIsTerminal() async {
        let mouse = SimulatedDirect(profile: DeviceProfiles.g502Lightspeed)
        let hub = makeHub(mouse)
        var states: [EndpointController.State] = []
        hub.onEndpointChange = { _, state in states.append(state) }
        hub.start()

        await eventually("unsupported") { unsupportedReason(hub, at: 0xFF) != nil }
        XCTAssertEqual(unsupportedReason(hub, at: 0xFF), .noReprogControls)
        if case .unsupported(_, let partial) = state(hub, at: 0xFF) {
            XCTAssertEqual(partial?.name, "G502 LIGHTSPEED Wireless Gaming Mouse")
        }
        await hub.waitUntilIdle()
        let sent = mouse.sentReports.count

        hub.refresh()
        hub.reconnect(index: nil)
        mouse.hold([])
        await pause(0.4)
        await hub.waitUntilIdle()
        XCTAssertEqual(mouse.sentReports.count, sent, "nothing more is sent")
        XCTAssertEqual(mouse.setReportingCount, 0)
        XCTAssertFalse(states.contains { if case .waitingForDevice = $0 { return true } else { return false } })
    }

    // MARK: Receivers

    func testBoltReceiverPairingLayoutFindsBothMice() async {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift])
        let hub = makeHub(receiver)
        hub.start()

        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        XCTAssertEqual(hub.endpoints[1]?.snapshot?.modelKey, ModelKey(productID: 0xB034))
        XCTAssertEqual(hub.endpoints[2]?.snapshot?.modelKey, ModelKey(productID: 0xB031))
        XCTAssertEqual(hub.endpoints[1]?.transportPID, 0xB034, "wireless PID from the Bolt pairing record")
        XCTAssertEqual(hub.endpoints[1]?.snapshot?.connection, .bolt)
        XCTAssertEqual(receiver.registerWriteCount(0x02), 0, "the pairing table was readable")
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxMaster3S))
        XCTAssertEqual(receiver.diverted(slot: 2), configurable(DeviceProfiles.lift))
    }

    func testNanoReceiverUsesUnifyingLayout() async {
        let receiver = SimulatedReceiver.nano([2: DeviceProfiles.m185])
        let hub = makeHub(receiver)
        hub.start()

        await eventually("connected") { isConnected(hub, at: 2) }
        XCTAssertEqual(hub.kind, .receiver(.nano))
        XCTAssertEqual(hub.endpoints[2]?.transportPID, 0x4055)
        XCTAssertEqual(hub.endpoints[2]?.snapshot?.connection, .nano)
        XCTAssertEqual(receiver.registerWriteCount(0x02), 0)
        // Left and Right are flagged divertable on the M185, but never diverted.
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.middleClick])
    }

    func testStartupProbesEverySlot() async {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxVertical, 3: DeviceProfiles.mxMaster3, 6: DeviceProfiles.mxVerticalSecondUnit,
        ])
        let hub = makeHub(receiver)
        hub.start()

        await eventually("all three connected") {
            isConnected(hub, at: 1) && isConnected(hub, at: 3) && isConnected(hub, at: 6)
        }
        await hub.waitUntilIdle()
        XCTAssertEqual(hub.orderedEndpoints.map(\.address.index), [1, 3, 6])
        for empty: UInt8 in [2, 4, 5] {
            XCTAssertEqual(receiver.pingCount(slot: empty), 0, "slot \(empty) is empty in the pairing table")
        }
    }

    // MARK: Per-slot state

    func testSleepingSlotDoesNotDelayOtherSlotBeyondOneTimeout() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3S])
        receiver.setDropsRequests(true, slot: 1)
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.3
        tuning.retryBaseDelay = 5
        tuning.retryMaxDelay = 5
        tuning.retryMaxDelayWithNotifications = 5
        let hub = makeHub(receiver, tuning: tuning)
        let began = Date()
        hub.start()

        await eventually("slot 2 connected") { isConnected(hub, at: 2) }
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 0.3 + 0.45, "slot 2 waited for at most one of slot 1's timeouts")
        await eventually("slot 1 waiting") { state(hub, at: 1) == .waitingForDevice }

        receiver.setDropsRequests(false, slot: 1)
        receiver.hold([], slot: 1)
        await eventually("slot 1 connected after it reported") { isConnected(hub, at: 1) }
    }

    func testBackoffAndCountersArePerSlot() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.setDropsRequests(true, slot: 1)
        receiver.setDropsRequests(true, slot: 2)
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.1
        // The receiver accepts notifications, so absent slot 1 backs off up to
        // `retryMaxDelayWithNotifications`; held equal to `retryMaxDelay` here so it keeps probing.
        tuning.retryMaxDelayWithNotifications = tuning.retryMaxDelay
        let hub = makeHub(receiver, tuning: tuning)
        hub.start()

        await eventually("both retried", timeout: 5) { receiver.pingCount(slot: 1) >= 2 && receiver.pingCount(slot: 2) >= 2 }
        XCTAssertNotEqual(receiver.notificationFlags[1] & 0x01, 0, "wireless notifications are on")
        receiver.setDropsRequests(false, slot: 2)
        await eventually("slot 2 connected by its own retry", timeout: 5) { isConnected(hub, at: 2) }
        let slot2Pings = receiver.pingCount(slot: 2)
        let slot1Pings = receiver.pingCount(slot: 1)

        await pause(0.8)
        XCTAssertEqual(receiver.pingCount(slot: 2), slot2Pings, "a connected slot isn't probed again")
        XCTAssertGreaterThan(receiver.pingCount(slot: 1), slot1Pings, "slot 1 keeps retrying on its own")
        XCTAssertEqual(state(hub, at: 1), .waitingForDevice)
        XCTAssertTrue(isConnected(hub, at: 2))
    }

    func testAbsentSlotBacksOffFurtherOnceReceiverNotificationsAreOn() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.setDropsRequests(true, slot: 1)
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.1
        tuning.retryBaseDelay = 0.05
        tuning.retryMaxDelay = 0.1
        tuning.retryMaxDelayWithNotifications = 5
        let hub = makeHub(receiver, tuning: tuning)
        hub.start()

        // Probes follow delays of 0.05, 0.1, 0.2, 0.4, 0.8 s (plus a 0.1 s timeout each): after
        // the fifth, the next one is at least 0.9 s away. With the 0.1 s cap it would be 0.2 s.
        await eventually("slot 2 connected and slot 1 backed off", timeout: 5) {
            isConnected(hub, at: 2) && receiver.pingCount(slot: 1) >= 5
        }
        XCTAssertNotEqual(receiver.notificationFlags[1] & 0x01, 0, "wireless notifications are on")
        let pings = receiver.pingCount(slot: 1)
        await pause(0.4)
        XCTAssertEqual(receiver.pingCount(slot: 1), pings, "no probe past retryMaxDelay while notifications are on")
        XCTAssertEqual(state(hub, at: 1), .waitingForDevice)

        // The link-up notification brings it back, well before the next poll.
        receiver.setDropsRequests(false, slot: 1)
        receiver.wakeUp(slot: 1, clearingDiversion: true)
        await eventually("slot 1 connected after link-up") { isConnected(hub, at: 1) }
    }

    func testAbsentSlotKeepsRetryMaxDelayWithoutReceiverNotifications() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.supportsNotificationFlags = false
        receiver.setDropsRequests(true, slot: 1)
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.1
        tuning.retryBaseDelay = 0.05
        tuning.retryMaxDelay = 0.1
        tuning.retryMaxDelayWithNotifications = 5
        let hub = makeHub(receiver, tuning: tuning)
        hub.start()

        await eventually("slot 2 connected and slot 1 backed off", timeout: 5) {
            isConnected(hub, at: 2) && receiver.pingCount(slot: 1) >= 5
        }
        XCTAssertEqual(receiver.notificationFlags, [0, 0, 0])
        let pings = receiver.pingCount(slot: 1)
        await pause(0.8)
        XCTAssertGreaterThanOrEqual(receiver.pingCount(slot: 1), pings + 2, "slot 1 keeps probing every retryMaxDelay")
        XCTAssertEqual(state(hub, at: 1), .waitingForDevice)
    }

    func testAbsentSlotPollsAgainWhenNotificationFlagsCanNotBeRestored() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.setDropsRequests(true, slot: 1)
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.1
        tuning.retryBaseDelay = 0.05
        tuning.retryMaxDelay = 0.1
        tuning.retryMaxDelayWithNotifications = 5
        let hub = makeHub(receiver, tuning: tuning)
        hub.start()
        await eventually("slot 2 connected and slot 1 backed off", timeout: 5) {
            isConnected(hub, at: 2) && receiver.pingCount(slot: 1) >= 5
        }

        // The Mac wakes, but rewriting the flags fails: no link-up can be counted on to
        // announce slot 1, so it goes back to the short poll.
        receiver.supportsNotificationFlags = false
        hub.refresh()
        let before = receiver.pingCount(slot: 1)
        await eventually("slot 1 probed again after the wake", timeout: 5) { receiver.pingCount(slot: 1) >= before + 5 }
        let pings = receiver.pingCount(slot: 1)
        await pause(0.4)
        XCTAssertGreaterThan(receiver.pingCount(slot: 1), pings, "slot 1 keeps probing every retryMaxDelay")
        XCTAssertEqual(state(hub, at: 1), .waitingForDevice)
    }

    func testWakePingPongKeepsBothSessions() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3])
        let hub = makeHub(receiver)
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        let first = hub.endpoints[1]
        let second = hub.endpoints[2]

        for round in 0..<3 {
            receiver.goToSleep(slot: 1)
            await eventually("1 asleep, round \(round)") { isAsleep(hub, at: 1) }
            receiver.wakeUp(slot: 1, clearingDiversion: true)
            receiver.goToSleep(slot: 2)
            await eventually("1 back, 2 asleep, round \(round)") { isConnected(hub, at: 1) && isAsleep(hub, at: 2) }
            receiver.wakeUp(slot: 2, clearingDiversion: true)
            await eventually("2 back, round \(round)") { isConnected(hub, at: 2) }
        }
        await hub.waitUntilIdle()
        XCTAssertTrue(hub.endpoints[1] === first)
        XCTAssertTrue(hub.endpoints[2] === second)
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxVertical))
        XCTAssertEqual(receiver.diverted(slot: 2), configurable(DeviceProfiles.mxMaster3))
    }

    // MARK: Pairing changes

    func testRePairByUnitIDRetiresOldSlotWithUndivert() async throws {
        let receiver = SimulatedReceiver.unifying([2: DeviceProfiles.mxVertical, 4: DeviceProfiles.mxMaster3])
        let hub = makeHub(receiver)
        var removed: [(DeviceAddress, HIDPPLink.RemovalReason)] = []
        hub.onEndpointRemoved = { removed.append(($0, $1)) }
        hub.start()
        await eventually("connected") { isConnected(hub, at: 2) && isConnected(hub, at: 4) }
        let reprog = try XCTUnwrap(DeviceProfiles.mxVertical.featureIndex(of: 0x1B04))
        let before = setReportingRequests(receiver, index: 2, reprogIndex: reprog).count

        receiver.repair(from: 2, to: 5, announceUnpair: false)
        await eventually("moved to slot 5") { isConnected(hub, at: 5) }
        XCTAssertNil(hub.endpoints[2])
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.0, hub.address(of: 2))
        XCTAssertEqual(removed.first?.1, .retired(movedTo: hub.address(of: 5)))
        let undiverts = setReportingRequests(receiver, index: 2, reprogIndex: reprog).dropFirst(before)
        XCTAssertEqual(undiverts.count, configurable(DeviceProfiles.mxVertical).count, "every diverted control handed back")
        XCTAssertEqual(receiver.diverted(slot: 5), configurable(DeviceProfiles.mxVertical))
        XCTAssertTrue(isConnected(hub, at: 4), "the other mouse is untouched")
    }

    func testUnpairRemovesOnlyThatSlot() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        let hub = makeHub(receiver)
        let events = Recorder<ButtonEvent>()
        hub.onButtonEvent = { events.append($0) }
        var removed: [(DeviceAddress, HIDPPLink.RemovalReason)] = []
        hub.onEndpointRemoved = { removed.append(($0, $1)) }
        hub.start()
        await eventually("connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }

        receiver.hold([KnownControl.back], slot: 1)
        receiver.hold([KnownControl.forward], slot: 2)
        await eventually("both pressed") { events.count == 2 }
        receiver.unpair(slot: 1)
        await eventually("slot 1 removed") { hub.endpoints[1] == nil }

        XCTAssertEqual(removed.map(\.0), [hub.address(of: 1)])
        XCTAssertEqual(removed.map(\.1), [.unpaired])
        XCTAssertEqual(events.records.last, ButtonEvent(cid: KnownControl.back, phase: .release, source: hub.address(of: 1)))
        XCTAssertFalse(events.records.contains(ButtonEvent(cid: KnownControl.forward, phase: .release, source: hub.address(of: 2))))
        XCTAssertTrue(isConnected(hub, at: 2))
        XCTAssertEqual(receiver.diverted(slot: 2), configurable(DeviceProfiles.lift))
    }

    func testDifferentWPIDInOccupiedSlotReplacesEndpoint() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let hub = makeHub(receiver)
        var removed: [(DeviceAddress, HIDPPLink.RemovalReason)] = []
        hub.onEndpointRemoved = { removed.append(($0, $1)) }
        hub.start()
        await eventually("connected") { isConnected(hub, at: 1) }
        let old = hub.endpoints[1]

        receiver.pair(DeviceProfiles.lift, slot: 1, announce: true)
        await eventually("lift connected") { hub.endpoints[1]?.snapshot?.modelKey == ModelKey(productID: 0xB031) && isConnected(hub, at: 1) }
        XCTAssertFalse(hub.endpoints[1] === old)
        XCTAssertEqual(removed.map(\.1), [.replaced])
        XCTAssertEqual(old?.isShutDown, true)
        // The vertical's restore messages would have reached the lift at the wrong feature index.
        XCTAssertEqual(receiver.requestCount(feature: 0x1814, function: 3, slot: 1), 0)
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.lift))
    }

    func testMissedLinkUpRecoveredFromReport() async {
        let receiver = SimulatedReceiver.unifying([3: DeviceProfiles.mxMaster3])
        receiver.supportsPairingInfo = false
        receiver.goToSleep(slot: 3)
        let hub = makeHub(receiver)
        hub.start()
        await hub.waitUntilIdle()
        XCTAssertTrue(hub.endpoints.isEmpty, "announced as down, and the ping found nothing")

        // It wakes without the receiver announcing it; only its report shows it's back.
        receiver.wakeUp(slot: 3, clearingDiversion: true, announce: false)
        receiver.hold([], slot: 3)
        await eventually("connected from the report") { isConnected(hub, at: 3) }
        XCTAssertEqual(receiver.diverted(slot: 3), configurable(DeviceProfiles.mxMaster3))
    }

    func testSlotBackWithoutLinkUpOrReportIsFoundByPolling() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let hub = makeHub(receiver)
        hub.start()
        await eventually("connected") { isConnected(hub, at: 1) }

        // The link-down arrives, but the link-up after an Easy-Switch back (or a Mac wake) is
        // missed and the mouse sends nothing, so only polling can find it again.
        receiver.goToSleep(slot: 1)
        await eventually("asleep") { isAsleep(hub, at: 1) }
        receiver.wakeUp(slot: 1, clearingDiversion: true, announce: false)
        await eventually("reconnected by polling") { isConnected(hub, at: 1) }
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxVertical))
    }

    func testAnnouncementEchoSuppressionIsPerSlot() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.supportsPairingInfo = false
        let hub = makeHub(receiver)
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.registerWriteCount(0x02), 1)
        let slot1Writes = receiver.setReportingCount(slot: 1)

        // Within the echo window: a repeated announcement for slot 1 is not a reconnect, but a
        // real sleep and wake of slot 2 is.
        receiver.announceLink(slot: 1, up: true)
        receiver.goToSleep(slot: 2)
        await eventually("2 asleep") { isAsleep(hub, at: 2) }
        receiver.wakeUp(slot: 2, clearingDiversion: true)
        await eventually("2 re-diverted") { receiver.diverted(slot: 2) == configurable(DeviceProfiles.lift) }
        await pause(0.1)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.setReportingCount(slot: 1), slot1Writes)
        XCTAssertTrue(isConnected(hub, at: 1))
        XCTAssertTrue(isConnected(hub, at: 2))
    }

    func testNotificationFlagsAreReadModifyWrittenOncePerLink() async {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift, 3: DeviceProfiles.mxMaster3,
        ])
        receiver.notificationFlags = [0x00, 0x10, 0x04] // set by another program
        let hub = makeHub(receiver)
        hub.start()
        await eventually("all connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) && isConnected(hub, at: 3) }
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.registerReadCount(0x00), 1)
        XCTAssertEqual(receiver.registerWriteCount(0x00), 1, "once for the receiver, not once per slot")
        XCTAssertEqual(receiver.notificationFlags, [0x00, 0x19, 0x04], "other flags kept")

        // A per-slot reconfiguration (0x1D4B) leaves the receiver alone.
        receiver.reportReconnect(slot: 2)
        await eventually("slot 2 re-diverted") { receiver.diverted(slot: 2) == configurable(DeviceProfiles.lift) }
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.registerWriteCount(0x00), 1)

        // A Mac wake re-asserts the flags once for the whole receiver.
        hub.refresh()
        await pause(0.05)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.registerWriteCount(0x00), 2)
        XCTAssertEqual(receiver.notificationFlags, [0x00, 0x19, 0x04])
    }

    // MARK: Refused reports

    func testDirectMouseWhoseReportsAreRefusedFailsSoItCanBeReopened() async {
        let mouse = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .bluetooth)
        let hub = makeHub(mouse)
        hub.start()
        let index = DeviceAddress.direct
        await eventually("connected") { isConnected(hub, at: index) }

        // After a Mac sleep, macOS refused every report on the old Bluetooth handle
        // (kIOReturnBadArgument). Retrying there can't help, so the endpoint reports a failure,
        // which is what makes the app open the interface again.
        mouse.sendError = Int32(bitPattern: 0xE000_02C2)
        hub.refresh()
        await eventually("failed") {
            if case .failed = state(hub, at: index) { return true }
            return false
        }
        XCTAssertNotNil(hub.endpoints[index]?.snapshot, "the session is kept")

        // It keeps retrying meanwhile, in case the same interface starts working again.
        mouse.sendError = nil
        mouse.forgetDiversion()
        await eventually("reconnected") { isConnected(hub, at: index) }
        XCTAssertEqual(mouse.diverted, configurable(DeviceProfiles.mxVertical))
    }

    func testReceiverSlotWhoseReportsAreRefusedOnlySleeps() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let hub = makeHub(receiver)
        hub.start()
        await eventually("connected") { isConnected(hub, at: 1) }

        receiver.sendError = Int32(bitPattern: 0xE000_02C2)
        hub.refresh()
        await eventually("asleep") { isAsleep(hub, at: 1) }
    }

    // MARK: Device actions

    func testEasySwitchOnBLeavesALone() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3S])
        let hub = makeHub(receiver)
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        await hub.waitUntilIdle()
        let slot1Writes = receiver.setReportingCount(slot: 1)

        hub.switchToHost(1, at: 2)
        await eventually("B left") { receiver.hostSwitches(slot: 2) == [1] }
        await eventually("B asleep") { isAsleep(hub, at: 2) }
        await pause(0.1)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.hostSwitches(slot: 1), [])
        XCTAssertTrue(isConnected(hub, at: 1))
        XCTAssertEqual(receiver.setReportingCount(slot: 1), slot1Writes)
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxVertical))
    }

    // MARK: Teardown

    func testShutdownRestoresEverySlot() async {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift, 4: DeviceProfiles.mxMaster3,
        ])
        let hub = makeHub(receiver)
        var removed: [(DeviceAddress, HIDPPLink.RemovalReason)] = []
        hub.onEndpointRemoved = { removed.append(($0, $1)) }
        hub.start()
        await eventually("all connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) && isConnected(hub, at: 4) }
        XCTAssertFalse(receiver.diverted(slot: 4).isEmpty)

        hub.shutdown()
        for slot: UInt8 in [1, 2, 4] {
            XCTAssertTrue(receiver.diverted(slot: slot).isEmpty, "slot \(slot)")
        }
        XCTAssertTrue(hub.endpoints.isEmpty)
        XCTAssertEqual(removed.map(\.0), [hub.address(of: 1), hub.address(of: 2), hub.address(of: 4)])
        XCTAssertTrue(removed.allSatisfy { $0.1 == .transportClosed })
        XCTAssertTrue(hub.isShutDown)
    }

    func testDroppedEndpointSendsRestore() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let hub = makeHub(receiver) { _ in
            EndpointConfiguration(divert: [KnownControl.back], rawXY: [KnownControl.dpiSwitch])
        }
        let events = Recorder<ButtonEvent>()
        hub.onButtonEvent = { events.append($0) }
        hub.start()
        await eventually("connected") { isConnected(hub, at: 1) }
        XCTAssertEqual(receiver.rawXY(slot: 1), [KnownControl.dpiSwitch])
        let reprog = try XCTUnwrap(DeviceProfiles.mxVertical.featureIndex(of: 0x1B04))
        let before = setReportingRequests(receiver, index: 1, reprogIndex: reprog).count

        receiver.hold([KnownControl.dpiSwitch], slot: 1)
        await eventually("pressed") { events.count == 1 }
        // Re-paired: the endpoint in slot 1 is dropped while the mouse may still hear it.
        receiver.repair(from: 1, to: 2, announceUnpair: false)
        await eventually("moved") { isConnected(hub, at: 2) }

        XCTAssertEqual(events.records[1], ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release, source: hub.address(of: 1)))
        let restores = Array(setReportingRequests(receiver, index: 1, reprogIndex: reprog).dropFirst(before))
        var byCID: [UInt16: UInt8] = [:]
        for report in restores {
            let cid = UInt16(report[4]) << 8 | UInt16(report[5])
            byCID[cid] = report[6]
        }
        XCTAssertEqual(Set(byCID.keys), [KnownControl.back, KnownControl.dpiSwitch])
        XCTAssertEqual(byCID[KnownControl.back], ReprogControls.reportingFlags(diverted: false, rawXY: nil).rawValue)
        XCTAssertEqual(byCID[KnownControl.dpiSwitch], ReprogControls.reportingFlags(diverted: false, rawXY: false).rawValue)
    }

    // MARK: Ordering and the request gate

    func testConfigurationIsPulledBeforeFirstDiversion() async {
        let receiver = SimulatedReceiver.unifying([2: DeviceProfiles.mxVertical, 5: DeviceProfiles.lift])
        var pulls: [(DeviceAddress, DeviceSnapshot, Int)] = []
        let hub = makeHub(receiver)
        hub.configurationProvider = { address, snapshot in
            pulls.append((address, snapshot, receiver.setReportingCount(slot: address.index)))
            return snapshot.modelKey == .mxVertical ? EndpointConfiguration(divert: [KnownControl.forward]) : .native
        }
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 2) && isConnected(hub, at: 5) }

        XCTAssertEqual(Set(pulls.map(\.0)), [hub.address(of: 2), hub.address(of: 5)])
        for (address, snapshot, writesBefore) in pulls {
            XCTAssertEqual(writesBefore, 0, "nothing written to \(address) before its configuration was known")
            XCTAssertEqual(snapshot.address, address)
            XCTAssertNotNil(snapshot.identity)
        }
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.forward])
        XCTAssertTrue(receiver.diverted(slot: 5).isEmpty)
        XCTAssertEqual(hub.endpoints[2]?.desiredDiversion, [KnownControl.forward])
    }

    func testOneRequestInFlightPerTransport() async {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3, 3: DeviceProfiles.lift, 4: DeviceProfiles.m185,
        ])
        receiver.latency = 0.002
        receiver.setDropsRequests(true, slot: 4)
        receiver.unansweredRequestWindow = 0.15
        var tuning = ControllerTuning.fastTests
        tuning.probeTimeout = 0.2
        let hub = makeHub(receiver, tuning: tuning)
        hub.start()

        // Serialized probing of three mice behind a slot that drops every request: ~1.5 s locally,
        // over 3 s on CI runners.
        await eventually("three connected", timeout: 15) { isConnected(hub, at: 1) && isConnected(hub, at: 2) && isConnected(hub, at: 3) }
        hub.refreshDeviceInfo(at: nil)
        hub.cycleDPI(at: 1, presets: [800, 1600])
        hub.setConfiguration(EndpointConfiguration(divert: [KnownControl.back]), at: 2)
        await pause(0.3)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.requestsInFlightMax, 1)
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.back])
    }

    func testFirstRawXYReportDroppedOnReprogV5() async {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift])
        let hub = makeHub(receiver) { snapshot in
            EndpointConfiguration(rawXY: snapshot.modelKey == ModelKey(productID: 0xB034) ? [KnownControl.gestureButton] : [KnownControl.back])
        }
        let deltas = Recorder<PointerDelta>()
        hub.onPointerDelta = { deltas.append($0) }
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        XCTAssertEqual(hub.endpoints[1]?.snapshot?.reprogVersion, 5)
        XCTAssertEqual(receiver.rawXY(slot: 1), [KnownControl.gestureButton])

        receiver.hold([KnownControl.gestureButton], slot: 1)
        receiver.move(dx: 99, dy: -99, slot: 1)
        receiver.move(dx: 3, dy: 4, slot: 1)
        receiver.hold([], slot: 1)
        await eventually("one delta") { deltas.count == 1 }
        await pause(0.05)
        XCTAssertEqual(deltas.records, [PointerDelta(source: hub.address(of: 1), dx: 3, dy: 4)])
    }

    func testUnsupportedExclusionClearsOnNewWPID() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.g502Lightspeed, 2: DeviceProfiles.mxKeys])
        let hub = makeHub(receiver)
        hub.start()
        await eventually("g502 unsupported") { unsupportedReason(hub, at: 1) == .noReprogControls }
        await hub.waitUntilIdle()
        let pings = receiver.pingCount(slot: 1)

        // The same device announcing itself again stays excluded.
        receiver.announceLink(slot: 1, up: true)
        await pause(0.1)
        await hub.waitUntilIdle()
        XCTAssertEqual(receiver.pingCount(slot: 1), pings)

        // Another device paired in its place (and in the keyboard's) is served.
        receiver.pair(DeviceProfiles.mxMaster3, slot: 1, announce: true)
        receiver.pair(DeviceProfiles.lift, slot: 2, announce: true)
        await eventually("new devices connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        XCTAssertEqual(hub.endpoints[1]?.snapshot?.modelKey, ModelKey(productID: 0xB023))
        XCTAssertEqual(receiver.diverted(slot: 1), configurable(DeviceProfiles.mxMaster3))
        XCTAssertEqual(receiver.diverted(slot: 2), configurable(DeviceProfiles.lift))
    }
}
