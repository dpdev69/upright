import Foundation

// Decides which matched HID interfaces Upright opens (design D9 and the twin rules).
// Foundation-only and Linux-safe; the IOKit side (Platform/IOKitHID.swift) only builds descriptors.

/// The IOKit properties of one HID interface, as plain values (Linux-safe).
public struct HIDInterfaceDescriptor: Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    /// The IOHID `Transport` string: "USB", "Bluetooth", "Bluetooth Low Energy", ...
    /// Empty when unknown; the classifier then judges by product ID alone.
    public var transport: String
    public var usagePage: Int
    public var usage: Int
    public var locationID: Int
    public var serial: String
    /// IORegistryEntryGetRegistryEntryID of the device service; unique per interface.
    public var registryID: UInt64
    public var productName: String

    public init(
        vendorID: Int,
        productID: Int,
        transport: String = "",
        usagePage: Int = 0,
        usage: Int = 0,
        locationID: Int = 0,
        serial: String = "",
        registryID: UInt64 = 0,
        productName: String = ""
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.usagePage = usagePage
        self.usage = usage
        self.locationID = locationID
        self.serial = serial
        self.registryID = registryID
        self.productName = productName
    }

    /// Receivers and the USB cable publish a dedicated vendor-page HID++ interface.
    public var isVendorHIDPP: Bool {
        usagePage == 0xFF00 || usagePage == 0xFF43
    }

    /// True for a descriptor built from a product ID alone (no usage information).
    public var hasUnknownUsage: Bool {
        usagePage == 0 && usage == 0
    }

    /// The serial number without surrounding whitespace; empty when the device has none.
    public var normalizedSerial: String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line for logs: "MX Vertical [046D:B020] via Bluetooth Low Energy, usage 0001:0002".
    public var summary: String {
        let name = productName.isEmpty ? "Logitech device" : productName
        let via = transport.isEmpty ? "" : " via " + transport
        return "\(name) [\(InterfaceClassifier.hex(vendorID, width: 4)):\(InterfaceClassifier.hex(productID, width: 4))]\(via), usage \(InterfaceClassifier.hex(usagePage, width: 4)):\(InterfaceClassifier.hex(usage, width: 4))"
    }
}

/// One entry of the matching dictionary the IOKit monitor registers. `usage == nil` matches
/// every usage on the page.
public struct HIDMatchCriterion: Hashable, Sendable {
    public var vendorID: Int
    public var usagePage: Int
    public var usage: Int?

    public init(vendorID: Int, usagePage: Int, usage: Int? = nil) {
        self.vendorID = vendorID
        self.usagePage = usagePage
        self.usage = usage
    }
}

/// What to do with a matched HID interface.
public enum InterfaceClass: Hashable, Sendable {
    /// A receiver: open it and serve the mice in its slots.
    case receiver(ConnectionKind, PairingLayout)
    /// A mouse connected by cable or Bluetooth (device index 0xFF).
    case direct(ConnectionKind)
    /// Never opened; the reason is logged once.
    case ignored(String)

    public var transportKind: TransportKind? {
        switch self {
        case .receiver(let kind, _): return .receiver(kind)
        case .direct(let kind): return .direct(kind)
        case .ignored: return nil
        }
    }

    /// Why the interface is left alone; nil when it is opened.
    public var ignoredReason: String? {
        if case .ignored(let reason) = self { return reason }
        return nil
    }
}

public enum InterfaceClassifier {
    // MARK: Matching

    /// What the IOKit monitor asks macOS to match: the vendor pages that carry HID++ on
    /// receivers, the USB cable and Bluetooth LE, plus every Logitech mouse (Bluetooth mice
    /// carry HID++ inside their mouse interface). `classify` then decides which to open.
    public static let matchCriteria: [HIDMatchCriterion] = [
        HIDMatchCriterion(vendorID: DeviceCatalog.vendorID, usagePage: 0xFF00),
        HIDMatchCriterion(vendorID: DeviceCatalog.vendorID, usagePage: 0xFF43),
        HIDMatchCriterion(vendorID: DeviceCatalog.vendorID, usagePage: 0x01, usage: 0x02),
    ]

