import Foundation

/// Where a live endpoint is reachable: the opened HID interface (`link`) and the device index
/// on it. Unique among live endpoints and known before the device is identified, so it routes
/// events, engine state and device actions. Never persisted; see `DeviceID` for that.
public struct DeviceAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Per opened IOHIDDevice, monotonic, never reused within a process. 0 is unassigned.
    public var link: UInt32
    /// Receiver slot 1...6, or `DeviceAddress.direct` (0xFF) for a directly connected device.
    public var index: UInt8

    public init(link: UInt32, index: UInt8) {
        self.link = link
        self.index = index
    }

    /// Events from code paths that don't know their device (legacy single-mouse callers).
    public static let unassigned = DeviceAddress(link: 0, index: 0xFF)
    /// The device index of a directly connected device (USB cable or Bluetooth).
    public static let direct: UInt8 = 0xFF

    public var isDirect: Bool { index == Self.direct }

    public static func < (lhs: DeviceAddress, rhs: DeviceAddress) -> Bool {
        lhs.link != rhs.link ? lhs.link < rhs.link : lhs.index < rhs.index
    }

    /// "3.2" for slot 2 of link 3, "3.direct" for a direct link.
    public var description: String {
        isDirect ? "\(link).direct" : "\(link).\(index)"
    }
}

/// Identifies a mouse model, independent of how it is connected. Mappings, catalog lookups and
/// control names are keyed by it.
///
/// The canonical form is `"046D:XXXX"`, where XXXX is the model's first product ID among
/// Bluetooth, Bluetooth LE, wireless (receiver) and USB as reported by DEVICE_FW_VERSION
/// (0x0003). A device that reports none falls back to `"name:<lowercased name>"`.
public struct ModelKey: RawRepresentable, Hashable, Codable, Comparable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public var rawValue: String

    /// Accepts `"VVVV:PPPP"` (hex, normalized to upper case) or `"name:<non-empty>"`.
    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.namePrefix) {
            guard rawValue.count > Self.namePrefix.count else { return nil }
            self.rawValue = rawValue
            return
        }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        self.rawValue = rawValue.uppercased()
    }

    /// A Logitech model by product ID: `"046D:%04X"`.
    public init(productID: UInt16) {
        rawValue = Self.hex4(DeviceCatalog.vendorID) + ":" + Self.hex4(Int(productID))
    }

    private static func hex4(_ value: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// The last-resort key for a device that reports no product IDs.
    public init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rawValue = Self.namePrefix + (trimmed.isEmpty ? "unknown" : trimmed)
    }

    public static let mxVertical = ModelKey(productID: 0xB020)

    private static let namePrefix = "name:"

    /// The product ID of a canonical key, or nil for a name key.
    public var productID: UInt16? {
        guard !rawValue.hasPrefix(Self.namePrefix), let pid = rawValue.split(separator: ":").last else { return nil }
        return UInt16(pid, radix: 16)
    }

    public static func < (lhs: ModelKey, rhs: ModelKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }
}

/// The model product IDs a device reports in DEVICE_FW_VERSION (0x0003) function 0.
public struct ModelIDs: Hashable, Sendable {
    public var bluetooth: UInt16?
    public var bluetoothLE: UInt16?
    /// The "wireless PID" a Unifying, Nano or Lightspeed receiver reports for the device.
    public var wireless: UInt16?
    public var usb: UInt16?

    public init(bluetooth: UInt16? = nil, bluetoothLE: UInt16? = nil, wireless: UInt16? = nil, usb: UInt16? = nil) {
        self.bluetooth = bluetooth
        self.bluetoothLE = bluetoothLE
        self.wireless = wireless
        self.usb = usb
    }

    /// The product ID a `ModelKey` is built from: the same on every transport.
    public var canonical: UInt16? { bluetooth ?? bluetoothLE ?? wireless ?? usb }

    /// Every reported ID, in canonical order.
    public var all: [UInt16] { [bluetooth, bluetoothLE, wireless, usb].compactMap { $0 } }

    public var isEmpty: Bool { all.isEmpty }
}

