import XCTest
@testable import UprightKit

/// Identity values (D5, §D). 0x0003 and 0x0005 layouts are Solaar's (`hidpp20.py` get_ids, get_kind).
final class DeviceIdentityTests: XCTestCase {
    func testParseFirmwareIDsPacksByTransportBits() throws {
        // MX Vertical: [entities, unit ID (4), transport (2), model IDs (6), extended model ID].
        // Bits BLE | wireless | USB, so the three IDs fill the slots in that order.
        let vertical = try XCTUnwrap(DeviceIdentity.parseFirmwareIDs(
            [3, 0x1A, 0x2B, 0x3C, 0x4D, 0x00, 0x0E, 0xB0, 0x20, 0x40, 0x7B, 0xC0, 0x8A, 0x00, 0x01]))
        XCTAssertEqual(vertical.unitID, 0x1A2B3C4D)
        XCTAssertEqual(vertical.modelIDs, ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A))
        XCTAssertNil(vertical.modelIDs.bluetooth)
        XCTAssertEqual(vertical.modelIDs.canonical, 0xB020)
        XCTAssertEqual(vertical.extendedModelID, 0x00)

        // Bluetooth | wireless (MX Master: BT B012, wpid 4041): the first slot is Bluetooth.
        let master = try XCTUnwrap(DeviceIdentity.parseFirmwareIDs(
            [2, 0x00, 0x00, 0xBE, 0xEF, 0x00, 0x05, 0xB0, 0x12, 0x40, 0x41, 0x00, 0x00, 0x07]))
        XCTAssertEqual(master.unitID, 0xBEEF)
        XCTAssertEqual(master.modelIDs, ModelIDs(bluetooth: 0xB012, wireless: 0x4041))
        XCTAssertEqual(master.modelIDs.canonical, 0xB012)
        XCTAssertEqual(master.extendedModelID, 0x07)

        // USB only: the first slot is the USB ID.
        let wired = try XCTUnwrap(DeviceIdentity.parseFirmwareIDs([1, 0, 0, 0, 1, 0, 0x08, 0xC0, 0x8A, 0, 0, 0, 0]))
        XCTAssertEqual(wired.modelIDs, ModelIDs(usb: 0xC08A))

        // A zero ID in its slot counts as absent; so does a zero unit ID.
        let sparse = try XCTUnwrap(DeviceIdentity.parseFirmwareIDs([1, 0, 0, 0, 0, 0, 0x0C, 0x00, 0x00, 0xC0, 0x8A, 0, 0]))
        XCTAssertEqual(sparse.modelIDs, ModelIDs(usb: 0xC08A))
        XCTAssertNil(sparse.unitID)
        XCTAssertNil(sparse.extendedModelID, "13 bytes carry no extended model ID")

