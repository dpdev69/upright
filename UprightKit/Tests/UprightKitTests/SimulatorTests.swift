import XCTest
@testable import UprightKit

/// The simulator itself: profiles answer like their dumps, receivers expose their pairing
/// layouts and notifications, and per-slot state stays per slot.
@MainActor
final class SimulatorTests: XCTestCase {
    private func makeClient(_ transport: HIDPPTransport) -> HIDPPClient {
        let client = HIDPPClient(transport: transport)
        client.defaultTimeout = 0.5
        return client
    }

    private func readRegister(_ client: HIDPPClient, _ subRegister: UInt8) async throws -> [UInt8] {
        try await client.send(.receiverLongRegisterRead(0xB5, parameters: [subRegister])).parameters
    }

    private func pairings(_ client: HIDPPClient, layout: PairingLayout) async throws -> [PairingRecord] {
        var records: [PairingRecord] = []
        for slot in UInt8(1)...6 {
            do {
                let reply = try await readRegister(client, layout.pairingSubRegister(slot: slot))
                if let record = ReceiverDirectory.parsePairing(reply, slot: slot, layout: layout) { records.append(record) }
            } catch HIDPPError.hidpp10(0x03) {
                continue // empty slot
            }
        }
        return records
    }

    // MARK: Profiles

    func testMouseProfilesAnswerFromTheirTables() async throws {
        let mice = [
            DeviceProfiles.mxVertical, DeviceProfiles.mxMaster3S, DeviceProfiles.lift, DeviceProfiles.mxMaster3,
            DeviceProfiles.m720, DeviceProfiles.mxErgo, DeviceProfiles.m185,
        ]
        for profile in mice {
            let device = HIDPPDevice(client: makeClient(SimulatedDirect(profile: profile)), index: 0xFF)
            let model = profile.codename

            let version = try await device.protocolVersion()
            XCTAssertEqual([version.major, version.minor], [profile.protocolMajor, profile.protocolMinor], model)
            let table = try await device.featureTable()
            XCTAssertEqual(table.map(\.featureID), profile.features.map(\.id), model)
            XCTAssertEqual(table.map(\.version), profile.features.map(\.version), model)
            XCTAssertEqual(table.map(\.flags), profile.features.map(\.flags), model)
            let name = try await device.name()
            XCTAssertEqual(name, profile.name, model)
            let type = try await device.call(.deviceName, function: 2)
            XCTAssertEqual(DeviceKind(hidpp20: type[0]), profile.kind, model)
            let controls = try await ReprogControls(device: device).allControls()
            XCTAssertEqual(controls, profile.controls, model)
            let firmware = try await DeviceFeatures(device: device).firmware()
            XCTAssertEqual(firmware.map(\.kind), profile.firmware.map(\.kind), model)
            let battery = await device.battery()
            XCTAssertEqual(battery?.percentage, profile.batteryLevel, model)
            if profile.feature(0x2201) != nil {
                let dpi = try await DeviceFeatures(device: device).dpi()
                XCTAssertEqual(dpi.supported, profile.supportedDPI, model)
                XCTAssertEqual(dpi.current, profile.defaultDPI, model)
            }
        }
    }

    func testMXVerticalMatchesItsDump() async throws {
        let device = HIDPPDevice(client: makeClient(SimulatedDirect(profile: DeviceProfiles.mxVertical)), index: 0xFF)
        let firmware = try await DeviceFeatures(device: device).firmware()
        XCTAssertEqual(firmware.map(\.displayString), ["BOT 78.00.B0009", "MPM 16.00.B0009", ""])
        let serial = try await DeviceFeatures(device: device).serialNumber()
        XCTAssertEqual(serial, "DEMO-0001")
        // "Model ID: B020407BC08A", Transport IDs btleid, wpid, usbid.
        let reply = DeviceProfiles.mxVertical.firmwareIDsReply
        XCTAssertEqual(reply[6], 0x0E)
        XCTAssertEqual(Array(reply[7...12]), [0xB0, 0x20, 0x40, 0x7B, 0xC0, 0x8A])
        let controls = try await ReprogControls(device: device).allControls()
        XCTAssertEqual(controls.filter(\.isConfigurable).map(\.cid), [0x52, 0x53, 0x56, 0xFD])
        XCTAssertTrue(controls.filter(\.isConfigurable).allSatisfy(\.supportsRawXY))
    }

