import XCTest
@testable import UprightKit

final class DeviceFeatureParsingTests: XCTestCase {
    private func bytes(_ values: [UInt16]) -> [UInt8] { values.flatMap(\.bigEndianBytes) }
    /// Top three bits set marks a step in getSensorDpiList. Typed explicitly because Swift 6.0
    /// infers `0xE000 | 50` as Int inside an array literal argument.
    private let stepFlag: UInt16 = 0xE000

    func testDPIListWithRange() {
        let parsed = DPIInfo.parseList(bytes([400, stepFlag | 50, 4000, 0, 0]))
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
        let parsed = DPIInfo.parseList(bytes([200, stepFlag | 100, 600, 1000, stepFlag | 500, 2000]))
        XCTAssertEqual(parsed.values, [200, 300, 400, 500, 600, 1000, 1500, 2000])
    }

    func testDPIListIgnoresMalformedRanges() {
        XCTAssertEqual(DPIInfo.parseList(bytes([stepFlag | 50, 4000])).values, [])
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

    func testSnapshotDefaultsForFixturesWithoutIdentity() {
        let snapshot = DeviceSnapshot(name: "MX Vertical", connection: .usb, deviceIndex: 0xFF, protocolVersion: "4.5",
                                      features: [], controls: [], battery: nil)
        XCTAssertNil(snapshot.identity)
        XCTAssertEqual(snapshot.address, .unassigned)
        XCTAssertEqual(snapshot.reprogVersion, 0)
        XCTAssertEqual(snapshot.modelKey, .mxVertical)

        let master = DeviceIdentity(name: "MX Master 3S", kind: .mouse, modelIDs: ModelIDs(bluetoothLE: 0xB034))
        let identified = DeviceSnapshot(name: "MX Master 3S", connection: .bolt, deviceIndex: 2, protocolVersion: "4.5",
                                        features: [], controls: [], battery: nil, identity: master,
                                        address: DeviceAddress(link: 2, index: 2), reprogVersion: 5)
        XCTAssertEqual(identified.modelKey, ModelKey(productID: 0xB034))
        XCTAssertEqual(identified.address, DeviceAddress(link: 2, index: 2))
    }

    func testConfigurableControlsNeverIncludePrimaryClicks() {
        let flags: ControlFlags = [.mouseButton, .reprogrammable, .divertable]
        XCTAssertFalse(ControlInfo(cid: KnownControl.leftClick, taskID: 0, flags: flags).isConfigurable)
        XCTAssertFalse(ControlInfo(cid: KnownControl.rightClick, taskID: 0, flags: flags).isConfigurable)
        XCTAssertTrue(ControlInfo(cid: KnownControl.back, taskID: 0, flags: flags).isConfigurable)
        XCTAssertTrue(ControlInfo(cid: KnownControl.back, taskID: 0, flags: flags).isMouseButton)
        XCTAssertFalse(ControlInfo(cid: 0x00D1, taskID: 0, flags: [.nonStandard, .divertable]).isMouseButton)
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

/// `DeviceSession` on its own, against the simulator's profiles: identification, the capability
/// gate, address stamping and the raw-XY quirk.
@MainActor
final class DeviceSessionTests: XCTestCase {
    private func makeSession(
        _ transport: SimulatedHIDPPTransport,
        at index: UInt8,
        link: UInt32 = 7,
        transportPID: UInt16? = nil,
        fallbackName: String? = nil,
        kindHint: DeviceKind? = nil
    ) -> DeviceSession {
        let client = HIDPPClient(transport: transport)
        client.defaultTimeout = 0.3
        client.busyRetryDelay = 0.01
        let session = DeviceSession(
            device: HIDPPDevice(client: client, index: index),
            connection: transport.transportKind.connection,
            address: DeviceAddress(link: link, index: index),
            transportPID: transportPID,
            fallbackName: fallbackName,
            kindHint: kindHint
        )
        client.onUnsolicited = { [weak session] message in
            MainActorDelivery.run { _ = session?.handle(message) }
        }
        return session
    }

    /// Runs `start()` expecting the capability gate to refuse the device.
    private func unsupported(
        _ session: DeviceSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> (reason: UnsupportedReason, partial: DeviceSnapshot?)? {
        do {
            let snapshot = try await session.start()
            XCTFail("expected unsupportedDevice, connected to \(snapshot.name)", file: file, line: line)
        } catch HIDPPError.unsupportedDevice(let reason, let partial) {
            return (reason, partial)
        } catch {
            XCTFail("expected unsupportedDevice, got \(error)", file: file, line: line)
        }
        return nil
    }

    /// (feature ID, function) of every HID++ 2.0 request sent to `index`, in order, resolving
    /// feature indices through `profile`. Root getFeature lookups are left out.
    private func requests(_ transport: SimulatedHIDPPTransport, to index: UInt8, profile: SimulatedDeviceProfile) -> [[UInt16]] {
        transport.sentReports.compactMap { bytes in
            guard let message = HIDPPMessage(bytes: bytes), message.deviceIndex == index,
                  Int(message.featureIndex) < profile.features.count else { return nil }
            let feature = profile.features[Int(message.featureIndex)].id
            if feature == 0x0000, message.function == 0 { return nil }
            return [feature, UInt16(message.function)]
        }
    }

    private static var unknownKindVertical: SimulatedDeviceProfile {
        var profile = DeviceProfiles.mxVertical
        profile.kind = .unknown
        return profile
    }

    // MARK: Identity

    func testSnapshotCarriesIdentityAddressAndReprogVersion() async throws {
        let mouse = SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .bluetooth)
        let session = makeSession(mouse, at: 0xFF, transportPID: 0xB020)
        let snapshot = try await session.start()
        let address = DeviceAddress(link: 7, index: 0xFF)

        XCTAssertEqual(session.address, address)
        XCTAssertEqual(snapshot.address, address)
        XCTAssertEqual(snapshot.connection, .bluetooth)
        XCTAssertEqual(snapshot.reprogVersion, 4)
        XCTAssertEqual(snapshot.name, "MX Vertical Advanced Ergonomic Mouse")
        XCTAssertEqual(snapshot.serialNumber, "DEMO-0001")
        XCTAssertEqual(snapshot.modelKey, .mxVertical)

        let identity = try XCTUnwrap(snapshot.identity)
        XCTAssertEqual(identity.name, snapshot.name)
        XCTAssertEqual(identity.kind, .mouse)
        XCTAssertEqual(identity.unitID, 0x1A2B_3C4D)
        XCTAssertEqual(identity.serialNumber, "DEMO-0001")
        XCTAssertEqual(identity.modelIDs, ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A))
        XCTAssertEqual(identity.transportPID, 0xB020)
        XCTAssertEqual(identity.model, .mxVertical)
        XCTAssertEqual(identity.deviceID(at: address), .unit(0x1A2B_3C4D, model: .mxVertical))

        // Everything the single-mouse snapshot had is still read.
        XCTAssertEqual(snapshot.configurableControls.map(\.cid), [0x52, 0x53, 0x56, 0xFD])
        XCTAssertEqual(snapshot.firmware.map(\.kind), [.bootloader, .firmware, .other])
        XCTAssertEqual(snapshot.battery?.percentage, 50)
        XCTAssertEqual(snapshot.dpi?.current, 1000)
        XCTAssertEqual(snapshot.hosts?.count, 3)
        XCTAssertEqual(session.snapshot, snapshot)
    }

    func testStartReadsInOrderAndWritesNothing() async throws {
        let profile = DeviceProfiles.mxVertical
        let mouse = SimulatedDirect(profile: profile)
        _ = try await makeSession(mouse, at: 0xFF).start()
        let sent = requests(mouse, to: 0xFF, profile: profile)

        // Protocol, feature table, name, kind, IDs and serial, controls, battery, speed, hosts.
        let milestones: [[UInt16]] = [
            [0x0000, 1], [0x0001, 0], [0x0005, 0], [0x0005, 2], [0x0003, 0], [0x0003, 2],
            [0x1B04, 0], [0x1000, 0], [0x2201, 1], [0x1814, 0],
        ]
        let positions = milestones.map { sent.firstIndex(of: $0) }
        XCTAssertFalse(positions.contains(nil), "every milestone is read: \(sent)")
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "read in order: \(sent)")

        let reads: Set<[UInt16]> = [
            [0x0000, 1], [0x0001, 0], [0x0001, 1], [0x0005, 0], [0x0005, 1], [0x0005, 2], [0x0003, 0], [0x0003, 1],
            [0x0003, 2], [0x1B04, 0], [0x1B04, 1], [0x1000, 0], [0x2201, 1], [0x2201, 2], [0x1814, 0], [0x1815, 0],
            [0x1815, 1], [0x1815, 3],
        ]
        XCTAssertEqual(Set(sent).subtracting(reads), [], "only reads")
        XCTAssertTrue(mouse.diverted.isEmpty)
        XCTAssertEqual(mouse.dpi, 1000)
        XCTAssertTrue(mouse.hostSwitches.isEmpty)
    }

    func testBoltMouseIdentifiesAsItsOwnModel() async throws {
        let receiver = SimulatedReceiver.bolt([2: DeviceProfiles.mxMaster3S])
        let session = makeSession(receiver, at: 2, link: 3, transportPID: 0xB034)
        let snapshot = try await session.start()

        XCTAssertEqual(snapshot.connection, .bolt)
        XCTAssertEqual(snapshot.deviceIndex, 2)
        XCTAssertEqual(snapshot.address, DeviceAddress(link: 3, index: 2))
        XCTAssertEqual(snapshot.reprogVersion, 5)
        XCTAssertEqual(snapshot.modelKey, ModelKey(productID: 0xB034))
        XCTAssertEqual(snapshot.identity?.unitID, 0x2A2B_3C4D)
        XCTAssertEqual(snapshot.identity?.kind, .mouse)
        XCTAssertEqual(snapshot.battery?.percentage, 25)
        XCTAssertEqual(snapshot.configurableControls.map(\.cid), [0x52, 0x53, 0x56, 0xC3, 0xC4])
    }

    func testIdenticalMiceShareTheirModelButNotTheirDeviceID() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxVerticalSecondUnit])
        let first = try await makeSession(receiver, at: 1, transportPID: 0x407B).start()
        let second = try await makeSession(receiver, at: 2, transportPID: 0x407B).start()
        let firstID = try XCTUnwrap(first.identity?.deviceID(at: first.address))
        let secondID = try XCTUnwrap(second.identity?.deviceID(at: second.address))

        XCTAssertEqual(first.modelKey, .mxVertical)
        XCTAssertEqual(second.modelKey, .mxVertical)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(firstID.isStable)
        XCTAssertTrue(secondID.isStable)
        XCTAssertNotEqual(first.address, second.address)
    }

    func testMouseWithoutUnitIDOrSerialGetsATransientID() async throws {
        let receiver = SimulatedReceiver.unifying([4: DeviceProfiles.mouseWithoutUnitID])
        let snapshot = try await makeSession(receiver, at: 4, link: 9, transportPID: 0x4082).start()
        let identity = try XCTUnwrap(snapshot.identity)

        XCTAssertNil(identity.unitID)
        XCTAssertNil(identity.serialNumber)
        XCTAssertEqual(identity.deviceID(at: snapshot.address), .transient(DeviceAddress(link: 9, index: 4)))
        XCTAssertFalse(identity.deviceID(at: snapshot.address).isStable)
        XCTAssertEqual(snapshot.modelKey, ModelKey(productID: 0xB023), "the model is still known")
    }

    func testNameFallsBackToTheGivenNameThenLogitechMouse() async throws {
        var nameless = DeviceProfiles.mxVertical
        nameless.features.removeAll { $0.id == 0x0005 }
        let named = try await makeSession(SimulatedDirect(profile: nameless), at: 0xFF, fallbackName: "MX Vertical").start()
        XCTAssertEqual(named.name, "MX Vertical")
        XCTAssertEqual(named.identity?.name, "MX Vertical")
        XCTAssertEqual(named.identity?.kind, .unknown, "no 0x0005, no kind")
        XCTAssertEqual(named.modelKey, .mxVertical, "0x0003 still keys the model")

        let unnamed = try await makeSession(SimulatedDirect(profile: nameless), at: 0xFF, fallbackName: "  ").start()
        XCTAssertEqual(unnamed.name, DeviceSession.defaultName)
        XCTAssertEqual(DeviceSession.defaultName, "Logitech mouse")

        let empty = try await makeSession(SimulatedDirect(profile: DeviceProfiles.mxVertical.named("")), at: 0xFF).start()
        XCTAssertEqual(empty.name, "Logitech mouse")
        XCTAssertEqual(empty.identity?.kind, .mouse)
    }

    func testTrackballAndBudgetMouseAreServedWithoutTheirPrimaryClicks() async throws {
        let ergo = try await makeSession(SimulatedReceiver.unifying([1: DeviceProfiles.mxErgo]), at: 1).start()
        XCTAssertEqual(ergo.identity?.kind, .trackball)
        XCTAssertFalse(ergo.configurableControls.isEmpty)

        // The M185 flags Left and Right as divertable; they are never offered.
        let m185 = try await makeSession(SimulatedReceiver.nano([1: DeviceProfiles.m185]), at: 1, transportPID: 0x4055).start()
        XCTAssertEqual(m185.connection, .nano)
        XCTAssertEqual(m185.configurableControls.map(\.cid), [0x52])
        XCTAssertNil(m185.dpi)
    }

    // MARK: Capability gate

    func testKeyboardIsUnsupportedBeforeItsControlsAreRead() async throws {
        let receiver = SimulatedReceiver.unifying([3: DeviceProfiles.mxKeys])
        let session = makeSession(receiver, at: 3, transportPID: 0x408A)
        let outcome = await unsupported(session)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.reason, .notAPointer(.keyboard))
        let partial = try XCTUnwrap(result.partial)
        XCTAssertEqual(partial.name, "MX Keys Wireless Keyboard")
        XCTAssertEqual(partial.address, DeviceAddress(link: 7, index: 3))
        XCTAssertEqual(partial.identity?.kind, .keyboard)
        XCTAssertEqual(partial.identity?.unitID, 0x8A2B_3C4D)
        XCTAssertFalse(partial.features.isEmpty)
        XCTAssertTrue(partial.controls.isEmpty)
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(receiver.requestCount(feature: 0x1B04, slot: 3), 0, "the gate stops before the control table")
        XCTAssertEqual(receiver.setReportingCount(slot: 3), 0)
    }

    func testHIDPP10DeviceIsUnsupported() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.m510HIDPP10])
        let session = makeSession(receiver, at: 1, transportPID: 0x1025, fallbackName: "M510", kindHint: .mouse)
        let outcome = await unsupported(session)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.reason, .hidpp10(major: 1, minor: 0))
        let partial = try XCTUnwrap(result.partial)
        XCTAssertEqual(partial.protocolVersion, "1.0")
        XCTAssertEqual(partial.name, "M510")
        XCTAssertEqual(partial.identity?.kind, .mouse)
        XCTAssertEqual(partial.identity?.transportPID, 0x1025)
        XCTAssertEqual(receiver.requestCount(feature: 0x0001), 0, "nothing else is asked")
    }

    func testMouseWithoutReprogControlsIsUnsupported() async throws {
        let mouse = SimulatedDirect(profile: DeviceProfiles.g502Lightspeed)
        let outcome = await unsupported(makeSession(mouse, at: 0xFF, transportPID: 0xC08D))
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.reason, .noReprogControls)
        let partial = try XCTUnwrap(result.partial)
        XCTAssertEqual(partial.name, "G502 LIGHTSPEED Wireless Gaming Mouse")
        XCTAssertEqual(partial.identity?.kind, .mouse)
        XCTAssertEqual(partial.identity?.unitID, 0x9A2B_3C4D)
        XCTAssertNotNil(partial.feature(.batteryVoltage))
        XCTAssertNil(partial.feature(.reprogControlsV4))
    }

    func testPointerWithoutConfigurableControlsIsUnsupported() async throws {
        let touchpad = SimulatedDeviceProfile(
            name: "Test Touchpad",
            kind: .touchpad,
            wirelessPID: 0x4101,
            unitID: 0x0D0D_0001,
            modelIDs: ModelIDs(wireless: 0x4101),
            features: ([0x0000, 0x0001, 0x0003, 0x0005, 0x1B04] as [UInt16]).map { SimulatedDeviceProfile.Feature($0) },
            controls: [
                ControlInfo(cid: 0x50, taskID: 0x38, flags: [.mouseButton, .divertable]),
                ControlInfo(cid: 0x51, taskID: 0x39, flags: [.mouseButton, .divertable]),
                ControlInfo(cid: 0xD7, taskID: 0, flags: [.divertable, .virtual]),
            ]
        )
        let receiver = SimulatedReceiver.unifying([5: touchpad])
        let outcome = await unsupported(makeSession(receiver, at: 5))
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.reason, .noConfigurableControls)
        XCTAssertEqual(result.partial?.controls.map(\.cid), [0x50, 0x51, 0xD7])
        XCTAssertEqual(result.partial?.identity?.kind, .touchpad)
        XCTAssertEqual(receiver.setReportingCount(slot: 5), 0)
    }

    func testReportedKindWinsOverTheReceiversHint() async throws {
        let mouse = try await makeSession(SimulatedDirect(profile: DeviceProfiles.mxVertical), at: 0xFF, kindHint: .keyboard).start()
        XCTAssertEqual(mouse.identity?.kind, .mouse)

        let keyboard = makeSession(SimulatedReceiver.unifying([1: DeviceProfiles.mxKeys]), at: 1, kindHint: .mouse)
        let result = await unsupported(keyboard)
        XCTAssertEqual(result?.reason, .notAPointer(.keyboard))
    }

    func testKindHintDecidesWhenTheDeviceDoesNotReportItsKind() async throws {
        let hintedKeyboard = SimulatedReceiver.unifying([2: Self.unknownKindVertical])
        let result = await unsupported(makeSession(hintedKeyboard, at: 2, kindHint: .keyboard))
        XCTAssertEqual(result?.reason, .notAPointer(.keyboard))
        XCTAssertEqual(result?.partial?.identity?.kind, .keyboard)
        XCTAssertEqual(hintedKeyboard.requestCount(feature: 0x1B04, slot: 2), 0)

        let hintedMouse = try await makeSession(SimulatedReceiver.unifying([2: Self.unknownKindVertical]), at: 2, kindHint: .mouse).start()
        XCTAssertEqual(hintedMouse.identity?.kind, .mouse)

        // Neither: a control flagged as a mouse button makes it a pointer.
        let unhinted = try await makeSession(SimulatedReceiver.unifying([2: Self.unknownKindVertical]), at: 2, kindHint: .unknown).start()
        XCTAssertEqual(unhinted.identity?.kind, .unknown)
        XCTAssertEqual(unhinted.configurableControls.map(\.cid), [0x52, 0x53, 0x56, 0xFD])
    }

    func testWithoutAnyKindAMouseButtonIsRequired() async throws {
        var keys = DeviceProfiles.mxKeys
        keys.kind = .unknown
        let receiver = SimulatedReceiver.unifying([1: keys])
        let result = await unsupported(makeSession(receiver, at: 1))

        XCTAssertEqual(result?.reason, .notAPointer(.unknown))
        XCTAssertEqual(result?.partial?.controls.count, keys.controls.count, "read, but never written")
        XCTAssertFalse(result?.partial?.configurableControls.isEmpty ?? true)
        XCTAssertEqual(receiver.setReportingCount(slot: 1), 0)
    }

    func testSleepingDeviceIsUnreachableNotUnsupported() async {
        let direct = SimulatedDirect(profile: DeviceProfiles.mxVertical)
        direct.dropsRequests = true
        do {
            _ = try await makeSession(direct, at: 0xFF).start(pingTimeout: 0.1)
            XCTFail("expected a timeout")
        } catch let error as HIDPPError {
            XCTAssertEqual(error, .timeout)
            XCTAssertNil(error.unsupportedReason)
        } catch {
            XCTFail("unexpected \(error)")
        }

        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        receiver.goToSleep(slot: 1)
        do {
            _ = try await makeSession(receiver, at: 1).start(pingTimeout: 0.1)
            XCTFail("expected the receiver to report the slot unreachable")
        } catch let error as HIDPPError {
            XCTAssertTrue(error.meansDeviceUnreachable, "\(error)")
            XCTAssertNil(error.unsupportedReason)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Events

    func testEventsAreStampedWithTheSessionAddress() async throws {
        let receiver = SimulatedReceiver.unifying([3: DeviceProfiles.mxVertical])
        let session = makeSession(receiver, at: 3, link: 4)
        let address = DeviceAddress(link: 4, index: 3)
        var events: [ButtonEvent] = []
        var deltas: [PointerDelta] = []
        var legacyDeltas: [[Int]] = []
        session.onButtonEvent = { events.append($0) }
        session.onSourcedPointerDelta = { deltas.append($0) }
        session.onPointerDelta = { legacyDeltas.append([$0, $1]) }
        _ = try await session.start()
        try await session.applyDiversion([KnownControl.back], rawXY: [KnownControl.dpiSwitch])

        receiver.hold([KnownControl.dpiSwitch], slot: 3)
        receiver.move(dx: -5, dy: 300, slot: 3)
        receiver.hold([], slot: 3)
        receiver.hold([KnownControl.back], slot: 3)
        await eventually("three events") { events.count == 3 }
        session.releaseAll()

        XCTAssertEqual(events, [
            ButtonEvent(cid: KnownControl.dpiSwitch, phase: .press, source: address),
            ButtonEvent(cid: KnownControl.dpiSwitch, phase: .release, source: address),
            ButtonEvent(cid: KnownControl.back, phase: .press, source: address),
            ButtonEvent(cid: KnownControl.back, phase: .release, source: address),
        ])
        XCTAssertEqual(deltas, [PointerDelta(source: address, dx: -5, dy: 300)])
        XCTAssertEqual(legacyDeltas, [[-5, 300]])
    }

    func testLegacySessionStampsUnassigned() async throws {
        let mouse = SimulatedDirect(profile: DeviceProfiles.mxVertical)
        let client = HIDPPClient(transport: mouse)
        let session = DeviceSession(device: HIDPPDevice(client: client, index: 0xFF), connection: .usb)
        client.onUnsolicited = { [weak session] message in MainActorDelivery.run { _ = session?.handle(message) } }
        var events: [ButtonEvent] = []
        session.onButtonEvent = { events.append($0) }
        let snapshot = try await session.start()
        try await session.applyDiversion([KnownControl.back])
        mouse.hold([KnownControl.back])
        await eventually("pressed") { events.count == 1 }

        XCTAssertEqual(session.address, .unassigned)
        XCTAssertEqual(snapshot.address, .unassigned)
        XCTAssertEqual(events, [ButtonEvent(cid: KnownControl.back, phase: .press)])
    }

    func testFirstRawXYReportAfterAPressIsDroppedFromReprogV5() async throws {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let session = makeSession(receiver, at: 1)
        var events: [ButtonEvent] = []
        var deltas: [[Int]] = []
        var legacyDeltas: [[Int]] = []
        session.onButtonEvent = { events.append($0) }
        session.onSourcedPointerDelta = { deltas.append([$0.dx, $0.dy]) }
        session.onPointerDelta = { legacyDeltas.append([$0, $1]) }
        let snapshot = try await session.start()
        XCTAssertEqual(snapshot.reprogVersion, 5)
        try await session.applyDiversion([], rawXY: [KnownControl.gestureButton])
        XCTAssertEqual(session.rawXYControls, [KnownControl.gestureButton])

        for round in 0..<2 {
            receiver.hold([KnownControl.gestureButton], slot: 1)
            receiver.move(dx: 99, dy: -99, slot: 1)
            receiver.move(dx: round * 10 + 1, dy: 2, slot: 1)
            receiver.move(dx: round * 10 + 3, dy: 4, slot: 1)
            receiver.hold([], slot: 1)
        }
        await eventually("two presses and releases") { events.count == 4 }
        XCTAssertEqual(deltas, [[1, 2], [3, 4], [11, 2], [13, 4]], "the first report after each press is dropped")
        XCTAssertEqual(legacyDeltas, deltas)
    }

    func testRawXYReportsBeforeReprogV5AreAllDelivered() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        let session = makeSession(receiver, at: 1)
        var events: [ButtonEvent] = []
        var deltas: [[Int]] = []
        session.onButtonEvent = { events.append($0) }
        session.onSourcedPointerDelta = { deltas.append([$0.dx, $0.dy]) }
        let snapshot = try await session.start()
        XCTAssertEqual(snapshot.reprogVersion, 4)
        try await session.applyDiversion([], rawXY: [KnownControl.dpiSwitch])

        receiver.hold([KnownControl.dpiSwitch], slot: 1)
        receiver.move(dx: 1, dy: 2, slot: 1)
        receiver.move(dx: 3, dy: 4, slot: 1)
        receiver.hold([], slot: 1)
        await eventually("press and release") { events.count == 2 }
        XCTAssertEqual(deltas, [[1, 2], [3, 4]])
    }

    func testVoltageBatteryIsReadAndFollowed() async throws {
        var profile = DeviceProfiles.mxVertical
        profile.features = profile.features.map { $0.id == 0x1000 ? SimulatedDeviceProfile.Feature(0x1001, version: 2) : $0 }
        profile.battery = .voltage
        profile.batteryLevel = 50
        let mouse = SimulatedDirect(profile: profile)
        let session = makeSession(mouse, at: 0xFF)
        var changes: [BatteryStatus] = []
        session.onBatteryChange = { changes.append($0) }
        let snapshot = try await session.start()

        let battery = try XCTUnwrap(snapshot.battery)
        XCTAssertTrue(battery.isApproximate)
        XCTAssertEqual(Double(battery.percentage), 50, accuracy: 2)

        mouse.reportBattery(percentage: 20, charging: true)
        await eventually("battery broadcast") { changes.count == 1 }
        XCTAssertEqual(Double(changes.first?.percentage ?? 0), 20, accuracy: 2)
        XCTAssertEqual(changes.first?.isCharging, true)
        XCTAssertEqual(session.snapshot?.battery, changes.first)
    }
}