        // No transport bits: no model IDs.
        XCTAssertEqual(DeviceIdentity.parseFirmwareIDs([1, 0, 0, 0, 1, 0, 0, 0xB0, 0x20, 0, 0, 0, 0])?.modelIDs.isEmpty, true)
        XCTAssertNil(DeviceIdentity.parseFirmwareIDs([3, 0x1A, 0x2B, 0x3C, 0x4D, 0x00, 0x0E, 0xB0, 0x20, 0x40, 0x7B, 0xC0]))
    }

    private let verticalIDs = ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A)

    func testCanonicalModelKeyIsTransportIndependent() {
        // Bluetooth, USB cable and Unifying slot: the same 0x0003 IDs, three transport PIDs.
        for transport: UInt16 in [0xB020, 0xC08A, 0x407B] {
            let identity = DeviceIdentity(name: "MX Vertical", kind: .mouse, unitID: 0x1A2B3C4D, modelIDs: verticalIDs, transportPID: transport)
            XCTAssertEqual(identity.model, .mxVertical, String(format: "%04X", transport))
            XCTAssertEqual(identity.model.rawValue, "046D:B020")
        }

        // A model the catalog doesn't know keys by its canonical ID on every transport.
        let unknownIDs = ModelIDs(bluetoothLE: 0xBFFE, wireless: 0x4FFE)
        for transport: UInt16 in [0xBFFE, 0x4FFE] {
            XCTAssertEqual(DeviceIdentity(name: "New Mouse", modelIDs: unknownIDs, transportPID: transport).model.rawValue, "046D:BFFE")
        }
        // Bluetooth beats BLE beats wireless beats USB.
        XCTAssertEqual(ModelIDs(bluetooth: 0xBFFD, bluetoothLE: 0xBFFE, wireless: 0x4FFE, usb: 0xCFFE).canonical, 0xBFFD)
        XCTAssertEqual(ModelIDs(wireless: 0x4FFE, usb: 0xCFFE).canonical, 0x4FFE)
        XCTAssertEqual(ModelIDs(usb: 0xCFFE).canonical, 0xCFFE)
    }

    func testCatalogAliasesMapToCanonical() {
        // Without 0x0003 model IDs the transport PID is looked up in the catalog.
        for transport: UInt16 in [0xB020, 0xC08A, 0x407B] {
            XCTAssertEqual(DeviceIdentity(name: "MX Vertical", transportPID: transport).model, .mxVertical, String(format: "%04X", transport))
        }
        XCTAssertEqual(DeviceIdentity(name: "Mystery", transportPID: 0x4FFE).model.rawValue, "046D:4FFE")
        XCTAssertEqual(DeviceIdentity(name: "  Mystery Mouse ").model.rawValue, "name:mystery mouse")
    }

    func testDeviceIDFallbackChain() {
        let address = DeviceAddress(link: 3, index: 2)

        let unit = DeviceIdentity(name: "MX Vertical", unitID: 0x1A2B3C4D, serialNumber: "TEST0001", modelIDs: verticalIDs).deviceID(at: address)
        XCTAssertEqual(unit.rawValue, "u:046D:B020:1A2B3C4D")
        XCTAssertTrue(unit.isStable)
        XCTAssertEqual(unit.model, .mxVertical)
        XCTAssertEqual(DeviceIdentity(name: "MX Vertical", unitID: 0xBEEF, modelIDs: verticalIDs).deviceID(at: address).rawValue,
                       "u:046D:B020:0000BEEF")

        let serial = DeviceIdentity(name: "MX Vertical", unitID: 0, serialNumber: "TEST0001", modelIDs: verticalIDs).deviceID(at: address)
        XCTAssertEqual(serial.rawValue, "s:046D:B020:TEST0001")
        XCTAssertTrue(serial.isStable)
        XCTAssertEqual(serial.model, .mxVertical)

        let transient = DeviceIdentity(name: "MX Vertical", serialNumber: "", modelIDs: verticalIDs).deviceID(at: address)
        XCTAssertEqual(transient.rawValue, "t:3.2")
        XCTAssertFalse(transient.isStable)
        XCTAssertNil(transient.model)
        XCTAssertNotEqual(transient, DeviceIdentity(name: "MX Vertical", modelIDs: verticalIDs).deviceID(at: DeviceAddress(link: 4, index: 2)))
    }

    func testDeviceKindTables() {
        let hidpp20: [UInt8: DeviceKind] = [
            0: .keyboard, 1: .remote, 2: .numpad, 3: .mouse, 4: .touchpad, 5: .trackball, 6: .presenter, 7: .receiver,
        ]
        for (value, kind) in hidpp20 { XCTAssertEqual(DeviceKind(hidpp20: value), kind, "\(value)") }
        XCTAssertEqual(DeviceKind(hidpp20: 9), .other(9))

        let hidpp10: [UInt8: DeviceKind] = [
            0: .unknown, 1: .keyboard, 2: .mouse, 3: .numpad, 4: .presenter, 7: .remote, 8: .trackball, 9: .touchpad,
        ]
        for (value, kind) in hidpp10 { XCTAssertEqual(DeviceKind(hidpp10Nibble: value), kind, "\(value)") }
        XCTAssertEqual(DeviceKind(hidpp10Nibble: 0x42), .mouse, "flag bits above the nibble are ignored")
        XCTAssertEqual(DeviceKind(hidpp10Nibble: 5), .other(5))

        for kind: DeviceKind in [.mouse, .trackball, .touchpad] {
            XCTAssertTrue(kind.isPointer)
            XCTAssertFalse(kind.isDefinitelyNotPointer)
        }
        for kind: DeviceKind in [.keyboard, .numpad, .presenter, .remote, .receiver] {
            XCTAssertFalse(kind.isPointer)
            XCTAssertTrue(kind.isDefinitelyNotPointer)
        }
        for kind: DeviceKind in [.unknown, .other(5)] {
            XCTAssertFalse(kind.isPointer)
            XCTAssertFalse(kind.isDefinitelyNotPointer, "decided by the device's own answers")
        }
    }
}

