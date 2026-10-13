import XCTest
@testable import UprightKit

@MainActor
final class ControllerTests: XCTestCase {
    private func makeController(_ mouse: SimulatedMXVertical, kind: TransportKind) -> MXVerticalController {
        let controller = MXVerticalController(transport: mouse, kind: kind)
        controller.probeTimeout = 0.2
        controller.reconnectDelay = 0
        controller.retryBaseDelay = 0.05
        controller.retryMaxDelay = 0.2
        controller.announcementWait = 0.05
        controller.client.defaultTimeout = 0.2
        controller.client.busyRetryDelay = 0.01
        return controller
    }

    private func eventually(
        _ description: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for: \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func isConnected(_ controller: MXVerticalController) -> Bool {
        if case .connected = controller.state { return true }
        return false
    }

    private func isAsleep(_ controller: MXVerticalController) -> Bool {
        if case .asleep = controller.state { return true }
        return false
    }

    private let defaultDiversion = ButtonMappings.legacyDefaults.divertedControls(accessibilityGranted: true)
    private let expectedDiversion: Set<UInt16> = [0x53, 0x56, 0xFD]

    // MARK: Discovery

    func testDirectConnectionDiscoversAndDivertsButtons() async throws {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        let snapshot = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(snapshot.name, "MX Vertical")
        XCTAssertEqual(snapshot.deviceIndex, 0xFF)
        XCTAssertEqual(snapshot.protocolVersion, "4.5")
        XCTAssertEqual(snapshot.battery, BatteryStatus(percentage: 80, isCharging: false))
        XCTAssertEqual(snapshot.configurableControls.map(\.cid), [0x52, 0x53, 0x56, 0xFD])
        XCTAssertEqual(snapshot.features.map(\.featureID), SimulatedMXVertical.allFeatures)
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testButtonEventsReachTheEngine() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)
        controller.onButtonEvent = { engine.handle($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.hold([KnownControl.dpiSwitch])
        mouse.hold([])
        mouse.hold([KnownControl.back])
        mouse.hold([])

        await eventually("three effects") { performer.log.count == 3 }
        XCTAssertEqual(performer.log.map(\.0), [
            .missionControl(.missionControl),
            .keyCombo(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)),
            .keyCombo(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command)),
        ])
        XCTAssertEqual(performer.log.map(\.1), [.down, .down, .up])
    }

