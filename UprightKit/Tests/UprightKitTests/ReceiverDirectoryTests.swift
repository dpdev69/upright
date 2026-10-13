import XCTest
@testable import UprightKit

/// Pairing layouts and 0x40/0x41 formats are Solaar's (`receiver.py`, `notifications.py`).
final class ReceiverDirectoryTests: XCTestCase {
    // MARK: Pairing records

    func testUnifyingPairingLayout() throws {
        // [sub, destination ID, report interval, wpid hi, wpid lo, ?, ?, kind]
        let record = try XCTUnwrap(ReceiverDirectory.parsePairing([0x20, 0x4B, 0x08, 0x40, 0x7B, 0x00, 0x00, 0x02], slot: 1, layout: .unifying))
        XCTAssertEqual(record, PairingRecord(slot: 1, wirelessPID: 0x407B, kind: .mouse))

        let third = try XCTUnwrap(ReceiverDirectory.parsePairing([0x22, 0x00, 0x08, 0x40, 0x82, 0x00, 0x00, 0x41], slot: 3, layout: .unifying))
        XCTAssertEqual(third, PairingRecord(slot: 3, wirelessPID: 0x4082, kind: .keyboard), "only the low nibble is the kind")
        XCTAssertEqual(PairingLayout.unifying.pairingSubRegister(slot: 1), 0x20)
        XCTAssertEqual(PairingLayout.unifying.pairingSubRegister(slot: 6), 0x25)
    }

    func testBoltPairingLayout() throws {
        // [sub, kind, wpid lo, wpid hi, serial (4)]: slot n is sub-register 0x50 + n, not n - 1.
        let reply: [UInt8] = [0x52, 0x02, 0x34, 0xB0, 0x1A, 0x2B, 0x3C, 0x4D]
        let record = try XCTUnwrap(ReceiverDirectory.parsePairing(reply, slot: 2, layout: .bolt))
        XCTAssertEqual(record, PairingRecord(slot: 2, wirelessPID: 0xB034, kind: .mouse))
        XCTAssertEqual(PairingLayout.bolt.pairingSubRegister(slot: 1), 0x51)
        XCTAssertEqual(PairingLayout.bolt.pairingSubRegister(slot: 6), 0x56)

        XCTAssertNil(ReceiverDirectory.parsePairing(reply, slot: 1, layout: .bolt), "0x52 is slot 2 on Bolt")
        XCTAssertNil(ReceiverDirectory.parsePairing(reply, slot: 2, layout: .unifying), "Unifying slot 2 is 0x21")
        XCTAssertNil(ReceiverDirectory.parsePairing([0x21, 0x02, 0x34, 0xB0, 0, 0, 0, 0x02], slot: 2, layout: .bolt))
    }

    func testPairingKindNibbles() {
        func kind(_ nibble: UInt8, _ layout: PairingLayout) -> DeviceKind? {
            let reply: [UInt8] = layout == .unifying
                ? [0x20, 0, 0, 0x40, 0x10, 0, 0, nibble]
                : [0x51, nibble, 0x10, 0x40, 0, 0, 0, 0]
            return ReceiverDirectory.parsePairing(reply, slot: 1, layout: layout)?.kind
        }
        for layout in [PairingLayout.unifying, .bolt] {
            XCTAssertEqual(kind(0x01, layout), .keyboard)
            XCTAssertEqual(kind(0x02, layout), .mouse)
            XCTAssertEqual(kind(0x03, layout), .numpad)
            XCTAssertEqual(kind(0x04, layout), .presenter)
            XCTAssertEqual(kind(0x07, layout), .remote)
            XCTAssertEqual(kind(0x08, layout), .trackball)
            XCTAssertEqual(kind(0x09, layout), .touchpad)
            XCTAssertEqual(kind(0x00, layout), .unknown)
            XCTAssertEqual(kind(0x62, layout), .mouse)
        }
    }

