import Foundation

/// Where a receiver lists its pairings (HID++ 1.0 long register 0xB5). Layouts follow Solaar
/// (`receiver.py`); the Bolt one is simulator-tested only.
public enum PairingLayout: Hashable, Sendable {
    /// Sub-register 0x20 + (slot - 1): [sub, destination ID, interval, wpid hi, wpid lo, ?, ?, kind].
    /// Extended pairing information (serial number in bytes 1...4) at 0x30 + (slot - 1).
    /// Nano receivers use it too.
    case unifying
    /// Sub-register 0x50 + slot (not slot - 1): [sub, kind, wpid lo, wpid hi, serial (4), ...].
    case bolt

    public func pairingSubRegister(slot: UInt8) -> UInt8 {
        switch self {
        case .unifying: return 0x20 + slot - 1
        case .bolt: return 0x50 + slot
        }
    }

    /// The sub-register holding the slot's serial number. Bolt keeps it in the pairing record.
    public func serialSubRegister(slot: UInt8) -> UInt8 {
        switch self {
        case .unifying: return 0x30 + slot - 1
        case .bolt: return 0x50 + slot
        }
    }
}

/// One occupied receiver slot.
public struct PairingRecord: Hashable, Sendable {
    public var slot: UInt8
    public var wirelessPID: UInt16
    public var kind: DeviceKind

    public init(slot: UInt8, wirelessPID: UInt16, kind: DeviceKind) {
        self.slot = slot
        self.wirelessPID = wirelessPID
        self.kind = kind
    }
}

/// Receiver registers and notifications used by `HIDPPLink`: value-level parsing, the request
/// messages, and the receiver-wide reads and writes built on them.
public enum ReceiverDirectory {
    /// Receiver slots. Always all six, whatever the receiver says its capacity is.
    public static let slots: ClosedRange<UInt8> = 1...6

    /// Long register 0xB5 (RECEIVER_INFO): pairing information by sub-register.
    public static let pairingRegister: UInt8 = 0xB5
    /// Register 0x00: notification flags, 3 bytes big-endian.
    public static let notificationFlagsRegister: UInt8 = 0x00
    /// Register 0x02: writing 0x02 makes the receiver send a 0x41 for every paired device.
    public static let connectionRegister: UInt8 = 0x02

    // MARK: Parsing

    /// Parses the parameters of a pairing-information read for `slot`. Nil for an empty slot,
    /// a reply for another sub-register, or a short reply.
    public static func parsePairing(_ reply: [UInt8], slot: UInt8, layout: PairingLayout) -> PairingRecord? {
        guard slots.contains(slot), reply.count >= 8, reply[0] == layout.pairingSubRegister(slot: slot) else { return nil }
        let pid: UInt16
        let kind: DeviceKind
        switch layout {
        case .unifying:
            pid = UInt16(reply[3]) << 8 | UInt16(reply[4])
            kind = DeviceKind(hidpp10Nibble: reply[7])
        case .bolt:
            pid = UInt16(reply[3]) << 8 | UInt16(reply[2])
            kind = DeviceKind(hidpp10Nibble: reply[1])
        }
        guard pid != 0 else { return nil }
        return PairingRecord(slot: slot, wirelessPID: pid, kind: kind)
    }

