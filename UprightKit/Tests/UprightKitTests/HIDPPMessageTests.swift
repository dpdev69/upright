import XCTest
@testable import UprightKit

final class HIDPPMessageTests: XCTestCase {
    func testLongRequestEncoding() {
        let message = HIDPPMessage.request(deviceIndex: 0xFF, featureIndex: 0x04, function: 3, softwareID: 0x0A, parameters: [0x00, 0x53, 0x03])
        XCTAssertEqual(message.bytes.count, 20)
        XCTAssertEqual(Array(message.bytes.prefix(7)), [0x11, 0xFF, 0x04, 0x3A, 0x00, 0x53, 0x03])
        XCTAssertEqual(message.function, 3)
        XCTAssertEqual(message.softwareID, 0x0A)
    }

    func testShortMessagePadsAndTruncates() {
        let message = HIDPPMessage(reportID: .short, deviceIndex: 1, subID: 0x80, address: 0, parameters: [1, 2, 3, 4, 5])
        XCTAssertEqual(message.bytes, [0x10, 0x01, 0x80, 0x00, 1, 2, 3])
    }

    func testParsingRejectsNonHIDPPReports() {
        XCTAssertNil(HIDPPMessage(bytes: [0x02, 0x00, 0x00, 0x00]))
        XCTAssertNil(HIDPPMessage(bytes: [0x11, 0xFF]))
        XCTAssertEqual(HIDPPMessage(bytes: [0x11, 0xFF, 0x00, 0x1A, 4, 5])?.parameters.count, 16)
    }

    func testResponseMatching() {
        let request = HIDPPMessage.request(deviceIndex: 2, featureIndex: 0x00, function: 1, softwareID: 0x0A)
        let success = HIDPPMessage(reportID: .long, deviceIndex: 2, subID: 0x00, address: 0x1A, parameters: [4, 5])
        let error20 = HIDPPMessage(reportID: .long, deviceIndex: 2, subID: 0xFF, address: 0x00, parameters: [0x1A, 0x07])
        let error10 = HIDPPMessage(reportID: .short, deviceIndex: 2, subID: 0x8F, address: 0x00, parameters: [0x1A, 0x09])
        let event = HIDPPMessage(reportID: .long, deviceIndex: 2, subID: 0x00, address: 0x10)
        let otherDevice = HIDPPMessage(reportID: .long, deviceIndex: 3, subID: 0x00, address: 0x1A)

        XCTAssertEqual(success.match(to: request), .success)
        XCTAssertEqual(error20.match(to: request), .hidpp20Error(0x07))
        XCTAssertEqual(error10.match(to: request), .hidpp10Error(0x09))
        XCTAssertNil(event.match(to: request))
        XCTAssertNil(otherDevice.match(to: request))
    }

    func testDivertedButtonsDecoding() {
        XCTAssertEqual(ReprogControls.pressedControls(fromEventParameters: [0x00, 0x53, 0x00, 0xFD] + Array(repeating: 0, count: 12)), [0x53, 0xFD])
        XCTAssertEqual(ReprogControls.pressedControls(fromEventParameters: Array(repeating: 0, count: 16)), [])
    }