    func testEmptyShortAndOutOfRangePairingRepliesAreNil() {
        XCTAssertNil(ReceiverDirectory.parsePairing([0x20, 0, 0, 0, 0, 0, 0, 0x02], slot: 1, layout: .unifying), "wpid 0 is an empty slot")
        XCTAssertNil(ReceiverDirectory.parsePairing([0x51, 0x02, 0, 0, 0, 0, 0, 0], slot: 1, layout: .bolt))
        XCTAssertNil(ReceiverDirectory.parsePairing([0x20, 0, 0, 0x40, 0x7B], slot: 1, layout: .unifying), "short reply")
        XCTAssertNil(ReceiverDirectory.parsePairing([0x21, 0, 0, 0x40, 0x7B, 0, 0, 2], slot: 1, layout: .unifying), "another slot's reply")
        XCTAssertNil(ReceiverDirectory.parsePairing([0x1F, 0, 0, 0x40, 0x7B, 0, 0, 2], slot: 0, layout: .unifying))
        XCTAssertNil(ReceiverDirectory.parsePairing([0x26, 0, 0, 0x40, 0x7B, 0, 0, 2], slot: 7, layout: .unifying))
    }

    func testNanoReceiversUseTheUnifyingLayout() {
        for pid: UInt16 in [0xC52F, 0xC534] {
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.layout, .unifying, String(format: "%04X", pid))
        }
        XCTAssertEqual(DeviceCatalog.receivers[0xC548]?.layout, .bolt)
        // Nano C534 hosting "Wireless Mouse M185 new" (wpid 4054) in slot 2.
        let record = ReceiverDirectory.parsePairing([0x21, 0x00, 0x08, 0x40, 0x54, 0x00, 0x00, 0x02], slot: 2, layout: .unifying)
        XCTAssertEqual(record, PairingRecord(slot: 2, wirelessPID: 0x4054, kind: .mouse))
    }

    // MARK: Serial numbers

    func testSerialFromExtendedPairingAndBoltRecord() {
        XCTAssertEqual(PairingLayout.unifying.serialSubRegister(slot: 1), 0x30)
        XCTAssertEqual(PairingLayout.unifying.serialSubRegister(slot: 6), 0x35)
        XCTAssertEqual(PairingLayout.bolt.serialSubRegister(slot: 3), 0x53)

        let extended: [UInt8] = [0x31, 0x1A, 0x2B, 0x3C, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x02]
        XCTAssertEqual(ReceiverDirectory.parseSerial(extended, slot: 2, layout: .unifying), "1A2B3C4D")
        XCTAssertNil(ReceiverDirectory.parseSerial(extended, slot: 1, layout: .unifying))

        let bolt: [UInt8] = [0x53, 0x02, 0x34, 0xB0, 0xDE, 0xAD, 0x00, 0x01]
        XCTAssertEqual(ReceiverDirectory.parseSerial(bolt, slot: 3, layout: .bolt), "DEAD0001")

        XCTAssertNil(ReceiverDirectory.parseSerial([0x30, 0, 0, 0, 0, 0, 0, 0], slot: 1, layout: .unifying))
        XCTAssertNil(ReceiverDirectory.parseSerial([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0], slot: 1, layout: .unifying))
        XCTAssertNil(ReceiverDirectory.parseSerial([0x30, 0x1A, 0x2B], slot: 1, layout: .unifying))
    }

    // MARK: Notifications

    private func notification(_ subID: UInt8, slot: UInt8, address: UInt8 = 0x04, _ parameters: [UInt8] = []) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: slot, subID: subID, address: address, parameters: parameters)
    }

    func testConnectionNotification() throws {
        let up = try XCTUnwrap(ReceiverDirectory.parseConnection(notification(0x41, slot: 2, [0x02, 0x7B, 0x40])))
        XCTAssertEqual(up.slot, 2)
        XCTAssertEqual(up.wirelessPID, 0x407B)
        XCTAssertEqual(up.kind, .mouse)
        XCTAssertTrue(up.linkUp)

        let down = try XCTUnwrap(ReceiverDirectory.parseConnection(notification(0x41, slot: 2, [0x42, 0x7B, 0x40])))
        XCTAssertFalse(down.linkUp)
        XCTAssertEqual(down.kind, .mouse)

        // Encrypted (0x20) and software-present (0x10) bits don't change the link state.
        let encrypted = try XCTUnwrap(ReceiverDirectory.parseConnection(notification(0x41, slot: 5, [0x31, 0x82, 0x40])))
        XCTAssertTrue(encrypted.linkUp)
        XCTAssertEqual(encrypted.kind, .keyboard)
        XCTAssertEqual(encrypted.wirelessPID, 0x4082)

        // Bolt (protocol 0x10) reports its device's Bxxx PID the same way.
        let bolt = try XCTUnwrap(ReceiverDirectory.parseConnection(notification(0x41, slot: 1, address: 0x10, [0x22, 0x34, 0xB0])))
        XCTAssertEqual(bolt.wirelessPID, 0xB034)
        XCTAssertTrue(bolt.linkUp)

        // An announcement without a PID still parses; the hub decides what a 0 PID means.
        XCTAssertEqual(ReceiverDirectory.parseConnection(notification(0x41, slot: 3, [0x00, 0x00, 0x00]))?.wirelessPID, 0)
    }

    func testConnectionNotificationIgnoresOtherMessages() {
        XCTAssertNil(ReceiverDirectory.parseConnection(notification(0x40, slot: 2, address: 0x02)))
        XCTAssertNil(ReceiverDirectory.parseConnection(notification(0x41, slot: 0xFF, [0x02, 0x7B, 0x40])))
        XCTAssertNil(ReceiverDirectory.parseConnection(notification(0x41, slot: 0, [0x02, 0x7B, 0x40])))
        XCTAssertNil(ReceiverDirectory.parseConnection(notification(0x41, slot: 7, [0x02, 0x7B, 0x40])))
        XCTAssertNil(ReceiverDirectory.parseConnection(.request(deviceIndex: 1, featureIndex: 0x05, function: 0, softwareID: 0)))
    }

    func testUnpairNotification() {
        XCTAssertEqual(ReceiverDirectory.isUnpair(notification(0x40, slot: 3, address: 0x02)), 3)
        XCTAssertNil(ReceiverDirectory.isUnpair(notification(0x40, slot: 3, address: 0x00)), "not an un-pairing")
        XCTAssertNil(ReceiverDirectory.isUnpair(notification(0x41, slot: 3, address: 0x02, [0x42, 0x7B, 0x40])))
        XCTAssertNil(ReceiverDirectory.isUnpair(notification(0x40, slot: 0xFF, address: 0x02)))
    }

    func testNotificationFlagsMergeKeepsOtherBits() {
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: [0x00, 0x00, 0x00]), [0x00, 0x09, 0x00])
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: [0x00, 0x09, 0x00]), [0x00, 0x09, 0x00])
        // Another program's flags (link quality 0x000400, battery 0x100000, 3D gesture 0x000001) survive.
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: [0x10, 0x04, 0x01]), [0x10, 0x0D, 0x01])
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: [0x00, 0x01, 0x00]), [0x00, 0x09, 0x00])
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: []), [0x00, 0x09, 0x00])
        XCTAssertEqual(ReceiverDirectory.mergedNotificationFlags(current: [0x01, 0x02, 0x03, 0x04]), [0x01, 0x0B, 0x03])
    }

    func testRequestMessages() {
        XCTAssertEqual(ReceiverDirectory.pairingReadMessage(slot: 2, layout: .unifying).bytes, [0x10, 0xFF, 0x83, 0xB5, 0x21, 0x00, 0x00])
        XCTAssertEqual(ReceiverDirectory.pairingReadMessage(slot: 2, layout: .bolt).bytes, [0x10, 0xFF, 0x83, 0xB5, 0x52, 0x00, 0x00])
        XCTAssertEqual(ReceiverDirectory.serialReadMessage(slot: 2, layout: .unifying).bytes, [0x10, 0xFF, 0x83, 0xB5, 0x31, 0x00, 0x00])
        XCTAssertEqual(ReceiverDirectory.notificationFlagsReadMessage.bytes, [0x10, 0xFF, 0x81, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ReceiverDirectory.notificationFlagsWriteMessage([0x10, 0x0D, 0x01]).bytes, [0x10, 0xFF, 0x80, 0x00, 0x10, 0x0D, 0x01])
        XCTAssertEqual(ReceiverDirectory.announcementRequestMessage.bytes, [0x10, 0xFF, 0x80, 0x02, 0x02, 0x00, 0x00])
    }

    // MARK: Receiver operations

    private func makeClient(_ receiver: PairingTestReceiver) -> HIDPPClient {
        let client = HIDPPClient(transport: receiver)
        client.defaultTimeout = 0.1
        return client
    }

    func testReadPairingsListsOccupiedSlots() async throws {
        let receiver = PairingTestReceiver()
        receiver.pairingReplies[0x20] = [0x20, 0x00, 0x08, 0x40, 0x7B, 0x00, 0x00, 0x02]
        receiver.pairingReplies[0x22] = [0x22, 0x00, 0x08, 0x40, 0x82, 0x00, 0x00, 0x01]
        receiver.pairingReplies[0x23] = [0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

        let records = try await ReceiverDirectory.readPairings(using: makeClient(receiver), layout: .unifying)
        XCTAssertEqual(records, [
            1: PairingRecord(slot: 1, wirelessPID: 0x407B, kind: .mouse),
            3: PairingRecord(slot: 3, wirelessPID: 0x4082, kind: .keyboard),
        ])
        XCTAssertEqual(receiver.pairingReads, [0x20, 0x21, 0x22, 0x23, 0x24, 0x25], "every slot is read, whatever the capacity")
    }

    func testReadPairingsUsesTheBoltLayout() async throws {
        let receiver = PairingTestReceiver()
        receiver.pairingReplies[0x51] = [0x51, 0x02, 0x34, 0xB0, 0x01, 0x02, 0x03, 0x04]
        receiver.pairingReplies[0x52] = [0x52, 0x02, 0x84, 0xB0, 0x05, 0x06, 0x07, 0x08]

        let records = try await ReceiverDirectory.readPairings(using: makeClient(receiver), layout: .bolt)
        XCTAssertEqual(records?.mapValues(\.wirelessPID), [1: 0xB034, 2: 0xB084])
        XCTAssertEqual(receiver.pairingReads, [0x51, 0x52, 0x53, 0x54, 0x55, 0x56])
    }

    func testReadPairingsIsNilWhenTheRegisterIsUnsupportedOrSilent() async throws {
        let unsupported = PairingTestReceiver()
        unsupported.registerError = 0x02
        let none = try await ReceiverDirectory.readPairings(using: makeClient(unsupported), layout: .unifying)
        XCTAssertNil(none)
        XCTAssertEqual(unsupported.pairingReads.count, 1)

        let empty = PairingTestReceiver()
        let nothingListed = try await ReceiverDirectory.readPairings(using: makeClient(empty), layout: .unifying)
        XCTAssertNil(nothingListed, "no slot answered with a record")
    }

    func testReadPairingsStopsAtATimeoutKeepingWhatWasRead() async throws {
        let receiver = PairingTestReceiver()
        receiver.pairingReplies[0x20] = [0x20, 0x00, 0x08, 0x40, 0x7B, 0x00, 0x00, 0x02]
        receiver.silentSubRegisters = [0x22]
        receiver.pairingReplies[0x24] = [0x24, 0x00, 0x08, 0x40, 0x82, 0x00, 0x00, 0x02]

        let records = try await ReceiverDirectory.readPairings(using: makeClient(receiver), layout: .unifying)
        XCTAssertEqual(records?.keys.sorted(), [1])
        XCTAssertEqual(receiver.pairingReads, [0x20, 0x21, 0x22])
    }

    func testReadPairingsThrowsWhenTheTransportCloses() async {
        let receiver = PairingTestReceiver()
        let client = makeClient(receiver)
        client.close()
        do {
            _ = try await ReceiverDirectory.readPairings(using: client, layout: .unifying)
            XCTFail("expected transportClosed")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .transportClosed)
        }
    }

    func testNotificationFlagsAreReadModifiedAndWritten() async throws {
        let receiver = PairingTestReceiver()
        receiver.notificationFlags = [0x10, 0x04, 0x00]
        let written = try await ReceiverDirectory.enableNotifications(using: makeClient(receiver))
        XCTAssertEqual(written, [0x10, 0x0D, 0x00])
        XCTAssertEqual(receiver.notificationFlags, [0x10, 0x0D, 0x00])
        XCTAssertEqual(receiver.sent.map(\.subID), [0x81, 0x80], "one read, then one write")
    }

    func testNotificationFlagsFallBackToAPlainWriteWhenUnreadable() async throws {
        let receiver = PairingTestReceiver()
        receiver.notificationFlags = nil
        let written = try await ReceiverDirectory.enableNotifications(using: makeClient(receiver))
        XCTAssertEqual(written, [0x00, 0x09, 0x00])
        XCTAssertEqual(receiver.writes(to: 0x00), [[0x00, 0x09, 0x00]])
    }

    func testReadSerialAndRequestAnnouncements() async throws {
        let receiver = PairingTestReceiver()
        receiver.pairingReplies[0x31] = [0x31, 0x1A, 0x2B, 0x3C, 0x4D, 0x00, 0x00, 0x00]
        let client = makeClient(receiver)
        let serial = try await ReceiverDirectory.readSerial(using: client, slot: 2, layout: .unifying)
        XCTAssertEqual(serial, "1A2B3C4D")
        let missing = try await ReceiverDirectory.readSerial(using: client, slot: 3, layout: .unifying)
        XCTAssertNil(missing)

        try await ReceiverDirectory.requestAnnouncements(using: client)
        XCTAssertEqual(receiver.writes(to: 0x02), [[0x02, 0x00, 0x00]])
    }
}

