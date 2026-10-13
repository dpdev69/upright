import XCTest
@testable import UprightKit

final class DeviceFeatureParsingTests: XCTestCase {
    private func bytes(_ values: [UInt16]) -> [UInt8] { values.flatMap(\.bigEndianBytes) }

    func testDPIListWithRange() {
        let parsed = DPIInfo.parseList(bytes([400, 0xE000 | 50, 4000, 0, 0]))
        XCTAssertEqual(parsed.step, 50)
        XCTAssertEqual(parsed.values.first, 400)
        XCTAssertEqual(parsed.values.last, 4000)
        XCTAssertEqual(parsed.values.count, 73)
        XCTAssertEqual(parsed.values[1], 450)
    }

    func testDPIListOfDiscreteValuesStopsAtZero() {
        let parsed = DPIInfo.parseList(bytes([800, 400, 1600, 0, 3200]))
        XCTAssertEqual(parsed.values, [400, 800, 1600])
        XCTAssertNil(parsed.step)
    }

    func testDPIListMixingValuesAndRanges() {
        let parsed = DPIInfo.parseList(bytes([200, 0xE000 | 100, 600, 1000, 0xE000 | 500, 2000]))
        XCTAssertEqual(parsed.values, [200, 300, 400, 500, 600, 1000, 1500, 2000])
    }

    func testDPIListIgnoresMalformedRanges() {
        XCTAssertEqual(DPIInfo.parseList(bytes([0xE000 | 50, 4000])).values, [])
        XCTAssertEqual(DPIInfo.parseList(bytes([400, 0xE000, 4000])).values, [400])
        XCTAssertEqual(DPIInfo.parseList([0x01]).values, [])
    }

    func testNearestAndPresets() {
        let info = DPIInfo(current: 1000, defaultValue: 1000, supported: Array(stride(from: 400, through: 4000, by: 50)), step: 50)
        XCTAssertEqual(info.nearest(to: 1234), 1250)
        XCTAssertEqual(info.nearest(to: 1225), 1200)
        XCTAssertEqual(info.nearest(to: 50), 400)
        XCTAssertEqual(info.nearest(to: 9000), 4000)
        XCTAssertEqual(info.suggestedPresets(), [400, 1600, 2800, 4000])
        XCTAssertEqual(info.nextPreset(after: 1000), 1600)
        XCTAssertEqual(info.nextPreset(after: 4000), 400)
        XCTAssertEqual(info.nextPreset(after: 1000, presets: [3210, 790, 1610]), 1600)
        XCTAssertEqual(info.nextPreset(after: 3200, presets: [3210, 790, 1610]), 800)

        let few = DPIInfo(current: 800, defaultValue: 800, supported: [400, 800, 1600])
        XCTAssertEqual(few.suggestedPresets(), [400, 800, 1600])
        XCTAssertEqual(few.nextPreset(after: 800), 1600)

        let unknown = DPIInfo(current: 1000, defaultValue: 1000, supported: [])
        XCTAssertEqual(unknown.nearest(to: 1234), 1234)
        XCTAssertEqual(unknown.nextPreset(after: 1000), 1000)
    }

