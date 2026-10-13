import Foundation

// Wave 0 scaffold: final signatures, today's acceptance rules. W1.2 owns this file and
// implements D9 (generic mouse ranges, keyboard exclusion, Lightspeed and 27 MHz ignored).

/// The IOKit properties of one HID interface, as plain values (Linux-safe).
public struct HIDInterfaceDescriptor: Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    /// The IOHID `Transport` string: "USB", "Bluetooth", "Bluetooth Low Energy", ...
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
}

public enum InterfaceClassifier {
    public static func classify(_ d: HIDInterfaceDescriptor) -> InterfaceClass {
        guard d.vendorID == DeviceCatalog.vendorID else { return .ignored("not a Logitech device") }
        guard let pid = UInt16(exactly: d.productID) else { return .ignored("invalid product ID") }
        if let receiver = DeviceCatalog.receivers[pid] {
            guard let layout = receiver.layout else { return .ignored("receiver not supported") }
            return .receiver(receiver.kind, layout)
        }
        if let model = DeviceCatalog.model(forPID: pid) {
            if model.usbPIDs.contains(pid) { return .direct(.usb) }
            if model.bluetoothPIDs.contains(pid) { return .direct(.bluetooth) }
        }
        return .ignored("not a supported mouse")
    }

    /// Identity used to dedupe twin interfaces at match time:
    /// vendor:product:page:usage plus the serial, else the location ID, else the registry ID.
    public static func identityKey(_ d: HIDInterfaceDescriptor) -> String {
        let base = String(format: "%04X:%04X:%04X:%04X", d.vendorID, d.productID, d.usagePage, d.usage)
        if !d.serial.isEmpty { return base + ":s:" + d.serial }
        if d.locationID != 0 { return base + ":l:" + String(d.locationID, radix: 16) }
        return base + ":r:" + String(d.registryID, radix: 16)
    }

    /// Bluetooth publishes the mouse and its HID++ collection as one interface. USB and
    /// receivers also publish a dedicated vendor-page interface, which is the one to use when
    /// both show up for the same device. Returns nil when `d` should not be opened, otherwise
    /// the keys of open twins it supersedes (to be closed first).
    public static func twinsToReplace<K: Hashable>(adding d: HIDInterfaceDescriptor, open: [K: HIDInterfaceDescriptor]) -> [K]? {
        guard d.locationID != 0 else { return [] }
        let twins = open.filter { isSamePhysicalDevice($0.value, d) }
        if d.isVendorHIDPP {
            if twins.values.contains(where: \.isVendorHIDPP) { return nil }
            return twins.filter { !$0.value.isVendorHIDPP }.map(\.key)
        }
        return twins.isEmpty ? [] : nil
    }

    static func isSamePhysicalDevice(_ a: HIDInterfaceDescriptor, _ b: HIDInterfaceDescriptor) -> Bool {
        a.locationID != 0 && a.vendorID == b.vendorID && a.productID == b.productID && a.locationID == b.locationID
    }
}