    // MARK: Product ID tables

    /// Lightspeed receivers (G and PRO mice). Every Lightspeed mouse in the verified device
    /// data lacks the programmable-button feature (0x1B04); G HUB owns these receivers, and
    /// C53A also carries a PowerPlay chip. Never opened. Re-enabling one means removing it here
    /// and adding it to `DeviceCatalog.receivers` with a pairing layout.
    public static let lightspeedReceiverPIDs: Set<UInt16> = [
        0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D,
    ]

    /// 27 MHz (pre-Unifying) receivers speak HID++ 1.0 only.
    public static let legacyReceiverPIDs: Set<UInt16> = [0xC517]

    public static let lightspeedReason = "Lightspeed receiver: not supported (no programmable-button feature on its mice)"
    public static let legacyReceiverReason = "27 MHz receiver: not supported (HID++ 1.0 only)"

    /// Receiverless HID++ 2.0 mice that Solaar recognizes without a table entry.
    static let mouseUSBRange: ClosedRange<UInt16> = 0xC07D...0xC094
    static let mouseBluetoothRange: ClosedRange<UInt16> = 0xB012...0xB0FF
    /// Solaar treats these as receiverless HID++ 2.0 devices too, but they are keyboards.
    /// Excluded so a keyboard is never opened (no Input Monitoring prompt, no clash with Options+).
    static let keyboardUSBRange: ClosedRange<UInt16> = 0xC32B...0xC344
    static let keyboardBluetoothRange: ClosedRange<UInt16> = 0xB317...0xB3FF
    static let receiverRange: ClosedRange<UInt16> = 0xC500...0xC5FF

    // MARK: Classification

    public static func classify(_ d: HIDInterfaceDescriptor) -> InterfaceClass {
        guard d.vendorID == DeviceCatalog.vendorID else { return .ignored("not a Logitech device") }
        guard let pid = UInt16(exactly: d.productID) else { return .ignored("invalid product ID") }

        // These win over the catalog: whatever the catalog says, they are never opened.
        if lightspeedReceiverPIDs.contains(pid) { return .ignored(lightspeedReason) }
        if legacyReceiverPIDs.contains(pid) { return .ignored(legacyReceiverReason) }

        if let receiver = DeviceCatalog.receivers[pid] { return classifyReceiver(d, receiver) }
        if receiverRange.contains(pid) { return .ignored("unrecognized Logitech receiver") }
        return classifyDirect(d, pid: pid)
    }

    private static func classifyReceiver(_ d: HIDInterfaceDescriptor, _ receiver: ReceiverModel) -> InterfaceClass {
        guard let layout = receiver.layout else { return .ignored("receiver not supported") }
        switch Bus(transport: d.transport) {
        case .usb, .unknown: break
        case .bluetooth, .other: return .ignored("receiver on an unexpected transport")
        }
        // A receiver also publishes keyboard and mouse interfaces. Only the vendor-page one
        // carries HID++, and the generic mouse matching would otherwise pick up the mouse one.
        guard d.isVendorHIDPP || d.hasUnknownUsage else { return .ignored("receiver interface without HID++") }
        return .receiver(receiver.kind, layout)
    }

    private static func classifyDirect(_ d: HIDInterfaceDescriptor, pid: UInt16) -> InterfaceClass {
        let model = DeviceCatalog.model(forPID: pid)

        // The IOHID Transport string says how the device is attached. Without it, fall back
        // to where the catalog or the product ID ranges put the PID.
        let connection: ConnectionKind
        switch Bus(transport: d.transport) {
        case .usb:
            connection = .usb
        case .bluetooth:
            connection = .bluetooth
        case .other:
            return .ignored("unsupported transport \"\(d.transport)\"")
        case .unknown:
            if let model, model.usbPIDs.contains(pid) {
                connection = .usb
            } else if let model, isBluetoothPID(pid, of: model) {
                connection = .bluetooth
            } else if mouseUSBRange.contains(pid) || keyboardUSBRange.contains(pid) {
                connection = .usb
            } else if mouseBluetoothRange.contains(pid) || keyboardBluetoothRange.contains(pid) {
                connection = .bluetooth
            } else {
                return .ignored("not a supported mouse")
            }
        }

        // A catalog entry is verified mouse data, so it wins over the keyboard ranges.
        if let model {
            switch connection {
            case .usb where model.usbPIDs.contains(pid): return .direct(.usb)
            case .bluetooth where isBluetoothPID(pid, of: model): return .direct(.bluetooth)
            default: break
            }
        }

        switch connection {
        case .usb:
            if keyboardUSBRange.contains(pid) { return .ignored("keyboard") }
            if mouseUSBRange.contains(pid) { return .direct(.usb) }
        case .bluetooth:
            if keyboardBluetoothRange.contains(pid) { return .ignored("keyboard") }
            if mouseBluetoothRange.contains(pid) { return .direct(.bluetooth) }
        case .unifying, .bolt, .nano:
            break
        }
        return .ignored("not a supported mouse")
    }

