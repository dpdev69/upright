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

/// Display name of the original model. Device identification lives in `DeviceCatalog` and
/// `InterfaceClassifier`.
public enum MXVertical {
    public static let displayName = "MX Vertical"
}
