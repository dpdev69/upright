import Foundation

/// How the mouse reaches the Mac.
public enum ConnectionKind: String, Hashable, Sendable {
    case usb
    case bluetooth
    case unifying
    case bolt

    public var title: String {
        switch self {
        case .usb: return "USB cable"
        case .bluetooth: return "Bluetooth"
        case .unifying: return "Unifying receiver"
        case .bolt: return "Bolt receiver"
        }
    }

    public var symbolName: String {
        switch self {
        case .usb: return "cable.connector"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .unifying, .bolt: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// What sits on the other end of a HID interface.
public enum TransportKind: Hashable, Sendable {
    /// A receiver; the mouse lives in one of its slots (device index 1...6).
    case receiver(ConnectionKind)
    /// The mouse itself over USB or Bluetooth (device index 0xFF).
    case direct(ConnectionKind)

    public var connection: ConnectionKind {
        switch self {
        case .receiver(let kind), .direct(let kind): return kind
        }
    }
}

/// Identification data for the Logitech MX Vertical. Product IDs match those published by
/// Solaar and the Linux hid-logitech-dj driver.
public enum MXVertical {
    public static let vendorID = 0x046D
    public static let usbProductID = 0xC08A
    public static let bluetoothProductID = 0xB020
    /// The "wireless PID" a receiver reports for an MX Vertical in one of its slots.
    public static let wirelessProductID: UInt16 = 0x407B

    public static let receiverProductIDs: [Int: ConnectionKind] = [
        0xC52B: .unifying,
        0xC532: .unifying,
        0xC548: .bolt,
    ]

    /// Classifies a Logitech HID interface by vendor and product ID.
    public static func classify(vendorID: Int, productID: Int) -> TransportKind? {
        guard vendorID == Self.vendorID else { return nil }
        if let receiver = receiverProductIDs[productID] { return .receiver(receiver) }
        switch productID {
        case usbProductID: return .direct(.usb)
        case bluetoothProductID: return .direct(.bluetooth)
        default: return nil
        }
    }

    public static func matches(name: String) -> Bool {
        name.lowercased().contains("mx vertical")
    }

    public static let displayName = "MX Vertical"
}

/// Control IDs (CIDs) used by REPROG_CONTROLS_V4, as listed in Solaar's special_keys table
/// and LogiOps' MX Vertical example configuration.
public enum KnownControl {
    public static let leftClick: UInt16 = 0x0050
    public static let rightClick: UInt16 = 0x0051
    public static let middleClick: UInt16 = 0x0052
    public static let back: UInt16 = 0x0053
    public static let forward: UInt16 = 0x0056
    public static let dpiChange: UInt16 = 0x00ED
    public static let dpiSwitch: UInt16 = 0x00FD

    public static let primaryClicks: Set<UInt16> = [leftClick, rightClick]

    /// The MX Vertical's remappable buttons, shown before a mouse has been detected.
    public static let mxVerticalDefaults: [UInt16] = [back, forward, dpiSwitch, middleClick]
}

/// User-facing description of a control.
public struct ControlDescriptor: Hashable, Sendable, Identifiable {
    public var cid: UInt16
    public var name: String
    public var detail: String
    public var symbolName: String

    public var id: UInt16 { cid }

    public init(cid: UInt16) {
        self.cid = cid
        switch cid {
        case KnownControl.back:
            name = "Back Button"
            detail = "Lower thumb button"
            symbolName = "chevron.backward.circle"
        case KnownControl.forward:
            name = "Forward Button"
            detail = "Upper thumb button"
            symbolName = "chevron.forward.circle"
        case KnownControl.dpiSwitch, KnownControl.dpiChange:
            name = "Top Button"
            detail = "Pointer-speed (DPI) button behind the wheel"
            symbolName = "speedometer"
        case KnownControl.middleClick:
            name = "Wheel Click"
            detail = "Press the scroll wheel"
            symbolName = "smallcircle.filled.circle"
        default:
            name = String(format: "Control 0x%04X", cid)
            detail = "Additional programmable control"
            symbolName = "button.programmable"
        }
    }

    public var hexID: String { String(format: "0x%04X", cid) }
}