    func testFirmwareParsing() {
        let main = FirmwareInfo(fwInfoParameters: [0x00] + Array("RBM".utf8) + [0x14, 0x00, 0x00, 0x15, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(main, FirmwareInfo(kind: .firmware, name: "RBM", version: "14.00.B0015"))
        XCTAssertEqual(main.displayString, "RBM 14.00.B0015")

        let bootloader = FirmwareInfo(fwInfoParameters: [0x01] + Array("BOT".utf8) + [0x12, 0x03, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(bootloader.displayString, "BOT 12.03")
        XCTAssertEqual(bootloader.kind, .bootloader)

        let hardware = FirmwareInfo(fwInfoParameters: [0x02, 0x48] + Array(repeating: 0, count: 14))
        XCTAssertEqual(hardware, FirmwareInfo(kind: .hardware, name: "", version: "72"))
        XCTAssertEqual(FirmwareInfo(fwInfoParameters: Array(repeating: 0x07, count: 16)).kind, .other)
    }

    func testRawXYDecodingAndReportingFlags() {
        let delta = ReprogControls.rawXYDelta(fromEventParameters: [0xFF, 0xFB, 0x01, 0x2C] + Array(repeating: 0, count: 12))
        XCTAssertEqual(delta.dx, -5)
        XCTAssertEqual(delta.dy, 300)

        XCTAssertEqual(ReprogControls.reportingFlags(diverted: true, rawXY: nil).rawValue, 0x03)
        XCTAssertEqual(ReprogControls.reportingFlags(diverted: false, rawXY: nil).rawValue, 0x02)
        XCTAssertEqual(ReprogControls.reportingFlags(diverted: true, rawXY: true).rawValue, 0x33)
        XCTAssertEqual(ReprogControls.reportingFlags(diverted: true, rawXY: false).rawValue, 0x23)
        // Raw XY needs diversion; un-diverting also clears it.
        XCTAssertEqual(ReprogControls.reportingFlags(diverted: false, rawXY: true).rawValue, 0x22)
        let undivert = ReprogControls.undivertMessage(deviceIndex: 1, featureIndex: 4, cid: 0xFD, softwareID: 0x0A, clearRawXY: true)
        XCTAssertEqual(Array(undivert.bytes.prefix(7)), [0x11, 0x01, 0x04, 0x3A, 0x00, 0xFD, 0x22])

        XCTAssertTrue(ControlInfo(cid: 0xFD, taskID: 0, flags: .divertable, additionalFlags: 0x01).supportsRawXY)
        XCTAssertFalse(ControlInfo(cid: 0xFD, taskID: 0, flags: .divertable).supportsRawXY)
    }

    func testChangeHostMessage() {
        let message = DeviceFeatures.changeHostMessage(deviceIndex: 0xFF, featureIndex: 8, host: 2, softwareID: 0x0A)
        XCTAssertEqual(Array(message.bytes.prefix(5)), [0x11, 0xFF, 0x08, 0x1A, 0x02])
    }

    func testSwitchHostActionCodingAndValidation() throws {
        let action = ButtonAction.device(.switchHost(2))
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"device":{"_0":{"switchHost":{"_0":2}}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(ButtonAction.self, from: data), action)
        // Existing cases keep their encoding.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(DeviceAction.cycleDPI), as: UTF8.self), #"{"cycleDPI":{}}"#)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(DeviceAction.setDPI(800)), as: UTF8.self), #"{"setDPI":{"_0":800}}"#)

        XCTAssertTrue(DeviceAction.switchHost(1).isValid)
        XCTAssertTrue(DeviceAction.switchHost(3).isValid)
        XCTAssertFalse(DeviceAction.switchHost(0).isValid)
        XCTAssertFalse(DeviceAction.switchHost(4).isValid)
        XCTAssertEqual(DeviceAction.switchHost(2).title, "Switch to Computer 2")
    }
}

@MainActor
final class DeviceFeatureControllerTests: XCTestCase {
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

    private func connected(_ mouse: SimulatedMXVertical, kind: TransportKind = .direct(.usb)) async -> MXVerticalController {
        let controller = makeController(mouse, kind: kind)
        controller.start()
        await eventually("connected") { isConnected(controller) }
        return controller
    }

    // MARK: Device information

    func testSnapshotCarriesFirmwareSerialDPIAndHosts() async throws {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        let snapshot = try XCTUnwrap(controller.snapshot)

        XCTAssertEqual(snapshot.firmware.map(\.displayString), ["RBM 14.00.B0015", "BOT 12.03", "72"])
        XCTAssertEqual(snapshot.firmwareVersion, "RBM 14.00.B0015")
        XCTAssertEqual(snapshot.serialNumber, SimulatedMXVertical.serialNumber)

        let dpi = try XCTUnwrap(snapshot.dpi)
        XCTAssertEqual(dpi.current, 1000)
        XCTAssertEqual(dpi.defaultValue, 1000)
        XCTAssertEqual(dpi.minimum, 400)
        XCTAssertEqual(dpi.maximum, 4000)
        XCTAssertEqual(dpi.step, 50)

        XCTAssertEqual(snapshot.hosts, HostInfo(count: 3, current: 0, names: SimulatedMXVertical.hostNames))
        XCTAssertEqual(snapshot.hosts?.name(at: 2), "Gaming PC with a very long host name")
        XCTAssertNil(snapshot.hosts?.name(at: 7))
    }

    func testMissingFeaturesDegradeGracefully() async throws {
        let mouse = SimulatedMXVertical(mode: .direct, features: SimulatedMXVertical.baseFeatures)
        var logs: [String] = []
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.onLog = { logs.append($0) }
        controller.setDPI(1600)
        controller.start()
        await eventually("connected") { isConnected(controller) }
        let snapshot = try XCTUnwrap(controller.snapshot)
        XCTAssertNil(snapshot.dpi)
        XCTAssertNil(snapshot.hosts)
        XCTAssertNil(snapshot.serialNumber)
        XCTAssertEqual(snapshot.firmware, [])

        controller.cycleDPI()
        controller.switchToHost(1)
        controller.refreshDeviceInfo()
        await controller.waitUntilIdle()
        XCTAssertTrue(isConnected(controller))
        XCTAssertTrue(mouse.hostSwitches.isEmpty)
        XCTAssertFalse(logs.contains { $0.hasPrefix("Could not") })
    }

    // MARK: Pointer speed

    func testDesiredDPIIsAppliedWhenTheMouseConnects() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 2))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.setDPI(800)
        controller.start()
        await eventually("connected") { isConnected(controller) }
        await eventually("speed applied") { mouse.dpi == 800 }
        XCTAssertEqual(controller.snapshot?.dpi?.current, 800)
    }

    func testSetDPISnapsAndSurvivesReconnect() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse, kind: .direct(.bluetooth))
        var changes: [Int?] = []
        controller.onDesiredDPIChange = { changes.append($0) }