/// A receiver answering HID++ 1.0 register traffic from tables, synchronously.
private final class PairingTestReceiver: HIDPPTransport, @unchecked Sendable {
    var onReport: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    /// Long register 0xB5 replies by sub-register. Others answer HID++ 1.0 "invalid value".
    var pairingReplies: [UInt8: [UInt8]] = [:]
    /// Sub-registers that never answer.
    var silentSubRegisters: Set<UInt8> = []
    /// Answers every 0xB5 read with this HID++ 1.0 error.
    var registerError: UInt8?
    /// Register 0x00; nil refuses reads.
    var notificationFlags: [UInt8]? = [0x00, 0x00, 0x00]
    private(set) var sent: [HIDPPMessage] = []

    var pairingReads: [UInt8] {
        sent.filter { $0.subID == 0x83 && $0.address == 0xB5 }.map { $0.parameters[0] }
    }

    func writes(to register: UInt8) -> [[UInt8]] {
        sent.filter { $0.subID == 0x80 && $0.address == register }.map { Array($0.parameters.prefix(3)) }
    }

    func send(_ bytes: [UInt8]) throws {
        guard let request = HIDPPMessage(bytes: bytes) else { return }
        sent.append(request)
        if let reply = respond(to: request) { onReport?(reply.bytes) }
    }

    private func respond(to request: HIDPPMessage) -> HIDPPMessage? {
        let p = request.parameters
        switch (request.subID, request.address) {
        case (0x81, 0x00):
            guard let notificationFlags else { return error(request, 0x02) }
            return HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x81, address: 0x00, parameters: notificationFlags)
        case (0x80, let register):
            if register == 0x00 { notificationFlags = Array(p.prefix(3)) }
            return HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x80, address: register)
        case (0x83, 0xB5):
            if let registerError { return error(request, registerError) }
            if silentSubRegisters.contains(p[0]) { return nil }
            guard let reply = pairingReplies[p[0]] else { return error(request, 0x03) }
            return HIDPPMessage(reportID: .long, deviceIndex: 0xFF, subID: 0x83, address: 0xB5, parameters: reply)
        default:
            return error(request, 0x01)
        }
    }

    private func error(_ request: HIDPPMessage, _ code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: request.deviceIndex, subID: 0x8F, address: request.subID, parameters: [request.address, code])
    }
}
