import Foundation

/// HID++ report IDs. Every HID++ message starts with one of these.
public enum HIDPPReportID: UInt8, Sendable {
    case short = 0x10
    case long = 0x11
    case veryLong = 0x12

    public var length: Int {
        switch self {
        case .short: return 7
        case .long: return 20
        case .veryLong: return 64
        }
    }
}

/// A single HID++ 1.0 or 2.0 message.
///
/// Wire layout (all report types):
///
///     byte 0   report ID (0x10 short, 0x11 long, 0x12 very long)
///     byte 1   device index (0xFF = directly connected, 0x01...0x06 = receiver slot)
///     byte 2   HID++ 2.0: feature index      HID++ 1.0: sub-ID
///     byte 3   HID++ 2.0: function << 4 | software ID      HID++ 1.0: register address
///     byte 4+  parameters
public struct HIDPPMessage: Equatable, Sendable, CustomStringConvertible {
    public var reportID: HIDPPReportID
    public var deviceIndex: UInt8
    public var subID: UInt8
    public var address: UInt8
    public private(set) var parameters: [UInt8]

    public init(reportID: HIDPPReportID, deviceIndex: UInt8, subID: UInt8, address: UInt8, parameters: [UInt8] = []) {
        self.reportID = reportID
        self.deviceIndex = deviceIndex
        self.subID = subID
        self.address = address
        let count = reportID.length - 4
        self.parameters = Array((parameters + Array(repeating: 0, count: count)).prefix(count))
    }

    /// Parses a raw report (including the leading report ID byte).
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 4, let reportID = HIDPPReportID(rawValue: bytes[0]) else { return nil }
        self.init(reportID: reportID, deviceIndex: bytes[1], subID: bytes[2], address: bytes[3], parameters: Array(bytes.dropFirst(4)))
    }

    public var bytes: [UInt8] { [reportID.rawValue, deviceIndex, subID, address] + parameters }

    // MARK: HID++ 2.0 accessors

    public var featureIndex: UInt8 { subID }
    public var function: UInt8 { address >> 4 }
    public var softwareID: UInt8 { address & 0x0F }

    /// Builds a HID++ 2.0 feature request.
    public static func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        softwareID: UInt8,
        parameters: [UInt8] = [],
        reportID: HIDPPReportID = .long
    ) -> HIDPPMessage {
        HIDPPMessage(
            reportID: reportID,
            deviceIndex: deviceIndex,
            subID: featureIndex,
            address: (function << 4) | (softwareID & 0x0F),
            parameters: parameters
        )
    }

    // MARK: HID++ 1.0 receiver registers

    /// Short register write (sub-ID 0x80) addressed to the receiver itself.
    public static func receiverRegisterWrite(_ address: UInt8, parameters: [UInt8]) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x80, address: address, parameters: parameters)
    }

    /// Long register read (sub-ID 0x83) addressed to the receiver itself.
    public static func receiverLongRegisterRead(_ address: UInt8, parameters: [UInt8]) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x83, address: address, parameters: parameters)
    }

    // MARK: Response matching

    public enum ResponseMatch: Equatable, Sendable {
        case success
        case hidpp10Error(UInt8)
        case hidpp20Error(UInt8)
    }

    static let hidpp10ErrorSubID: UInt8 = 0x8F
    static let hidpp20ErrorSubID: UInt8 = 0xFF

    /// Returns how (and whether) this message answers `request`.
    ///
    /// Successful replies echo the request's device index, sub-ID and address. Errors carry
    /// the original sub-ID and address in bytes 3 and 4, and the error code in byte 5.
    public func match(to request: HIDPPMessage) -> ResponseMatch? {
        guard deviceIndex == request.deviceIndex else { return nil }
        if subID == request.subID && address == request.address {
            return .success
        }
        if subID == Self.hidpp20ErrorSubID, address == request.subID, parameters[0] == request.address {
            return .hidpp20Error(parameters[1])
        }
        if subID == Self.hidpp10ErrorSubID, address == request.subID, parameters[0] == request.address {
            return .hidpp10Error(parameters[1])
        }
        return nil
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension Array where Element == UInt8 {
    /// Reads a big-endian UInt16 at `offset`, returning 0 when out of range.
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}
