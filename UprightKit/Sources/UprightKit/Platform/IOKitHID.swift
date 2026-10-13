#if canImport(IOKit)
import Foundation
import IOKit
import IOKit.hid

public enum IOKitHIDError: Error, CustomStringConvertible {
    case openFailed(IOReturn)

    public var description: String {
        switch self {
        case .openFailed(let code):
            if code == IOKitReturn.notPermitted || code == IOKitReturn.notPrivileged {
                return "macOS denied access to the HID device. Allow Upright under Privacy & Security → Input Monitoring."
            }
            return String(format: "Could not open the HID device (IOReturn 0x%08X).", UInt32(bitPattern: code))
        }
    }

    public var isPermissionDenied: Bool {
        switch self {
        case .openFailed(let code): return code == IOKitReturn.notPermitted || code == IOKitReturn.notPrivileged
        }
    }
}

/// IOReturn values that Swift doesn't import (they're built with function-like macros).
enum IOKitReturn {
    static let notPrivileged = IOReturn(bitPattern: 0xE00002C1)
    static let badArgument = IOReturn(bitPattern: 0xE00002C2)
    static let exclusiveAccess = IOReturn(bitPattern: 0xE00002C5)
    static let notPermitted = IOReturn(bitPattern: 0xE00002E2)
}

/// Basic facts about a HID interface, read from its IORegistry properties.
public struct HIDInterfaceInfo: Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var transport: String
    public var locationID: Int
    public var primaryUsagePage: Int
    public var primaryUsage: Int
    public var serialNumber: String

    init(device: IOHIDDevice) {
        func int(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func string(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
        }
        vendorID = int(kIOHIDVendorIDKey)
        productID = int(kIOHIDProductIDKey)
        product = string(kIOHIDProductKey)
        transport = string(kIOHIDTransportKey)
        locationID = int(kIOHIDLocationIDKey)
        primaryUsagePage = int(kIOHIDPrimaryUsagePageKey)
        primaryUsage = int(kIOHIDPrimaryUsageKey)
        serialNumber = string(kIOHIDSerialNumberKey)
    }

    public var summary: String {
        String(format: "%@ [%04X:%04X] via %@, usage %04X:%04X", product, vendorID, productID, transport, primaryUsagePage, primaryUsage)
    }
}

/// Watches for Logitech HID interfaces that carry HID++ (vendor usage pages 0xFF00 on USB
/// receivers and wired devices, 0xFF43 on Bluetooth Low Energy devices).
public final class HIDDeviceMonitor {
    public var onMatch: ((IOHIDDevice) -> Void)?
    public var onRemove: ((IOHIDDevice) -> Void)?

