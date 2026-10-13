import Foundation

// Wave 0 scaffold: final signatures. W1.3 owns this file (parsing tests, Bolt details).

/// Where a receiver lists its pairings (HID++ 1.0 long register 0xB5).
public enum PairingLayout: Hashable, Sendable {
    /// Sub-register 0x20 + (slot - 1): [sub, destination ID, interval, wpid hi, wpid lo, ?, ?, kind].
    /// Nano receivers use it too.
    case unifying
    /// Sub-register 0x50 + slot: [sub, kind, wpid lo, wpid hi, ...].
    case bolt

    public func pairingSubRegister(slot: UInt8) -> UInt8 {
        switch self {
        case .unifying: return 0x20 + slot - 1
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

/// Value-level parsing of receiver registers and notifications, used by `HIDPPLink`.
public enum ReceiverDirectory {
    /// Parses the parameters of a pairing-information read for `slot`. Nil for an empty slot,
    /// a reply for another sub-register, or a short reply.
    public static func parsePairing(_ reply: [UInt8], slot: UInt8, layout: PairingLayout) -> PairingRecord? {
        guard (1...6).contains(slot), reply.count >= 8, reply[0] == layout.pairingSubRegister(slot: slot) else { return nil }
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

    /// A 0x41 device-connection notification: params[0] bit 6 set = link lost, low nibble = kind;
    /// params[1...2] = wireless PID (little-endian).
    public static func parseConnection(_ m: HIDPPMessage) -> (slot: UInt8, wirelessPID: UInt16, kind: DeviceKind, linkUp: Bool)? {
        guard m.subID == 0x41, (1...6).contains(m.deviceIndex) else { return nil }
        let p = m.parameters
        let pid = UInt16(p[2]) << 8 | UInt16(p[1])
        return (m.deviceIndex, pid, DeviceKind(hidpp10Nibble: p[0]), p[0] & 0x40 == 0)
    }

    /// The slot of a 0x40 device-disconnection notification with the un-paired bit, else nil.
    public static func isUnpair(_ m: HIDPPMessage) -> UInt8? {
        guard m.subID == 0x40, (1...6).contains(m.deviceIndex), m.address & 0x02 != 0 else { return nil }
        return m.deviceIndex
    }

    /// Register 0x00 (notification flags) read-modify-write: keeps every flag already set and
    /// adds wireless (0x000100) and software-present (0x000800) notifications.
    public static func mergedNotificationFlags(current: [UInt8]) -> [UInt8] {
        var flags = Array((current + [0, 0, 0]).prefix(3))
        flags[1] |= 0x09
        return flags
    }
}