    func testFirmwareIDsGiveCanonicalModelKeysAndFakeUnits() async throws {
        let expected: [(SimulatedDeviceProfile, UInt16)] = [
            (DeviceProfiles.mxVertical, 0xB020), (DeviceProfiles.mxMaster3S, 0xB034), (DeviceProfiles.lift, 0xB031),
            (DeviceProfiles.mxMaster3, 0xB023), (DeviceProfiles.m720, 0xB015), (DeviceProfiles.mxErgo, 0xB01D),
            (DeviceProfiles.m185, 0x4055), (DeviceProfiles.g502Lightspeed, 0x407F), (DeviceProfiles.mxKeys, 0xB35B),
        ]
        for (profile, pid) in expected {
            let ids = try XCTUnwrap(DeviceIdentity.parseFirmwareIDs(profile.firmwareIDsReply), profile.codename)
            XCTAssertEqual(ids.modelIDs, profile.modelIDs, profile.codename)
            XCTAssertEqual(ids.modelIDs.canonical, pid, profile.codename)
            XCTAssertEqual(ids.unitID, profile.unitID, profile.codename)
        }

        let units = DeviceProfiles.all.compactMap(\.unitID)
        XCTAssertEqual(Set(units).count, units.count, "every simulated unit is distinct")
        XCTAssertTrue(units.allSatisfy { $0 & 0x00FF_FF00 == 0x002B_3C00 }, "unit IDs follow the fake pattern")
        let serials = DeviceProfiles.all.compactMap(\.serialNumber)
        XCTAssertEqual(Set(serials).count, serials.count)
        XCTAssertTrue(serials.allSatisfy { $0.hasPrefix("DEMO-") })
        XCTAssertNil(DeviceProfiles.mouseWithoutUnitID.unitID)
        XCTAssertNil(DeviceProfiles.mouseWithoutUnitID.serialNumber)
        XCTAssertEqual(DeviceProfiles.mxVerticalSecondUnit.modelIDs, DeviceProfiles.mxVertical.modelIDs)
        XCTAssertNotEqual(DeviceProfiles.mxVerticalSecondUnit.unitID, DeviceProfiles.mxVertical.unitID)
    }