    func testControlInfoDecoding() {
        let info = ControlInfo(cidInfoParameters: [0x00, 0xFD, 0x00, 0xA4, 0x30, 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(info.cid, 0xFD)
        XCTAssertEqual(info.taskID, 0xA4)
        XCTAssertTrue(info.flags.contains(.divertable))
        XCTAssertTrue(info.flags.contains(.reprogrammable))
        XCTAssertTrue(info.isConfigurable)

        let virtual = ControlInfo(cid: 0xD7, taskID: 0, flags: [.divertable, .virtual])
        XCTAssertFalse(virtual.isConfigurable)
        let leftClick = ControlInfo(cid: 0x50, taskID: 0, flags: [.mouseButton, .divertable])
        XCTAssertFalse(leftClick.isConfigurable)
    }

    func testButtonStateTracker() {
        var tracker = ButtonStateTracker()
        XCTAssertEqual(tracker.update(pressedNow: [0x53]), [ButtonEvent(cid: 0x53, phase: .press)])
        XCTAssertEqual(tracker.update(pressedNow: [0x53, 0x56]), [ButtonEvent(cid: 0x56, phase: .press)])
        XCTAssertEqual(tracker.update(pressedNow: [0x56]), [ButtonEvent(cid: 0x53, phase: .release)])
        XCTAssertEqual(tracker.reset(), [ButtonEvent(cid: 0x56, phase: .release)])
        XCTAssertEqual(tracker.reset(), [])
    }

    /// The classification cases that used to pin `MXVertical.classify`, now against
    /// `InterfaceClassifier`. What changed: nothing is gated on the product name, so an MX Master 3
    /// over Bluetooth is served; the non-HID++ M100 (C077) and other vendors are still ignored.
    func testDeviceClassification() {
        func classify(_ vendor: Int, _ product: Int, transport: String = "", page: Int = 0xFF00) -> InterfaceClass {
            InterfaceClassifier.classify(HIDInterfaceDescriptor(vendorID: vendor, productID: product, transport: transport, usagePage: page))
        }

        XCTAssertEqual(classify(0x046D, 0xC52B), .receiver(.unifying, .unifying))
        XCTAssertEqual(classify(0x046D, 0xC548), .receiver(.bolt, .bolt))
        XCTAssertEqual(classify(0x046D, 0xC08A), .direct(.usb))
        XCTAssertEqual(classify(0x046D, 0xB020), .direct(.bluetooth))
        XCTAssertEqual(classify(0x046D, 0xC08A).transportKind, .direct(.usb))

        // Inverted: an MX Master 3 (Bluetooth B023) was rejected by name before; it is a mouse now.
        XCTAssertEqual(classify(0x046D, 0xB023, transport: "Bluetooth Low Energy", page: 0x01), .direct(.bluetooth))
        // Inverted: Nano receivers were not watched; they are served, with the Unifying layout.
        XCTAssertEqual(classify(0x046D, 0xC52F), .receiver(.nano, .unifying))

        // Still ignored: a plain (non-HID++) Logitech mouse, another vendor, a Lightspeed receiver, a keyboard.
        XCTAssertEqual(classify(0x046D, 0xC077, transport: "USB", page: 0x01).transportKind, nil)
        XCTAssertEqual(classify(0x05AC, 0xC52B).transportKind, nil)
        XCTAssertEqual(classify(0x046D, 0xC539).transportKind, nil)
        XCTAssertEqual(classify(0x046D, 0xB350, transport: "Bluetooth Low Energy").transportKind, nil)
        if case .ignored(let reason) = classify(0x046D, 0xC077, transport: "USB", page: 0x01) {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("C077 must be ignored")
        }
    }

    func testRePairReplacesADeadInterfaceAndLeavesALiveTwinAlone() {
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: false, sameInterface: false, previousStillPresent: false), .use)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: true, previousStillPresent: true), .use)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: false, previousStillPresent: true), .ignore)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: false, previousStillPresent: false), .replace)
    }

    func testBatteryStatusParsing() {
        // 0x1000: [level, next level, status]
        XCTAssertEqual(BatteryStatus(batteryStatusParameters: [80, 50, 0]), BatteryStatus(percentage: 80, isCharging: false))
        XCTAssertEqual(BatteryStatus(batteryStatusParameters: [100, 0, 3]), BatteryStatus(percentage: 100, isCharging: true))
        XCTAssertEqual(BatteryStatus(batteryStatusParameters: [0, 0, 3]), BatteryStatus(percentage: 100, isCharging: true))
        XCTAssertNil(BatteryStatus(batteryStatusParameters: [0, 0, 1]))
        let previous = BatteryStatus(percentage: 42, isCharging: false)
        XCTAssertEqual(BatteryStatus(batteryStatusParameters: [0, 0, 1], previous: previous), BatteryStatus(percentage: 42, isCharging: true))
        XCTAssertNil(BatteryStatus(batteryStatusParameters: [0, 0, 0], previous: previous))

        // 0x1004: [state of charge, level flags, charging status, external power]
        XCTAssertEqual(BatteryStatus(unifiedBatteryParameters: [73, 0x04, 0, 0]), BatteryStatus(percentage: 73, isCharging: false))
        XCTAssertEqual(BatteryStatus(unifiedBatteryParameters: [100, 0x08, 3, 1]), BatteryStatus(percentage: 100, isCharging: true))
        XCTAssertEqual(BatteryStatus(unifiedBatteryParameters: [0, 0x02, 0, 0], reportsPercentage: false),
                       BatteryStatus(percentage: 20, isCharging: false, isApproximate: true))
        XCTAssertEqual(BatteryStatus(unifiedBatteryParameters: [55, 0x08, 1, 1], reportsPercentage: false),
                       BatteryStatus(percentage: 90, isCharging: true, isApproximate: true))
    }

    func testErrorClassification() {
        XCTAssertTrue(HIDPPError.timeout.meansDeviceUnreachable)
        XCTAssertTrue(HIDPPError.sendFailed(-1).meansDeviceUnreachable)
        XCTAssertTrue(HIDPPError.hidpp10(0x09).meansDeviceUnreachable)
        XCTAssertFalse(HIDPPError.hidpp20(0x04).meansDeviceUnreachable)
        XCTAssertTrue(HIDPPError.hidpp20(0x08).isBusy)
        XCTAssertTrue(HIDPPError.hidpp10(0x07).isBusy)
        XCTAssertFalse(HIDPPError.hidpp20(0x02).isBusy)
    }

    func testReceiverRegisterMessages() {
        XCTAssertEqual(Array(HIDPPMessage.receiverRegisterWrite(0x02, parameters: [0x02]).bytes), [0x10, 0xFF, 0x80, 0x02, 0x02, 0x00, 0x00])
        XCTAssertEqual(Array(HIDPPMessage.receiverLongRegisterRead(0xB5, parameters: [0x21]).bytes), [0x10, 0xFF, 0x83, 0xB5, 0x21, 0x00, 0x00])
    }
}