    private let manager: IOHIDManager
    /// macOS publishes two IOHIDDevice objects for one Bluetooth mouse. Opening both
    /// interleaves HID++ replies, so the second match for the same device is ignored.
    private var chosen: [String: IOHIDDevice] = [:]
    private var ignored: Set<IOHIDDevice> = []

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        stop()
    }

    /// Starts monitoring on the main run loop. Returns the IOHIDManagerOpen result.
    @discardableResult
    public func start() -> IOReturn {
        // Receivers and the USB cable publish a dedicated HID++ interface (usage page
        // 0xFF00 or 0xFF43). Bluetooth does not: the MX Vertical is one mouse interface
        // (usage page 0x01) that also carries the HID++ collection. Matching only the
        // vendor page leaves that mouse unmatched, so its buttons are never remapped.
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: MXVertical.vendorID, kIOHIDDeviceUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: MXVertical.vendorID, kIOHIDDeviceUsagePageKey: 0xFF43],
            [
                kIOHIDVendorIDKey: MXVertical.vendorID,
                kIOHIDProductIDKey: Int(MXVertical.bluetoothProductID),
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
            ],
            [
                kIOHIDVendorIDKey: MXVertical.vendorID,
                kIOHIDProductIDKey: Int(MXVertical.usbProductID),
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().deliverMatch(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().deliverRemoval(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        chosen.removeAll()
        ignored.removeAll()
    }

    private func deliverMatch(_ device: IOHIDDevice) {
        let key = identity(for: device)
        if let existing = chosen[key] {
            switch HIDInterfaceChoicePolicy.choose(
                alreadyOpen: true,
                sameInterface: existing == device,
                previousStillPresent: isPresent(existing)
            ) {
            case .use:
                break
            case .ignore:
                ignored.insert(device)
                return
            case .replace:
                ignored.remove(device)
                chosen[key] = device
                onRemove?(existing)
                onMatch?(device)
                return
            }
        }
        ignored.remove(device)
        chosen[key] = device
        onMatch?(device)
    }

    private func deliverRemoval(_ device: IOHIDDevice) {
        if ignored.remove(device) != nil { return }
        let key = chosen.first { $0.value == device }?.key
        chosen = chosen.filter { $0.value != device }
        onRemove?(device)
        guard let key, let replacement = ignored.first(where: { identity(for: $0) == key && isPresent($0) }) else { return }
        ignored.remove(replacement)
        chosen[key] = replacement
        onMatch?(replacement)
    }

    private func isPresent(_ device: IOHIDDevice) -> Bool {
        guard let raw = IOHIDManagerCopyDevices(manager) else { return false }
        return (raw as NSSet).contains(device)
    }

    /// Same physical interface: serial when the device has one, otherwise location and usage.
    private func identity(for device: IOHIDDevice) -> String {
        let info = HIDInterfaceInfo(device: device)
        if !info.serialNumber.isEmpty {
            return "\(info.vendorID):\(info.productID):\(info.primaryUsagePage):\(info.primaryUsage):\(info.serialNumber)"
        }
        return "\(info.vendorID):\(info.productID):\(info.primaryUsagePage):\(info.primaryUsage):loc\(info.locationID)"
    }

    public static func info(for device: IOHIDDevice) -> HIDInterfaceInfo {
        HIDInterfaceInfo(device: device)
    }

    /// Devices that currently match, including ones already present when monitoring started.
    public func currentDevices() -> [HIDInterfaceInfo] {
        guard let raw = IOHIDManagerCopyDevices(manager) else { return [] }
        return (raw as NSSet).allObjects.map { HIDInterfaceInfo(device: $0 as! IOHIDDevice) }
    }

    /// Whether macOS currently lets this process read HID input (Input Monitoring).
    public static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Shows the Input Monitoring prompt if the user hasn't decided yet.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// HID++ over an IOHIDDevice that was matched by `HIDDeviceMonitor` (and is therefore
/// already scheduled on the main run loop). Reports are delivered on the main thread.
public final class IOKitHIDTransport: HIDPPTransport {
    public let device: IOHIDDevice
    public let info: HIDInterfaceInfo
    public var onReport: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    private static let bufferSize = 64
    private let buffer: UnsafeMutablePointer<UInt8>
    private var isOpen = false

    public init(device: IOHIDDevice) {
        self.device = device
        self.info = HIDInterfaceInfo(device: device)
        buffer = .allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    public func open() throws {
        guard !isOpen else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw IOKitHIDError.openFailed(result) }
        isOpen = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let transport = Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.deliver(reportID: reportID, report: report, length: length)
        }, context)
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Call when IOKit reports the device was removed.
    public func deviceRemoved() {
        if isOpen {
            isOpen = false
            IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
        }
        onClose?()
    }

    public func send(_ bytes: [UInt8]) throws {
        guard let reportID = bytes.first else { return }
        let result = bytes.withUnsafeBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return IOKitReturn.badArgument }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, pointer.count)
        }
        guard result == kIOReturnSuccess else { throw HIDPPError.sendFailed(result) }
    }

    private func deliver(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0, length <= Self.bufferSize else { return }
        // Pointer and wheel reports share this interface and arrive constantly. Drop them
        // before copying, so moving the mouse does not allocate on the main thread.
        let leadingIsHIDPP = HIDPPReportID(rawValue: report[0]) != nil
        let headerIsHIDPP = UInt8(exactly: reportID).flatMap(HIDPPReportID.init(rawValue:)) != nil
        guard leadingIsHIDPP || headerIsHIDPP else { return }

        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        if !leadingIsHIDPP, let id = UInt8(exactly: reportID) {
            bytes.insert(id, at: 0)
        }
        onReport?(bytes)
    }
}
#endif