    /// The serial number ("1A2B3C4D") in the parameters of a `serialSubRegister(slot:)` read:
    /// bytes 1...4 on Unifying and Nano, bytes 4...7 on Bolt. Nil when absent or blank.
    public static func parseSerial(_ reply: [UInt8], slot: UInt8, layout: PairingLayout) -> String? {
        guard slots.contains(slot), reply.count >= 8, reply[0] == layout.serialSubRegister(slot: slot) else { return nil }
        let bytes: ArraySlice<UInt8>
        switch layout {
        case .unifying: bytes = reply[1...4]
        case .bolt: bytes = reply[4...7]
        }
        guard bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 0xFF }) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// A 0x41 device-connection notification: params[0] bit 6 set = link lost, low nibble = kind;
    /// params[1...2] = wireless PID (little-endian). Unifying, Nano and Bolt share the layout.
    public static func parseConnection(_ m: HIDPPMessage) -> (slot: UInt8, wirelessPID: UInt16, kind: DeviceKind, linkUp: Bool)? {
        guard m.subID == 0x41, slots.contains(m.deviceIndex) else { return nil }
        let p = m.parameters
        let pid = UInt16(p[2]) << 8 | UInt16(p[1])
        return (m.deviceIndex, pid, DeviceKind(hidpp10Nibble: p[0]), p[0] & 0x40 == 0)
    }

    /// The slot of a 0x40 device-disconnection notification with the un-paired bit, else nil.
    public static func isUnpair(_ m: HIDPPMessage) -> UInt8? {
        guard m.subID == 0x40, slots.contains(m.deviceIndex), m.address & 0x02 != 0 else { return nil }
        return m.deviceIndex
    }

    /// Register 0x00 (notification flags) read-modify-write: keeps every flag already set and
    /// adds wireless (0x000100) and software-present (0x000800) notifications.
    public static func mergedNotificationFlags(current: [UInt8]) -> [UInt8] {
        var flags = Array((current + [0, 0, 0]).prefix(3))
        flags[1] |= 0x09
        return flags
    }

    // MARK: Messages (all addressed to the receiver, device index 0xFF)

    public static func pairingReadMessage(slot: UInt8, layout: PairingLayout) -> HIDPPMessage {
        .receiverLongRegisterRead(pairingRegister, parameters: [layout.pairingSubRegister(slot: slot)])
    }

    public static func serialReadMessage(slot: UInt8, layout: PairingLayout) -> HIDPPMessage {
        .receiverLongRegisterRead(pairingRegister, parameters: [layout.serialSubRegister(slot: slot)])
    }

    /// Short register read (sub-ID 0x81) of the notification flags.
    public static var notificationFlagsReadMessage: HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x81, address: notificationFlagsRegister)
    }

    public static func notificationFlagsWriteMessage(_ flags: [UInt8]) -> HIDPPMessage {
        .receiverRegisterWrite(notificationFlagsRegister, parameters: flags)
    }

    public static var announcementRequestMessage: HIDPPMessage {
        .receiverRegisterWrite(connectionRegister, parameters: [0x02, 0x00, 0x00])
    }

    // MARK: Receiver operations

    /// Reads the pairing record of every slot. Reading doesn't wake any device.
    ///
    /// Returns the occupied slots, or nil when the table can't be read: the receiver rejects the
    /// register (invalid sub-ID or address) or no slot gave a well-formed answer. Any other HID++
    /// 1.0 error means an empty slot. Stops at the first timeout, keeping what was read.
    /// Only a closed transport throws.
    public static func readPairings(using client: HIDPPClient, layout: PairingLayout, timeout: TimeInterval? = nil) async throws -> [UInt8: PairingRecord]? {
        var records: [UInt8: PairingRecord] = [:]
        var listed = false
        for slot in slots {
            do {
                let reply = try await client.send(pairingReadMessage(slot: slot, layout: layout), timeout: timeout)
                guard reply.parameters[0] == layout.pairingSubRegister(slot: slot) else { continue }
                listed = true
                records[slot] = parsePairing(reply.parameters, slot: slot, layout: layout)
            } catch HIDPPError.transportClosed {
                throw HIDPPError.transportClosed
            } catch HIDPPError.hidpp10(let code) where code == 0x01 || code == 0x02 {
                return nil
            } catch HIDPPError.hidpp10 {
                continue
            } catch {
                break
            }
        }
        return listed ? records : nil
    }

    /// The slot's serial number from the receiver, or nil when it doesn't keep one.
    /// Only a closed transport throws.
    public static func readSerial(using client: HIDPPClient, slot: UInt8, layout: PairingLayout, timeout: TimeInterval? = nil) async throws -> String? {
        do {
            let reply = try await client.send(serialReadMessage(slot: slot, layout: layout), timeout: timeout)
            return parseSerial(reply.parameters, slot: slot, layout: layout)
        } catch HIDPPError.transportClosed {
            throw HIDPPError.transportClosed
        } catch {
            return nil
        }
    }

    /// Turns on wireless and software-present notifications without clearing flags another
    /// program set: reads register 0x00 and writes back `mergedNotificationFlags`. A receiver that
    /// refuses the read gets the two flags alone. Returns the flags written; throws when the
    /// write fails.
    @discardableResult
    public static func enableNotifications(using client: HIDPPClient, timeout: TimeInterval? = nil) async throws -> [UInt8] {
        var current: [UInt8] = []
        do {
            let reply = try await client.send(notificationFlagsReadMessage, timeout: timeout)
            current = Array(reply.parameters.prefix(3))
        } catch HIDPPError.transportClosed {
            throw HIDPPError.transportClosed
        } catch {
            current = []
        }
        let flags = mergedNotificationFlags(current: current)
        _ = try await client.send(notificationFlagsWriteMessage(flags), timeout: timeout)
        return flags
    }

    /// Asks the receiver to announce every paired device with a 0x41 notification.
    public static func requestAnnouncements(using client: HIDPPClient, timeout: TimeInterval? = nil) async throws {
        _ = try await client.send(announcementRequestMessage, timeout: timeout)
    }
}