/// Identifies one physical unit across connections, for per-mouse preferences and same-unit
/// deduplication. It never routes events (`DeviceAddress` does).
///
/// Forms: `"u:<model>:<unit ID, 8 hex>"` from 0x0003, `"s:<model>:<serial>"`, or
/// `"t:<link>.<index>"` when the device reports neither. Transient IDs are never persisted.
public struct DeviceID: RawRepresentable, Hashable, Codable, Comparable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func unit(_ unitID: UInt32, model: ModelKey) -> DeviceID {
        let digits = String(unitID, radix: 16, uppercase: true)
        return DeviceID(rawValue: "u:\(model.rawValue):" + String(repeating: "0", count: 8 - digits.count) + digits)
    }

    public static func serial(_ serial: String, model: ModelKey) -> DeviceID {
        DeviceID(rawValue: "s:\(model.rawValue):\(serial)")
    }

    public static func transient(_ address: DeviceAddress) -> DeviceID {
        DeviceID(rawValue: "t:\(address.link).\(address.index)")
    }

    /// False for transient IDs, which must not key anything that outlives the connection.
    public var isStable: Bool { !rawValue.hasPrefix("t:") }

    /// The model embedded in a stable ID.
    public var model: ModelKey? {
        guard rawValue.hasPrefix("u:") || rawValue.hasPrefix("s:") else { return nil }
        let parts = rawValue.dropFirst(2).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return ModelKey(rawValue: String(parts[0]) + ":" + String(parts[1]))
    }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }
}

/// What kind of device sits behind an endpoint, from DEVICE_NAME (0x0005) function 2 or the
/// receiver's pairing information.
public enum DeviceKind: Hashable, Sendable {
    case keyboard, remote, numpad, mouse, touchpad, trackball, presenter, receiver
    case other(UInt8)
    case unknown

    /// HID++ 2.0 DEVICE_NAME getDeviceType (0x0005 function 2).
    public init(hidpp20 value: UInt8) {
        switch value {
        case 0: self = .keyboard
        case 1: self = .remote
        case 2: self = .numpad
        case 3: self = .mouse
        case 4: self = .touchpad
        case 5: self = .trackball
        case 6: self = .presenter
        case 7: self = .receiver
        default: self = .other(value)
        }
    }

    /// HID++ 1.0 device kind nibble, from a pairing record or a 0x41 notification. Only the
    /// low nibble is used.
    public init(hidpp10Nibble value: UInt8) {
        let nibble = value & 0x0F
        switch nibble {
        case 0: self = .unknown
        case 1: self = .keyboard
        case 2: self = .mouse
        case 3: self = .numpad
        case 4: self = .presenter
        case 7: self = .remote
        case 8: self = .trackball
        case 9: self = .touchpad
        default: self = .other(nibble)
        }
    }

    public var isPointer: Bool {
        switch self {
        case .mouse, .touchpad, .trackball: return true
        default: return false
        }
    }

    /// Kinds that are never served (the anti-hijack gate). `.unknown` and `.other` are not
    /// in this set: they are decided by the device's own answers.
    public var isDefinitelyNotPointer: Bool {
        switch self {
        case .keyboard, .numpad, .presenter, .remote, .receiver: return true
        default: return false
        }
    }

    /// A short English name for logs and device reports.
    public var name: String {
        switch self {
        case .keyboard: return "keyboard"
        case .remote: return "remote control"
        case .numpad: return "numpad"
        case .mouse: return "mouse"
        case .touchpad: return "touchpad"
        case .trackball: return "trackball"
        case .presenter: return "presenter"
        case .receiver: return "receiver"
        case .other(let value): return String(format: "kind 0x%02X", value)
        case .unknown: return "unknown"
        }
    }
}

/// Who a device is, as far as Upright can tell from its HID++ answers.
public struct DeviceIdentity: Hashable, Sendable {
    public var name: String
    public var kind: DeviceKind
    /// Nil when the device doesn't report one, or reports zero.
    public var unitID: UInt32?
    public var serialNumber: String?
    public var modelIDs: ModelIDs
    public var extendedModelID: UInt8?
    /// The wireless PID on a receiver, or the IOHID product ID on a direct link.
    public var transportPID: UInt16?
    public var model: ModelKey