/// `DeviceFeatures.identity()`, `deviceKind()`, feature versions and the 0x1001 battery, against
/// a scripted device.
@MainActor
final class HIDPPIdentityTests: XCTestCase {
    private let verticalFirmwareIDs: [UInt8] = [3, 0x1A, 0x2B, 0x3C, 0x4D, 0x00, 0x0E, 0xB0, 0x20, 0x40, 0x7B, 0xC0, 0x8A, 0x00, 0x01]

    private func makeFeatures(_ device: IdentityTestDevice) -> DeviceFeatures {
        let client = HIDPPClient(transport: device)
        client.defaultTimeout = 0.1
        return DeviceFeatures(device: HIDPPDevice(client: client, index: device.index))
    }

    func testIdentityReadsKindIDsAndSerial() async throws {
        let mouse = IdentityTestDevice(index: 2, features: [(0x0003, 4), (0x0005, 2)])
        mouse.replies[0x0005] = [2: [3]]
        mouse.replies[0x0003] = [0: verticalFirmwareIDs, 2: Array("TEST00012345".utf8)]

        let identity = try await makeFeatures(mouse).identity(name: "MX Vertical", transportPID: 0x407B)
        XCTAssertEqual(identity.name, "MX Vertical")
        XCTAssertEqual(identity.kind, .mouse)
        XCTAssertEqual(identity.unitID, 0x1A2B3C4D)
        XCTAssertEqual(identity.modelIDs, ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A))
        XCTAssertEqual(identity.extendedModelID, 0x00)
        XCTAssertEqual(identity.serialNumber, "TEST00012345")
        XCTAssertEqual(identity.transportPID, 0x407B)
        XCTAssertEqual(identity.model, .mxVertical)
        XCTAssertEqual(identity.deviceID(at: DeviceAddress(link: 1, index: 2)).rawValue, "u:046D:B020:1A2B3C4D")
    }

    func testSerialNeedsFirmwareFeatureVersion4() async throws {
        let mouse = IdentityTestDevice(features: [(0x0003, 3), (0x0005, 2)])
        mouse.replies[0x0005] = [2: [5]]
        mouse.replies[0x0003] = [0: verticalFirmwareIDs, 2: Array("TEST00012345".utf8)]

        let identity = try await makeFeatures(mouse).identity(name: "MX Ergo")
        XCTAssertEqual(identity.kind, .trackball)
        XCTAssertNil(identity.serialNumber)
        XCTAssertFalse(mouse.called(0x0003, function: 2), "getDeviceSerialNumber exists from version 4")
    }

    func testIdentityWithoutFirmwareFeatureKeysByTransportPID() async throws {
        let mouse = IdentityTestDevice(features: [(0x0005, 2)])
        mouse.replies[0x0005] = [2: [3]]
        let features = makeFeatures(mouse)

        let aliased = try await features.identity(name: "MX Vertical", transportPID: 0xC08A)
        XCTAssertEqual(aliased.model, .mxVertical)
        XCTAssertTrue(aliased.modelIDs.isEmpty)
        XCTAssertNil(aliased.unitID)

        let unknown = try await features.identity(name: "Mystery", transportPID: 0x4FFE)
        XCTAssertEqual(unknown.model.rawValue, "046D:4FFE")
        XCTAssertEqual(unknown.deviceID(at: DeviceAddress(link: 2, index: 0xFF)).rawValue, "t:2.255")

        let named = try await features.identity(name: "Mystery")
        XCTAssertEqual(named.model.rawValue, "name:mystery")
    }

    func testGivenKindSkipsGetDeviceTypeAndRefusalsLeaveItUnknown() async throws {
        let mouse = IdentityTestDevice(features: [(0x0003, 4), (0x0005, 1)])
        mouse.replies[0x0003] = [0: verticalFirmwareIDs]
        mouse.errors[0x0005] = [2: 0x07]
        mouse.errors[0x0003] = [2: 0x02]
        let features = makeFeatures(mouse)

        let refused = try await features.identity(name: "Old Firmware")
        XCTAssertEqual(refused.kind, .unknown)
        XCTAssertNil(refused.serialNumber, "a refused serial read leaves it empty")
        XCTAssertEqual(refused.unitID, 0x1A2B3C4D)

        mouse.clearRequests()
        let given = try await features.identity(name: "Old Firmware", kind: .trackball)
        XCTAssertEqual(given.kind, .trackball)
        XCTAssertFalse(mouse.called(0x0005, function: 2))
    }

    func testIdentityThrowsWhenTheDeviceStopsAnswering() async {
        let mouse = IdentityTestDevice(features: [(0x0003, 4), (0x0005, 2)])
        mouse.replies[0x0005] = [2: [3]]
        mouse.silent[0x0003] = [0]
        do {
            _ = try await makeFeatures(mouse).identity(name: "MX Vertical")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .timeout)
        }
    }

    func testDeviceKindAndFirmwareIDsThrowAsIs() async {
        let keyboard = IdentityTestDevice(features: [(0x0003, 2)])
        let features = makeFeatures(keyboard)
        do {
            _ = try await features.deviceKind()
            XCTFail("expected featureNotSupported")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .featureNotSupported(0x0005))
        }
        keyboard.errors[0x0003] = [0: 0x05]
        do {
            _ = try await features.firmwareIDs()
            XCTFail("expected the device's error")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .hidpp20(0x05))
        }
    }

    func testFeatureVersionFromGetFeatureAndFeatureTable() async throws {
        let mouse = IdentityTestDevice(features: [(0x0003, 4), (0x1B04, 5)])
        let device = makeFeatures(mouse).device

        let reprog = try await device.featureVersion(for: .reprogControlsV4)
        XCTAssertEqual(reprog, 5)
        let missing = try await device.featureVersion(for: .adjustableDPI)
        XCTAssertNil(missing)

        let table = try await device.featureTable()
        XCTAssertEqual(table.map(\.version), [0, 0, 4, 5])
        mouse.clearRequests()
        let firmware = try await device.featureVersion(for: .deviceFirmwareVersion)
        XCTAssertEqual(firmware, 4)
        XCTAssertTrue(mouse.requests.isEmpty, "the feature table already cached it")
    }

    func testBatteryFallsBackToVoltage() async throws {
        let gamingMouse = IdentityTestDevice(features: [(0x1001, 0)])
        gamingMouse.replies[0x1001] = [0: [0x0F, 0x52, 0x00]] // 3922 mV, discharging
        let battery = await makeFeatures(gamingMouse).device.battery()
        XCTAssertEqual(battery, BatteryStatus(percentage: 70, isCharging: false, isApproximate: true))

        let both = IdentityTestDevice(features: [(0x1000, 0), (0x1001, 0)])
        both.replies[0x1000] = [0: [55, 50, 0]]
        both.replies[0x1001] = [0: [0x0F, 0x52, 0x00]]
        let preferred = await makeFeatures(both).device.battery()
        XCTAssertEqual(preferred, BatteryStatus(percentage: 55, isCharging: false))
        XCTAssertFalse(both.called(0x1001, function: 0))
    }
}