    func testChangingMappingsUpdatesDiversion() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.bluetooth))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        controller.setDesiredDiversion([KnownControl.middleClick])
        await eventually("only wheel click diverted") { mouse.diverted == [KnownControl.middleClick] }

        controller.setDesiredDiversion([])
        await eventually("nothing diverted") { mouse.diverted.isEmpty }
    }

    func testReceiverFindsMouseInItsSlot() async throws {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(controller.snapshot?.deviceIndex, 2)
        XCTAssertEqual(controller.snapshot?.connection, .unifying)
        XCTAssertEqual(mouse.diverted, expectedDiversion)
        // Receiver notifications were enabled via HID++ 1.0 register 0x00.
        XCTAssertTrue(mouse.sentReports.contains { Array($0.prefix(7)) == [0x10, 0xFF, 0x80, 0x00, 0x00, 0x09, 0x00] })
    }

    func testReceiverUsesPairingInfoInsteadOfPingingEverySlot() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 4))
        mouse.addDevice(slot: 1, name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(controller.snapshot?.deviceIndex, 4)
        let firstDeviceRequest = mouse.sentReports.first { (1...6).contains($0[1]) }
        XCTAssertEqual(firstDeviceRequest?[1], 4)
        XCTAssertEqual(mouse.pingCount(to: 1), 0)
        XCTAssertEqual(mouse.registerWriteCount(0x02), 0)
    }

    func testReceiverWithoutPairingInfoAsksForAnnouncements() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 3))
        mouse.supportsPairingInfo = false
        mouse.addDevice(slot: 1, name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(controller.snapshot?.deviceIndex, 3)
        XCTAssertEqual(mouse.registerWriteCount(0x02), 1)
        XCTAssertEqual(mouse.pingCount(to: 1), 0)
        // The announcement for the configured slot is not mistaken for a reconnect.
        await controller.waitUntilIdle()
        await pause(0.1)
        XCTAssertEqual(mouse.setReportingCount, SimulatedMXVertical.configurableCount)
    }

    func testReceiverIgnoresOtherDevices() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1), name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.start()
        await eventually("waiting") { controller.state == .waitingForDevice }
        XCTAssertNil(controller.snapshot)
    }

    // MARK: Sleep and wake

    func testSleepingMouseIsReconfiguredWhenItWakes() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.goToSleep()
        await eventually("asleep") { isAsleep(controller) }

        mouse.wakeUp(clearingDiversion: true)
        XCTAssertTrue(mouse.diverted.isEmpty)
        await eventually("re-diverted after wake") { mouse.diverted == expectedDiversion }
        await eventually("connected again") { isConnected(controller) }
        // Receiver notifications are re-enabled on every reconfiguration, not just the first probe.
        XCTAssertGreaterThanOrEqual(mouse.registerWriteCount(0x00), 2)
    }

    func testLinkUpAndWirelessStatusTogetherReconfigureOnce() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.reconnectDelay = 0.1
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.goToSleep()
        await eventually("asleep") { isAsleep(controller) }
        let before = mouse.setReportingCount

        mouse.wakeUp(clearingDiversion: true, reportReconnect: true)
        await eventually("re-diverted after wake") { mouse.diverted == expectedDiversion }
        await eventually("connected again") { isConnected(controller) }
        await pause(0.3)
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.setReportingCount - before, SimulatedMXVertical.configurableCount)
    }

    func testMouseThatArrivesLaterIsPickedUp() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 3))
        mouse.goToSleep()
        let controller = makeController(mouse, kind: .receiver(.bolt))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("waiting") { controller.state == .waitingForDevice }

        mouse.wakeUp()
        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(controller.snapshot?.deviceIndex, 3)
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testReportFromASilentlyWokenMouseTriggersReconnect() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        mouse.goToSleep()
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.retryBaseDelay = 30
        controller.retryMaxDelay = 30
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("waiting") { controller.state == .waitingForDevice }

        // No 0x41 link-up: only a device report shows the mouse is back.
        mouse.wakeUp(clearingDiversion: true, announce: false)
        mouse.hold([])
        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testWirelessStatusReconnectTriggersReapply() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.bluetooth))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.reportReconnect()
        await eventually("re-diverted") { mouse.diverted == expectedDiversion }
    }

    func testRefreshAfterMacWakeReappliesDiversion() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        // The mouse lost its state without telling us; only refresh() can restore it.
        mouse.forgetDiversion()
        controller.refresh()
        await eventually("re-diverted") { mouse.diverted == expectedDiversion }
    }

    // MARK: Timeouts and recovery (H1)

    func testDirectTimeoutKeepsSessionAndButtonsKeepWorking() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.retryBaseDelay = 30
        controller.retryMaxDelay = 30
        var events: [ButtonEvent] = []
        controller.onButtonEvent = { events.append($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.dropsRequests = true
        controller.refresh()
        await eventually("asleep after a timeout") { isAsleep(controller) }
        XCTAssertNotNil(controller.snapshot, "the session survives a timeout")

        // The mouse answers again and a diverted button arrives before any retry is due.
        mouse.dropsRequests = false
        mouse.hold([KnownControl.back])
        await eventually("press delivered while asleep") { events.contains(ButtonEvent(cid: KnownControl.back, phase: .press)) }
        await eventually("reconfigured by the report") { isConnected(controller) }
    }

    func testUnansweringDirectMouseIsRetriedWithBackoff() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        mouse.dropsRequests = true
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("waiting") { controller.state == .waitingForDevice }
        await eventually("several attempts", timeout: 5) { mouse.pingCount(to: 0xFF) >= 3 }
        XCTAssertEqual(controller.state, .waitingForDevice)

        mouse.dropsRequests = false
        await eventually("connected by a retry", timeout: 5) { isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testAsleepDirectMouseRecoversThroughBackoffAlone() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.dropsRequests = true
        mouse.forgetDiversion()
        controller.refresh()
        await eventually("asleep") { isAsleep(controller) }
        await pause(0.5)
        XCTAssertTrue(isAsleep(controller), "keeps retrying instead of giving up")

        mouse.dropsRequests = false
        await eventually("connected again", timeout: 5) { isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testReportWhileWaitingTriggersProbeOnDirectConnection() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        mouse.dropsRequests = true
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.retryBaseDelay = 30
        controller.retryMaxDelay = 30
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("waiting") { controller.state == .waitingForDevice }

        mouse.dropsRequests = false
        mouse.hold([])
        await eventually("connected") { isConnected(controller) }
    }

    // MARK: Held buttons (stuck keys)

    func testHeldButtonIsReleasedWhenTheMouseStopsAnswering() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.retryBaseDelay = 30
        var events: [ButtonEvent] = []
        controller.onButtonEvent = { events.append($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.hold([KnownControl.forward])
        await eventually("pressed") { events == [ButtonEvent(cid: KnownControl.forward, phase: .press)] }
        mouse.dropsRequests = true
        controller.refresh()
        await eventually("released") { events.last == ButtonEvent(cid: KnownControl.forward, phase: .release) }
    }

    func testSnapshotUpdatesWhileConnectedDoNotReleaseHeldButtons() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        var events: [ButtonEvent] = []
        var states: [MXVerticalController.State] = []
        controller.onButtonEvent = { events.append($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }
        controller.onStateChange = { states.append($0) }

        mouse.hold([KnownControl.back])
        await eventually("pressed") { events == [ButtonEvent(cid: KnownControl.back, phase: .press)] }

        // Each of these publishes a new `.connected` snapshot while the button is still held.
        controller.setDPI(1600)
        await controller.waitUntilIdle()
        mouse.reportBattery(percentage: 42)
        await eventually("battery published") { controller.snapshot?.battery?.percentage == 42 }
        controller.refreshDeviceInfo()
        await controller.waitUntilIdle()
        await pause(0.05)
        XCTAssertGreaterThanOrEqual(states.count, 2, "snapshot updates were published")
        XCTAssertTrue(states.allSatisfy { if case .connected = $0 { return true } else { return false } })
        XCTAssertEqual(events, [ButtonEvent(cid: KnownControl.back, phase: .press)], "held button was released by a snapshot update")

        // A second button goes down while the first is still held: only it is pressed.
        mouse.hold([KnownControl.back, KnownControl.forward])
        await eventually("second press") { events.count == 2 }
        await pause(0.05)
        XCTAssertEqual(events, [
            ButtonEvent(cid: KnownControl.back, phase: .press),
            ButtonEvent(cid: KnownControl.forward, phase: .press),
        ])
    }

    func testTransportRemovalReleasesHeldButtons() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .legacyDefaults, performer: performer)
        controller.onButtonEvent = { engine.handle($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.hold([KnownControl.forward])
        await eventually("key down") { performer.log.count == 1 }
        mouse.disconnect()
        await eventually("key up") { performer.log.count == 2 }
        XCTAssertEqual(performer.log.last?.1, .up)
        await eventually("failed") { controller.state == .failed("Disconnected") }
    }

    // MARK: Shutdown (H2)

    func testShutdownHandsButtonsBackToTheMouse() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        controller.shutdown()
        XCTAssertTrue(mouse.diverted.isEmpty)
    }

    func testShutdownStopsQueuedWork() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        mouse.dropsRequests = true
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await pause(0.05)

        controller.shutdown()
        XCTAssertTrue(controller.isShutDown)
        let sentAtShutdown = mouse.sentReports.count
        controller.refresh()
        controller.setDesiredDiversion([KnownControl.back])
        mouse.dropsRequests = false
        mouse.hold([])
        await pause(0.5)
        await controller.waitUntilIdle()

        XCTAssertEqual(mouse.sentReports.count, sentAtShutdown)
        XCTAssertEqual(controller.state, .failed("Disconnected"))
    }

    func testTransportCloseDuringProbeIsTerminal() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1), name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.start()
        await pause(0.02)
        mouse.disconnect()

        await eventually("failed") { controller.state == .failed("Disconnected") }
        await pause(0.5)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.state, .failed("Disconnected"))
        XCTAssertTrue(controller.isShutDown)
    }

    // MARK: Per-control failures (M1)

    func testOneRefusedControlDoesNotBlockTheOthers() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        mouse.failDiversion(of: KnownControl.forward, code: 0x04)
        let controller = makeController(mouse, kind: .direct(.usb))
        var logs: [String] = []
        controller.onLog = { logs.append($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(mouse.diverted, [KnownControl.back, KnownControl.dpiSwitch])
        XCTAssertTrue(logs.contains { $0.contains("0x0056") && $0.contains("refused") })
    }

    func testBusyControlIsRetried() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        mouse.failDiversion(of: KnownControl.back, code: 0x08, times: 2)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()

        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    // MARK: Re-pairing (M3)

    func testRePairToANewSlotMovesTheSession() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        mouse.addDevice(slot: 1, name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.repair(toSlot: 3, announceUnpair: false)
        await eventually("moved to slot 3") { controller.snapshot?.deviceIndex == 3 && isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testUnpairThenPairOnANewSlot() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.repair(toSlot: 5, announceUnpair: true)
        await eventually("moved to slot 5") { controller.snapshot?.deviceIndex == 5 && isConnected(controller) }
        XCTAssertEqual(mouse.diverted, expectedDiversion)
    }

    func testUnpairDropsTheSessionAndReleasesHeldButtons() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        var events: [ButtonEvent] = []
        controller.onButtonEvent = { events.append($0) }
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.hold([KnownControl.back])
        await eventually("pressed") { events.count == 1 }
        mouse.unpair()
        await eventually("waiting") { controller.state == .waitingForDevice }
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(events.last, ButtonEvent(cid: KnownControl.back, phase: .release))
    }

    func testSecondLiveMXVerticalDoesNotStealTheSession() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        mouse.addDevice(slot: 4, name: "MX Vertical", wirelessPID: MXVertical.wirelessProductID)
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }
        let slot = controller.snapshot?.deviceIndex

        // A link-up from the other mouse while ours still answers.
        mouse.onReport?(HIDPPMessage(reportID: .short, deviceIndex: slot == 2 ? 4 : 2, subID: 0x41, address: 0x04, parameters: [0x00, 0x7B, 0x40]).bytes)
        await pause(0.2)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.deviceIndex, slot)
        XCTAssertTrue(isConnected(controller))
    }
}
