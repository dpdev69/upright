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

    func testDeviceClassification() {
        XCTAssertEqual(MXVertical.classify(vendorID: 0x046D, productID: 0xC52B), .receiver(.unifying))
        XCTAssertEqual(MXVertical.classify(vendorID: 0x046D, productID: 0xC548), .receiver(.bolt))
        XCTAssertEqual(MXVertical.classify(vendorID: 0x046D, productID: 0xC08A), .direct(.usb))
        XCTAssertEqual(MXVertical.classify(vendorID: 0x046D, productID: 0xB020), .direct(.bluetooth))
        XCTAssertNil(MXVertical.classify(vendorID: 0x046D, productID: 0xC077))
        XCTAssertNil(MXVertical.classify(vendorID: 0x05AC, productID: 0xC52B))
        XCTAssertTrue(MXVertical.matches(name: "MX Vertical Advanced Ergonomic Mouse"))
        XCTAssertFalse(MXVertical.matches(name: "MX Master 3"))
    }

    func testRePairReplacesADeadInterfaceAndLeavesALiveTwinAlone() {
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: false, sameInterface: false, previousStillPresent: false), .use)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: true, previousStillPresent: true), .use)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: false, previousStillPresent: true), .ignore)
        XCTAssertEqual(HIDInterfaceChoicePolicy.choose(alreadyOpen: true, sameInterface: false, previousStillPresent: false), .replace)
    }
}