final class BatteryVoltageTests: XCTestCase {
    private func status(millivolts: UInt16, flags: UInt8) -> BatteryStatus? {
        BatteryStatus(batteryVoltageParameters: millivolts.bigEndianBytes + [flags])
    }

    func testVoltageCurve() {
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 4200), 100)
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 4186), 100)
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3922), 70)
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3811), 50)
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3885), 64, "60 + 10 × 26/63, rounded")
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3600), 3, "2 + 3 × 21/67, rounded")
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3500), 0)
        XCTAssertEqual(BatteryStatus.percentage(forMillivolts: 3000), 0)
    }

    func testVoltageFlags() {
        XCTAssertEqual(status(millivolts: 3922, flags: 0x00), BatteryStatus(percentage: 70, isCharging: false, isApproximate: true))
        XCTAssertEqual(status(millivolts: 3922, flags: 0x80), BatteryStatus(percentage: 70, isCharging: true, isApproximate: true))
        XCTAssertEqual(status(millivolts: 4100, flags: 0x81)?.isCharging, true, "full while on power")
        XCTAssertEqual(status(millivolts: 3700, flags: 0x20)?.isCharging, false, "critical flag alone")
        XCTAssertEqual(status(millivolts: 0, flags: 0x81), BatteryStatus(percentage: 100, isCharging: true, isApproximate: true))
        XCTAssertNil(status(millivolts: 0, flags: 0x80))
        XCTAssertNil(status(millivolts: 0, flags: 0x00))
        XCTAssertNil(BatteryStatus(batteryVoltageParameters: [0x0F, 0x52]))
    }
}