    func testKeyboardAndUnsupportedProfiles() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxKeys, 2: DeviceProfiles.m510HIDPP10])
        let client = makeClient(receiver)

        let keyboard = HIDPPDevice(client: client, index: 1)
        let type = try await keyboard.call(.deviceName, function: 2)
        XCTAssertEqual(DeviceKind(hidpp20: type[0]), .keyboard)
        let keys = try await ReprogControls(device: keyboard).allControls()
        XCTAssertFalse(keys.filter(\.isConfigurable).isEmpty, "only its kind keeps a keyboard from being diverted")

        let old = try await HIDPPDevice(client: client, index: 2).protocolVersion()
        XCTAssertEqual([old.major, old.minor], [1, 0])
        let records = try await pairings(client, layout: .unifying)
        XCTAssertEqual(records, [
            PairingRecord(slot: 1, wirelessPID: 0x408A, kind: .keyboard),
            PairingRecord(slot: 2, wirelessPID: 0x1025, kind: .mouse),
        ])

        let gaming = HIDPPDevice(client: makeClient(SimulatedDirect(profile: DeviceProfiles.g502Lightspeed)), index: 0xFF)
        let reprog = try await gaming.featureIndex(for: .reprogControlsV4)
        XCTAssertNil(reprog)
    }

    // MARK: Receivers

    func testUnifyingPairingRegisters() async throws {
        let receiver = SimulatedReceiver.unifying([
            1: DeviceProfiles.mxKeys, 2: DeviceProfiles.mxVertical, 3: DeviceProfiles.mxVerticalSecondUnit,
        ])
        XCTAssertEqual(receiver.transportKind, .receiver(.unifying))
        let client = makeClient(receiver)

        let records = try await pairings(client, layout: .unifying)
        XCTAssertEqual(records, [
            PairingRecord(slot: 1, wirelessPID: 0x408A, kind: .keyboard),
            PairingRecord(slot: 2, wirelessPID: 0x407B, kind: .mouse),
            PairingRecord(slot: 3, wirelessPID: 0x407B, kind: .mouse),
        ])
        // Extended pairing information: the unit ID is the slot's serial.
        let extended = try await readRegister(client, 0x31)
        XCTAssertEqual(Array(extended[1...4]), [0x1A, 0x2B, 0x3C, 0x4D])
        let codename = try await readRegister(client, 0x41)
        XCTAssertEqual(String(decoding: codename[2..<(2 + Int(codename[1]))], as: UTF8.self), "MX Vertical")
        let info = try await readRegister(client, 0x03)
        XCTAssertEqual(info[6], 6)
        XCTAssertEqual(receiver.registerReadCount(0xB5), 9)
    }

    func testBoltPairingRegisters() async throws {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift])
        XCTAssertEqual(receiver.transportKind, .receiver(.bolt))
        let client = makeClient(receiver)

        let records = try await pairings(client, layout: .bolt)
        XCTAssertEqual(records, [
            PairingRecord(slot: 1, wirelessPID: 0xB034, kind: .mouse),
            PairingRecord(slot: 2, wirelessPID: 0xB031, kind: .mouse),
        ])
        let record = try await readRegister(client, 0x52)
        XCTAssertEqual(Array(record[4...7]), [0x3A, 0x2B, 0x3C, 0x4D])
        let name = try await readRegister(client, 0x61)
        XCTAssertEqual(String(decoding: name[3..<(3 + Int(name[2]))], as: UTF8.self), "MX Master 3S")
        do {
            _ = try await readRegister(client, 0x20)
            XCTFail("Bolt has no Unifying pairing sub-registers")
        } catch HIDPPError.hidpp10(let code) {
            XCTAssertEqual(code, 0x03)
        }
    }

    func testNanoUsesTheUnifyingLayout() async throws {
        let receiver = SimulatedReceiver.nano([1: DeviceProfiles.m185])
        XCTAssertEqual(receiver.transportKind, .receiver(.nano))
        let records = try await pairings(makeClient(receiver), layout: .unifying)
        XCTAssertEqual(records, [PairingRecord(slot: 1, wirelessPID: 0x4055, kind: .mouse)])

        receiver.supportsPairingInfo = false
        do {
            _ = try await readRegister(makeClient(receiver), 0x20)
            XCTFail("pairing information is off")
        } catch HIDPPError.hidpp10(let code) {
            XCTAssertEqual(code, 0x02)
        }
    }

    func testLinkNotificationsAndAnnouncements() async throws {
        let receiver = SimulatedReceiver.unifying([2: DeviceProfiles.mxVertical])
        let client = makeClient(receiver)
        let messages = Recorder<HIDPPMessage>()
        client.onUnsolicited = { messages.append($0) }

        receiver.goToSleep(slot: 2)
        receiver.wakeUp(slot: 2)
        receiver.pair(DeviceProfiles.mxKeys, slot: 3)
        receiver.unpair(slot: 3)
        await eventually("four notifications") { messages.count == 4 }
        let links = messages.records.prefix(3).compactMap(ReceiverDirectory.parseConnection)
        XCTAssertEqual(links.map { $0.slot }, [2, 2, 3])
        XCTAssertEqual(links.map { $0.linkUp }, [false, true, true])
        XCTAssertEqual(links.map { $0.wirelessPID }, [0x407B, 0x407B, 0x408A])
        XCTAssertEqual(links.map { $0.kind }, [.mouse, .mouse, .keyboard])
        XCTAssertEqual(ReceiverDirectory.isUnpair(messages.records[3]), 3)

        // Asking for announcements reports every paired device with its link state.
        receiver.pair(DeviceProfiles.mxKeys, slot: 1, announce: false)
        receiver.goToSleep(slot: 2)
        await eventually("link loss") { messages.count == 5 }
        messages.removeAll()
        _ = try await client.send(.receiverRegisterWrite(0x02, parameters: [0x02, 0x00, 0x00]))
        await eventually("two announcements") { messages.count == 2 }
        let announced = messages.records.compactMap(ReceiverDirectory.parseConnection)
        XCTAssertEqual(announced.map { $0.slot }, [1, 2])
        XCTAssertEqual(announced.map { $0.linkUp }, [true, false])
        XCTAssertEqual(receiver.registerWriteCount(0x02), 1)
    }

    func testNotificationFlagsAreReadableAndCanGateLinkNotifications() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical])
        receiver.notificationFlags = [0x10, 0x00, 0x00]
        receiver.linkNotificationsNeedFlag = true
        let client = makeClient(receiver)
        let messages = Recorder<HIDPPMessage>()
        client.onUnsolicited = { messages.append($0) }

        let read = try await client.send(HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x81, address: 0x00))
        let current = Array(read.parameters.prefix(3))
        XCTAssertEqual(current, [0x10, 0x00, 0x00])
        receiver.goToSleep(slot: 1)
        _ = try await client.send(.receiverRegisterWrite(0x00, parameters: ReceiverDirectory.mergedNotificationFlags(current: current)))
        XCTAssertEqual(receiver.notificationFlags, [0x10, 0x09, 0x00])
        XCTAssertEqual(receiver.registerReadCount(0x00), 1)
        XCTAssertEqual(receiver.registerWriteCount(0x00), 1)

        receiver.wakeUp(slot: 1)
        await eventually("link-up") { messages.count == 1 }
        await pause(0.05)
        XCTAssertEqual(messages.count, 1, "the link loss before notifications were enabled was not sent")
        XCTAssertEqual(ReceiverDirectory.parseConnection(messages.records[0])?.linkUp, true)
    }

    // MARK: Per-slot state

    func testIdenticalMiceKeepSeparateState() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxVerticalSecondUnit])
        let client = makeClient(receiver)
        let first = HIDPPDevice(client: client, index: 1)
        let second = HIDPPDevice(client: client, index: 2)
        let messages = Recorder<HIDPPMessage>()
        client.onUnsolicited = { messages.append($0) }

        try await ReprogControls(device: first).setDiverted(true, cid: KnownControl.back)
        try await ReprogControls(device: second).setReporting(cid: KnownControl.forward, diverted: true, rawXY: true)
        XCTAssertEqual(receiver.diverted(slot: 1), [KnownControl.back])
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.forward])
        XCTAssertEqual(receiver.rawXY(slot: 1), [])
        XCTAssertEqual(receiver.rawXY(slot: 2), [KnownControl.forward])
        XCTAssertEqual(receiver.setReportingCount(slot: 1), 1)
        XCTAssertEqual(receiver.setReportingCount(slot: 2), 1)
        XCTAssertEqual(receiver.setReportingCount, 2)

        let firstIDs = try await first.call(.deviceFirmwareVersion, function: 0)
        let secondIDs = try await second.call(.deviceFirmwareVersion, function: 0)
        XCTAssertEqual(DeviceIdentity.parseFirmwareIDs(firstIDs)?.unitID, 0x1A2B_3C4D)
        XCTAssertEqual(DeviceIdentity.parseFirmwareIDs(secondIDs)?.unitID, 0x1A2B_3C4E)

        // Reports carry their own slot and list only that mouse's diverted controls.
        receiver.hold([KnownControl.back, KnownControl.forward], slot: 1)
        receiver.move(dx: -5, dy: 300, slot: 2)
        await eventually("two reports") { messages.count == 2 }
        XCTAssertEqual(messages.records[0].deviceIndex, 1)
        XCTAssertEqual(ReprogControls.pressedControls(fromEventParameters: messages.records[0].parameters), [KnownControl.back])
        XCTAssertEqual(messages.records[1].deviceIndex, 2)
        let delta = ReprogControls.rawXYDelta(fromEventParameters: messages.records[1].parameters)
        XCTAssertEqual([delta.dx, delta.dy], [-5, 300])

        // One asleep, the other answering.
        receiver.goToSleep(slot: 1)
        do {
            _ = try await first.protocolVersion()
            XCTFail("an asleep slot doesn't answer")
        } catch HIDPPError.hidpp10(let code) {
            XCTAssertEqual(code, 0x09)
        }
        _ = try await second.protocolVersion()
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.forward])

        // Waking with its state cleared only affects that mouse.
        receiver.wakeUp(slot: 1)
        XCTAssertEqual(receiver.diverted(slot: 1), [])
        XCTAssertEqual(receiver.diverted(slot: 2), [KnownControl.forward])
    }

    func testEasySwitchSleepsOnlyTheAddressedSlot() async throws {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift])
        let client = makeClient(receiver)
        let messages = Recorder<HIDPPMessage>()
        client.onUnsolicited = { messages.append($0) }
        let index = try await HIDPPDevice(client: client, index: 1).featureIndex(for: .changeHost)
        let changeHost = try XCTUnwrap(index)

        client.sendWithoutReply(DeviceFeatures.changeHostMessage(deviceIndex: 1, featureIndex: changeHost, host: 1, softwareID: client.softwareID))
        await eventually("asleep") { !receiver.isAwake(slot: 1) }
        await eventually("link loss") { messages.count == 1 }
        XCTAssertEqual(receiver.hostSwitches(slot: 1), [1])
        XCTAssertEqual(receiver.currentHost(slot: 1), 1)
        XCTAssertTrue(receiver.isAwake(slot: 2))
        XCTAssertEqual(receiver.hostSwitches(slot: 2), [])
        let link = try XCTUnwrap(ReceiverDirectory.parseConnection(messages.records[0]))
        XCTAssertEqual(link.slot, 1)
        XCTAssertFalse(link.linkUp)
    }

    func testRequestsInFlightMaxSeesOverlappingRequests() async throws {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.lift])
        receiver.latency = 0.05
        let client = makeClient(receiver)

        _ = try await HIDPPDevice(client: client, index: 1).protocolVersion()
        _ = try await HIDPPDevice(client: client, index: 2).protocolVersion()
        XCTAssertEqual(receiver.requestsInFlightMax, 1, "one after the other")

        let first = Task { try await HIDPPDevice(client: client, index: 1).protocolVersion() }
        let second = Task { try await HIDPPDevice(client: client, index: 2).protocolVersion() }
        _ = try await (first.value, second.value)
        XCTAssertEqual(receiver.requestsInFlightMax, 2, "both waiting at once")

        // Requests nobody answers only count when asked to.
        receiver.resetTraffic()
        receiver.setDropsRequests(true, slot: 1)
        receiver.unansweredRequestWindow = 0.2
        let ping: [UInt8] = [0, 0, 0x5A]
        client.sendWithoutReply(.request(deviceIndex: 1, featureIndex: 0, function: 1, softwareID: client.softwareID, parameters: ping))
        client.sendWithoutReply(.request(deviceIndex: 1, featureIndex: 0, function: 1, softwareID: client.softwareID, parameters: ping))
        XCTAssertEqual(receiver.requestsInFlightMax, 2)
        XCTAssertEqual(receiver.pingCount(slot: 1), 2)
    }

    func testBatteryReportsFollowTheProfilesFeature() async throws {
        let receiver = SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S])
        let client = makeClient(receiver)
        let messages = Recorder<HIDPPMessage>()
        client.onUnsolicited = { messages.append($0) }

        receiver.reportBattery(percentage: 9, charging: true, slot: 1)
        await eventually("battery event") { messages.count == 1 }
        let event = messages.records[0]
        XCTAssertEqual(event.featureIndex, DeviceProfiles.mxMaster3S.featureIndex(of: 0x1004))
        XCTAssertEqual(BatteryStatus(unifiedBatteryParameters: event.parameters), BatteryStatus(percentage: 9, isCharging: true))
        let battery = await HIDPPDevice(client: client, index: 1).battery()
        XCTAssertEqual(battery, BatteryStatus(percentage: 9, isCharging: true))
        XCTAssertEqual(receiver.batteryLevel(slot: 1), 9)
    }
}
