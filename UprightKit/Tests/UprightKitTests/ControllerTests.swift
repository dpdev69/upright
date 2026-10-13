import XCTest
@testable import UprightKit

@MainActor
final class ControllerTests: XCTestCase {
    private func makeController(_ mouse: SimulatedMXVertical, kind: TransportKind) -> MXVerticalController {
        let controller = MXVerticalController(transport: mouse, kind: kind)
        controller.probeTimeout = 0.2
        controller.reconnectDelay = 0
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

    private func isConnected(_ controller: MXVerticalController) -> Bool {
        if case .connected = controller.state { return true }
        return false
    }

    private let defaultDiversion = ButtonMappings.defaults.divertedControls(accessibilityGranted: true)

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
        XCTAssertEqual(snapshot.features.map(\.featureID), SimulatedMXVertical.features)
        XCTAssertEqual(mouse.diverted, [0x53, 0x56, 0xFD])
    }

    func testButtonEventsReachTheEngine() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)
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
        XCTAssertEqual(mouse.diverted, [0x53, 0x56, 0xFD])
        // Receiver notifications were enabled via HID++ 1.0 register 0x00.
        XCTAssertTrue(mouse.sentReports.contains { Array($0.prefix(7)) == [0x10, 0xFF, 0x80, 0x00, 0x00, 0x09, 0x00] })
    }

    func testReceiverIgnoresOtherDevices() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1), name: "MX Keys")
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.start()
        await eventually("waiting") { controller.state == .waitingForDevice }
        XCTAssertNil(controller.snapshot)
    }

    func testSleepingMouseIsReconfiguredWhenItWakes() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.goToSleep()
        await eventually("asleep") {
            if case .asleep = controller.state { return true }
            return false
        }

        mouse.wakeUp(clearingDiversion: true)
        XCTAssertTrue(mouse.diverted.isEmpty)
        await eventually("re-diverted after wake") { mouse.diverted == [0x53, 0x56, 0xFD] }
        await eventually("connected again") { isConnected(controller) }
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
        XCTAssertEqual(mouse.diverted, [0x53, 0x56, 0xFD])
    }

    func testWirelessStatusReconnectTriggersReapply() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.bluetooth))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.reportReconnect()
        await eventually("re-diverted") { mouse.diverted == [0x53, 0x56, 0xFD] }
    }

    func testRefreshAfterMacWakeReappliesDiversion() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        mouse.reportReconnect()
        controller.refresh()
        await eventually("re-diverted") { mouse.diverted == [0x53, 0x56, 0xFD] }
    }

    func testShutdownHandsButtonsBackToTheMouse() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion(defaultDiversion)
        controller.start()
        await eventually("connected") { isConnected(controller) }

        controller.shutdown()
        XCTAssertTrue(mouse.diverted.isEmpty)
    }

    func testTransportRemovalReleasesHeldButtons() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        let performer = RecordingPerformer()
        let engine = RemapEngine(mappings: .defaults, performer: performer)
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
}