final class HIDPPFeatureNameTests: XCTestCase {
    func testFeatureNames() {
        XCTAssertEqual(HIDPPFeature.name(for: 0x1B00), "Reprog Controls")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1B01), "Reprog Controls v2")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1B02), "Reprog Controls v2.2")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1B03), "Reprog Controls v3")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1B04), "Reprog Controls v4")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1C00), "Persistent Remappable Action")
        XCTAssertEqual(HIDPPFeature.name(for: 0x2202), "Extended Adjustable DPI")
        XCTAssertEqual(HIDPPFeature.name(for: 0x2205), "Pointer Speed")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1001), "Battery Voltage")
        XCTAssertEqual(HIDPPFeature.name(for: 0x8100), "Onboard Profiles")
        XCTAssertEqual(HIDPPFeature.name(for: 0x1234), "Feature 0x1234")
        XCTAssertEqual(FeatureEntry(index: 4, featureID: 0x2205, version: 0, flags: 0).name, "Pointer Speed")
    }

    func testUnsupportedDeviceError() {
        let partial = DeviceSnapshot(name: "MX Keys", connection: .unifying, deviceIndex: 3, protocolVersion: "4.5",
                                     features: [], controls: [], battery: nil)
        let error = HIDPPError.unsupportedDevice(.notAPointer(.keyboard), partial: partial)
        XCTAssertEqual(error.unsupportedReason, .notAPointer(.keyboard))
        XCTAssertTrue(error.description.contains("MX Keys"))
        XCTAssertFalse(error.meansDeviceUnreachable)
        XCTAssertFalse(error.isBusy)
        XCTAssertNotEqual(error, .unsupportedDevice(.notAPointer(.keyboard), partial: nil))
        XCTAssertEqual(HIDPPError.unsupportedDevice(.noReprogControls, partial: nil).unsupportedReason, .noReprogControls)
        XCTAssertNil(HIDPPError.timeout.unsupportedReason)
    }
}

/// A HID++ 2.0 device answering from a feature list and per-function replies, synchronously.
/// Root and Feature Set are always present (indices 0 and 1).
private final class IdentityTestDevice: HIDPPTransport, @unchecked Sendable {
    var onReport: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let index: UInt8
    /// Feature IDs and versions by feature index.
    let table: [(id: UInt16, version: UInt8)]
    /// Reply parameters by feature ID, then function.
    var replies: [UInt16: [UInt8: [UInt8]]] = [:]
    /// HID++ 2.0 error codes by feature ID, then function.
    var errors: [UInt16: [UInt8: UInt8]] = [:]
    /// Functions that never answer, by feature ID.
    var silent: [UInt16: Set<UInt8>] = [:]
    private(set) var requests: [(feature: UInt16, function: UInt8)] = []

    init(index: UInt8 = 0xFF, features: [(UInt16, UInt8)]) {
        self.index = index
        table = [(0x0000, 0), (0x0001, 0)] + features.map { (id: $0.0, version: $0.1) }
    }

    func called(_ feature: UInt16, function: UInt8) -> Bool {
        requests.contains { $0.feature == feature && $0.function == function }
    }

    func clearRequests() {
        requests.removeAll()
    }

    func send(_ bytes: [UInt8]) throws {
        guard let request = HIDPPMessage(bytes: bytes), request.deviceIndex == index else { return }
        if let reply = respond(to: request) { onReport?(reply.bytes) }
    }

    private func respond(to request: HIDPPMessage) -> HIDPPMessage? {
        guard Int(request.featureIndex) < table.count else { return error(request, 0x06) }
        let feature = table[Int(request.featureIndex)].id
        let p = request.parameters
        requests.append((feature, request.function))
        switch (feature, request.function) {
        case (0x0000, 0):
            let id = p.uint16(at: 0)
            guard let found = table.firstIndex(where: { $0.id == id }) else { return reply(request, [0, 0, 0]) }
            return reply(request, [UInt8(found), 0, table[found].version])
        case (0x0001, 0):
            return reply(request, [UInt8(table.count - 1)])
        case (0x0001, 1):
            guard Int(p[0]) < table.count else { return error(request, 0x02) }
            let entry = table[Int(p[0])]
            return reply(request, entry.id.bigEndianBytes + [0, entry.version])
        default:
            if silent[feature]?.contains(request.function) == true { return nil }
            if let code = errors[feature]?[request.function] { return error(request, code) }
            guard let parameters = replies[feature]?[request.function] else { return error(request, 0x07) }
            return reply(request, parameters)
        }
    }

    private func reply(_ request: HIDPPMessage, _ parameters: [UInt8]) -> HIDPPMessage {
        HIDPPMessage(reportID: .long, deviceIndex: request.deviceIndex, subID: request.subID, address: request.address, parameters: parameters)
    }

    private func error(_ request: HIDPPMessage, _ code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .long, deviceIndex: request.deviceIndex, subID: 0xFF, address: request.subID, parameters: [request.address, code])
    }
}