        controller.setDPI(1234)
        XCTAssertEqual(controller.desiredDPI, 1250)
        await eventually("speed applied") { mouse.dpi == 1250 }
        await eventually("snapshot updated") { controller.snapshot?.dpi?.current == 1250 }
        XCTAssertEqual(changes, [1250])

        // The mouse reconnects and falls back to its default speed.
        mouse.reportReconnect()
        XCTAssertEqual(mouse.dpi, SimulatedMXVertical.defaultDPI)
        await eventually("speed re-applied") { mouse.dpi == 1250 }

        // So does a Mac wake.
        mouse.forgetDiversion()
        controller.refresh()
        await eventually("speed re-applied after wake") { mouse.dpi == 1250 }

        controller.setDesiredDPI(nil)
        XCTAssertNil(controller.desiredDPI)
        XCTAssertEqual(changes, [1250, nil])
    }

    func testCycleDPIStepsThroughPresets() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)

        controller.cycleDPI(presets: [800, 1600, 3200])
        controller.cycleDPI(presets: [800, 1600, 3200])
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 3200, "two quick presses both count")
        controller.cycleDPI(presets: [800, 1600, 3200])
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 800)
        XCTAssertEqual(controller.desiredDPI, 800)

        // Without presets: four evenly spaced speeds (400, 1600, 2800, 4000).
        controller.cycleDPI()
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 1600)
        XCTAssertEqual(controller.snapshot?.dpi?.current, 1600)
    }

    func testCycleStartsFromASpeedChangedOnTheMouse() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        mouse.setDPINatively(2000)
        controller.cycleDPI(presets: [800, 1600, 3200])
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 3200)
    }

    func testRefreshDPIAdoptsASpeedChangedOnTheMouse() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        controller.setDPI(1600)
        await controller.waitUntilIdle()
        var changes: [Int?] = []
        controller.onDesiredDPIChange = { changes.append($0) }

        // The top button isn't diverted, so the firmware cycles the speed without telling us.
        mouse.setDPINatively(2400)
        controller.refreshDPI()
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.dpi?.current, 2400)
        XCTAssertEqual(controller.desiredDPI, 2400)
        XCTAssertEqual(changes, [2400])

        // Without a desired speed, refreshing only reads.
        controller.setDesiredDPI(nil)
        mouse.setDPINatively(800)
        controller.refreshDeviceInfo()
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.dpi?.current, 800)
        XCTAssertNil(controller.desiredDPI)
    }

    func testReconnectKeepsASpeedChangedOnTheMouse() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse, kind: .direct(.bluetooth))
        controller.setDPI(1600)
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 1600)
        var changes: [Int?] = []
        controller.onDesiredDPIChange = { changes.append($0) }

        // The top button changes the speed, then the Mac wakes: the mouse's speed is kept.
        mouse.setDPINatively(2400)
        controller.refresh()
        await eventually("speed adopted after wake") { controller.desiredDPI == 2400 }
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 2400)
        XCTAssertEqual(controller.snapshot?.dpi?.current, 2400)

        // Same when the mouse reconnects without forgetting its speed.
        mouse.setDPINatively(3200)
        mouse.wakeUp(clearingDiversion: false, announce: false, reportReconnect: true)
        await eventually("speed adopted after reconnect") { controller.desiredDPI == 3200 }
        await controller.waitUntilIdle()
        XCTAssertEqual(mouse.dpi, 3200)
        XCTAssertEqual(changes, [2400, 3200])

        // A mouse that comes back at its default speed forgot ours: it is re-applied.
        mouse.reportReconnect()
        XCTAssertEqual(mouse.dpi, SimulatedMXVertical.defaultDPI)
        await eventually("speed re-applied") { mouse.dpi == 3200 }
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.desiredDPI, 3200)
        XCTAssertEqual(changes, [2400, 3200], "the default speed isn't adopted")
    }

    func testSpeedSetByTheAppIsNotRevertedByAReconfiguration() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        controller.setDPI(1600)
        await controller.waitUntilIdle()

        // The app picks a new speed while the Mac-wake reconfiguration is re-diverting buttons:
        // the mouse still reports the old (non-default) speed, which must not be adopted.
        mouse.latency = 0.03
        controller.refresh()
        await pause(0.05)
        controller.setDPI(800)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.desiredDPI, 800)
        XCTAssertEqual(mouse.dpi, 800)
    }

    func testRefreshDPIDoesNotOverwriteASpeedSetDuringTheRead() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        controller.setDPI(1600)
        await controller.waitUntilIdle()

        mouse.setDPINatively(2400)
        mouse.latency = 0.1
        controller.refreshDPI()
        await pause(0.03)
        // Chosen in the app while the read of the old speed is still in flight.
        controller.setDPI(800)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.desiredDPI, 800)
        XCTAssertEqual(mouse.dpi, 800)
    }

    // MARK: Easy-Switch

    func testSwitchToHostIsFireAndForget() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1))
        let controller = makeController(mouse, kind: .receiver(.unifying))
        controller.retryBaseDelay = 30
        controller.retryMaxDelay = 30
        var logs: [String] = []
        controller.onLog = { logs.append($0) }
        controller.start()
        await eventually("connected") { isConnected(controller) }

        controller.switchToHost(0) // already there
        controller.switchToHost(3) // no such channel
        XCTAssertEqual(mouse.hostSwitches, [])

        controller.switchToHost(1)
        await eventually("switched") { mouse.hostSwitches == [1] }
        await eventually("asleep after leaving") {
            if case .asleep = controller.state { return true }
            return false
        }
        XCTAssertFalse(logs.contains { $0.hasPrefix("Could not") })
    }

    func testHostsAreRereadOnReconfigure() async {
        let mouse = SimulatedMXVertical(mode: .receiver(slot: 1))
        let controller = await connected(mouse, kind: .receiver(.unifying))
        controller.switchToHost(2)
        await eventually("switched") { mouse.hostSwitches == [2] }
        await eventually("asleep") {
            if case .asleep = controller.state { return true }
            return false
        }
        // Coming back on channel 3 (as the simulator remembers it).
        mouse.wakeUp()
        await eventually("connected again") { isConnected(controller) }
        await eventually("current channel updated") { controller.snapshot?.hosts?.current == 2 }
    }

    // MARK: Raw XY

    func testRawXYDivertsAndReportsMovement() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        var deltas: [[Int]] = []
        var events: [ButtonEvent] = []
        controller.onPointerDelta = { deltas.append([$0, $1]) }
        controller.onButtonEvent = { events.append($0) }

        controller.setDesiredRawXY([KnownControl.dpiSwitch])
        await eventually("raw XY on") { mouse.rawXY == [KnownControl.dpiSwitch] }
        XCTAssertEqual(mouse.diverted, [KnownControl.dpiSwitch], "raw XY implies diversion")

        mouse.hold([KnownControl.dpiSwitch])
        mouse.move(dx: -5, dy: 300)
        mouse.move(dx: 7, dy: -2)
        mouse.hold([])
        await eventually("events") { events.count == 2 && deltas.count == 2 }
        XCTAssertEqual(deltas, [[-5, 300], [7, -2]])
        XCTAssertEqual(events, [ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press), ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release)])

        controller.setDesiredRawXY([])
        await eventually("raw XY off") { mouse.rawXY.isEmpty && mouse.diverted.isEmpty }
    }

    func testRawXYIsReappliedAfterReconnectAndClearedOnShutdown() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = makeController(mouse, kind: .direct(.usb))
        controller.setDesiredDiversion([KnownControl.back])
        controller.setDesiredRawXY([KnownControl.dpiSwitch])
        controller.start()
        await eventually("connected") { isConnected(controller) }
        XCTAssertEqual(mouse.rawXY, [KnownControl.dpiSwitch])
        XCTAssertEqual(mouse.diverted, [KnownControl.back, KnownControl.dpiSwitch])

        mouse.reportReconnect()
        XCTAssertTrue(mouse.rawXY.isEmpty)
        await eventually("raw XY restored") { mouse.rawXY == [KnownControl.dpiSwitch] }

        controller.shutdown()
        XCTAssertTrue(mouse.rawXY.isEmpty)
        XCTAssertTrue(mouse.diverted.isEmpty)
    }

    func testRawXYOnAControlWithoutTheCapabilityOnlyDiverts() async {
        let mouse = SimulatedMXVertical(mode: .direct)
        let controller = await connected(mouse)
        var logs: [String] = []
        controller.onLog = { logs.append($0) }

        controller.setDesiredRawXY([KnownControl.middleClick])
        await eventually("diverted") { mouse.diverted == [KnownControl.middleClick] }
        await controller.waitUntilIdle()
        XCTAssertTrue(mouse.rawXY.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("without raw XY support") && $0.contains("0x0052") })
        XCTAssertFalse(logs.contains { $0.contains("refused") })
    }
}
