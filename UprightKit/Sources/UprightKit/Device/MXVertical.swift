import Foundation

/// How the mouse reaches the Mac.
public enum ConnectionKind: String, Hashable, Sendable {
    case usb
    case bluetooth
    case unifying
    case bolt
    case nano

    public var title: String {
        switch self {
        case .usb: return NSLocalizedString("USB cable", comment: "How the mouse connects to the Mac")
        case .bluetooth: return NSLocalizedString("Bluetooth", comment: "How the mouse connects to the Mac")
        case .unifying: return NSLocalizedString("Unifying receiver", comment: "How the mouse connects to the Mac")
        case .bolt: return NSLocalizedString("Bolt receiver", comment: "How the mouse connects to the Mac")
        case .nano: return NSLocalizedString("Nano receiver", comment: "How the mouse connects to the Mac")
        }
    }

    public var symbolName: String {
        switch self {
        case .usb: return "cable.connector"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .unifying, .bolt, .nano: return "antenna.radiowaves.left.and.right"
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

    /// The MX Vertical pairs over Unifying or Bluetooth only. Bolt receivers are still watched
    /// (harmlessly) so a future Bolt-capable model, or a mislabeled one, is picked up.
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

extension KnownControl {
    /// The MX Vertical's remappable buttons, shown before a mouse has been detected.
    public static let mxVerticalDefaults: [UInt16] = [back, forward, dpiSwitch, middleClick]
}