    /// `model` defaults to `DeviceCatalog.modelKey(for:)`, which never reads `model` itself.
    public init(
        name: String,
        kind: DeviceKind = .unknown,
        unitID: UInt32? = nil,
        serialNumber: String? = nil,
        modelIDs: ModelIDs = ModelIDs(),
        extendedModelID: UInt8? = nil,
        transportPID: UInt16? = nil,
        model: ModelKey? = nil
    ) {
        self.name = name
        self.kind = kind
        self.unitID = unitID == 0 ? nil : unitID
        self.serialNumber = serialNumber.flatMap { $0.isEmpty ? nil : $0 }
        self.modelIDs = modelIDs
        self.extendedModelID = extendedModelID
        self.transportPID = transportPID
        self.model = .mxVertical
        self.model = model ?? DeviceCatalog.modelKey(for: self)
    }

    /// The unit ID, else the serial number, else a transient ID for this connection.
    public func deviceID(at address: DeviceAddress) -> DeviceID {
        if let unitID { return .unit(unitID, model: model) }
        if let serialNumber { return .serial(serialNumber, model: model) }
        return .transient(address)
    }

    /// Parses the parameters of a DEVICE_FW_VERSION getEntityCount reply (0x0003 function 0):
    /// [entity count, unit ID (4), transport (2), model IDs (6), extended model ID].
    /// Byte 6 holds the transport bits (Bluetooth 0x01, BLE 0x02, wireless 0x04, USB 0x08);
    /// one big-endian ID per set bit is packed into bytes 7...12 in that order.
    public static func parseFirmwareIDs(_ reply: [UInt8]) -> (unitID: UInt32?, modelIDs: ModelIDs, extendedModelID: UInt8?)? {
        guard reply.count >= 13 else { return nil }
        let unit = reply[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let bits = reply[6]
        var ids = ModelIDs()
        var offset = 7
        func next() -> UInt16? {
            defer { offset += 2 }
            guard offset + 1 <= 12 else { return nil }
            let value = UInt16(reply[offset]) << 8 | UInt16(reply[offset + 1])
            return value == 0 ? nil : value
        }
        if bits & 0x01 != 0 { ids.bluetooth = next() }
        if bits & 0x02 != 0 { ids.bluetoothLE = next() }
        if bits & 0x04 != 0 { ids.wireless = next() }
        if bits & 0x08 != 0 { ids.usb = next() }
        let extended: UInt8? = reply.count > 13 ? reply[13] : nil
        return (unit == 0 ? nil : unit, ids, extended)
    }
}

/// Why an endpoint is not served. Terminal: no retry, no writes, never diverted.
public enum UnsupportedReason: Hashable, Sendable {
    /// The device answers HID++ 1.0 only.
    case hidpp10(major: UInt8, minor: UInt8)
    /// A keyboard, numpad, presenter, remote or receiver.
    case notAPointer(DeviceKind)
    /// No REPROG_CONTROLS_V4 (0x1B04).
    case noReprogControls
    /// 0x1B04 is present but lists no control Upright can divert.
    case noConfigurableControls

    /// User-facing, localized.
    public var message: String {
        switch self {
        case .hidpp10(let major, let minor):
            return String(format: NSLocalizedString("Older HID++ %d.%d device; Upright needs HID++ 2.0", comment: "Why a Logitech device isn't supported; %d.%d is its protocol version"), Int(major), Int(minor))
        case .notAPointer(let kind):
            switch kind {
            case .keyboard: return NSLocalizedString("Keyboard; Upright only configures mice", comment: "Why a Logitech device isn't supported")
            default: return NSLocalizedString("Not a mouse; Upright only configures mice", comment: "Why a Logitech device isn't supported")
            }
        case .noReprogControls:
            return NSLocalizedString("No programmable buttons", comment: "Why a Logitech device isn't supported")
        case .noConfigurableControls:
            return NSLocalizedString("No buttons Upright can remap", comment: "Why a Logitech device isn't supported")
        }
    }
}

/// What one endpoint should be doing: the controls diverted to Upright, those that also
/// report raw movement while held, and the pointer speed to keep (nil leaves it alone).
public struct EndpointConfiguration: Hashable, Sendable {
    public var divert: Set<UInt16> = []
    public var rawXY: Set<UInt16> = []
    public var dpi: Int? = nil

    public init(divert: Set<UInt16> = [], rawXY: Set<UInt16> = [], dpi: Int? = nil) {
        self.divert = divert
        self.rawXY = rawXY
        self.dpi = dpi
    }

    /// Nothing diverted, pointer speed left to the mouse.
    public static let native = EndpointConfiguration()
}