    /// A Bolt receiver reports a mouse by its Bluetooth PID, so a Bxxx wireless PID counts too.
    private static func isBluetoothPID(_ pid: UInt16, of model: DeviceModel) -> Bool {
        model.bluetoothPIDs.contains(pid) || (model.wirelessPIDs.contains(pid) && pid & 0xF000 == 0xB000)
    }

    /// How an IOHID `Transport` string reads.
    private enum Bus {
        case usb, bluetooth, unknown, other

        init(transport: String) {
            let text = transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.isEmpty {
                self = .unknown
            } else if text.contains("usb") {
                self = .usb
            } else if text.contains("bluetooth") {
                self = .bluetooth
            } else {
                self = .other
            }
        }
    }

    // MARK: Identity and twins

    /// Identity used to dedupe twin interfaces at match time:
    /// vendor:product:page:usage plus the serial, else the location ID, else the registry ID.
    /// The registry ID is unique per interface, so two Bluetooth mice that report neither a
    /// serial nor a location never collapse into one.
    public static func identityKey(_ d: HIDInterfaceDescriptor) -> String {
        let base = [d.vendorID, d.productID, d.usagePage, d.usage].map { hex($0, width: 4) }.joined(separator: ":")
        let serial = d.normalizedSerial
        if !serial.isEmpty { return base + ":s:" + serial }
        if d.locationID != 0 { return base + ":l:" + String(d.locationID, radix: 16) }
        return base + ":r:" + String(d.registryID, radix: 16)
    }

    /// Bluetooth publishes the mouse and its HID++ collection as one interface. USB and
    /// receivers also publish a dedicated vendor-page interface, which is the one to use when
    /// both show up for the same device. Returns nil when `d` should not be opened, otherwise
    /// the keys of open twins it supersedes (to be closed first).
    ///
    /// Twins share vendor, product and a nonzero location ID, and their serial numbers don't
    /// contradict each other. An interface without a location is never a twin: it is opened.
    public static func twinsToReplace<K: Hashable>(adding d: HIDInterfaceDescriptor, open: [K: HIDInterfaceDescriptor]) -> [K]? {
        guard d.locationID != 0 else { return [] }
        let twins = open.filter { isSamePhysicalDevice($0.value, d) }
        if d.isVendorHIDPP {
            if twins.values.contains(where: \.isVendorHIDPP) { return nil }
            return twins.filter { !$0.value.isVendorHIDPP }.map(\.key)
        }
        return twins.isEmpty ? [] : nil
    }

    public static func isSamePhysicalDevice(_ a: HIDInterfaceDescriptor, _ b: HIDInterfaceDescriptor) -> Bool {
        guard a.locationID != 0, a.vendorID == b.vendorID, a.productID == b.productID, a.locationID == b.locationID else { return false }
        // Interfaces of one device report one serial; a missing one on either side is no contradiction.
        let sa = a.normalizedSerial
        let sb = b.normalizedSerial
        return sa.isEmpty || sb.isEmpty || sa == sb
    }

    // MARK: Formatting

    /// Upper-case hex, zero-padded to `width` (no `String(format:)`, so it is exact on Linux too).
    static func hex(_ value: Int, width: Int) -> String {
        let digits = String(UInt(clamping: value), radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
