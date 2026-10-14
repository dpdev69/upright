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

extension HIDInterfaceDescriptor {
    /// Reads the descriptor from a matched device's IORegistry properties.
    public init(device: IOHIDDevice) {
        func int(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func string(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
        }
        self.init(
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            transport: string(kIOHIDTransportKey),
            usagePage: int(kIOHIDPrimaryUsagePageKey),
            usage: int(kIOHIDPrimaryUsageKey),
            locationID: int(kIOHIDLocationIDKey),
            serial: string(kIOHIDSerialNumberKey),
            registryID: Self.registryEntryID(of: device),
            productName: string(kIOHIDProductKey)
        )
    }

    /// The IORegistry entry ID of the device's service: unique per interface, 0 when unavailable.
    static func registryEntryID(of device: IOHIDDevice) -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return 0 }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return 0 }
        return entryID
    }
}

/// Basic facts about a HID interface, read from its IORegistry properties.
///
/// A thin wrapper over `HIDInterfaceDescriptor`, which holds the values and drives
/// `InterfaceClassifier`. The accessors keep the names earlier callers used.
public struct HIDInterfaceInfo: Hashable, Sendable {
    public var descriptor: HIDInterfaceDescriptor

    public init(descriptor: HIDInterfaceDescriptor) {
        self.descriptor = descriptor
    }

    init(device: IOHIDDevice) {
        descriptor = HIDInterfaceDescriptor(device: device)
    }

    public var vendorID: Int { descriptor.vendorID }
    public var productID: Int { descriptor.productID }
    public var product: String { descriptor.productName }
    public var transport: String { descriptor.transport }
    public var locationID: Int { descriptor.locationID }
    public var primaryUsagePage: Int { descriptor.usagePage }
    public var primaryUsage: Int { descriptor.usage }
    public var serialNumber: String { descriptor.serial }
    public var registryID: UInt64 { descriptor.registryID }

    public var summary: String { descriptor.summary }

    /// Receivers and the USB cable publish a dedicated vendor-page HID++ interface.
    public var isVendorHIDPP: Bool { descriptor.isVendorHIDPP }

    /// Whether Upright opens this interface, and as what.
    public var interfaceClass: InterfaceClass { InterfaceClassifier.classify(descriptor) }

    public func isSamePhysicalDevice(as other: HIDInterfaceInfo) -> Bool {
        InterfaceClassifier.isSamePhysicalDevice(descriptor, other.descriptor)
    }

    /// See `InterfaceClassifier.twinsToReplace`.
    public static func twinsToReplace<Key: Hashable>(adding info: HIDInterfaceInfo, open: [Key: HIDInterfaceInfo]) -> [Key]? {
        InterfaceClassifier.twinsToReplace(adding: info.descriptor, open: open.mapValues(\.descriptor))
    }
}

/// Watches for Logitech HID interfaces that may carry HID++: the vendor usage pages (0xFF00 on
/// USB receivers and wired devices, 0xFF43 on Bluetooth Low Energy devices) and every Logitech
/// mouse interface (Bluetooth mice carry HID++ inside their mouse interface). The criteria live
/// in `InterfaceClassifier.matchCriteria`.
///
/// Every match is classified with `InterfaceClassifier.classify`. Interfaces it ignores (a
/// receiver's boot-mouse interface, a Lightspeed receiver, a keyboard, a mouse that isn't HID++)
/// are never passed to `onMatch`; `onIgnored` reports each one once, with the reason, so the
/// owner can log it. Set `deliversIgnoredInterfaces` to see them anyway (`upright-probe --all`).
/// Callers still ask `HIDDeviceMonitor.interfaceClass(for:)` what an accepted device is, and use
/// `InterfaceClassifier.twinsToReplace` to pick between interfaces of one device.
public final class HIDDeviceMonitor {
    public var onMatch: ((IOHIDDevice) -> Void)?
    public var onRemove: ((IOHIDDevice) -> Void)?
    /// An interface the classifier ignores, with the reason. Called once per matched interface.
    public var onIgnored: ((HIDInterfaceInfo, String) -> Void)?
    /// When true, ignored interfaces are delivered through `onMatch` as well.
    public var deliversIgnoredInterfaces = false

    private let manager: IOHIDManager
    /// macOS publishes two IOHIDDevice objects for one Bluetooth mouse. Opening both
    /// interleaves HID++ replies, so the second match for the same device is ignored.
    private var chosen: [String: IOHIDDevice] = [:]
    private var ignored: Set<IOHIDDevice> = []
    /// Interfaces the classifier turned away: never delivered, so their removal isn't either.
    private var skipped: Set<IOHIDDevice> = []
    private var isRunning = false

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        stop()
    }

    /// Starts monitoring on the main run loop.
    ///
    /// Callbacks are scheduled in the common run loop modes so devices keep being matched (and
    /// reports keep arriving) while a menu is open or a modal panel runs.
    ///
    /// The manager itself is never opened (no `IOHIDManagerOpen`): matching and removal callbacks
    /// fire without it, and opening at the manager level would open every matched interface,
    /// including the ones `classify` turns away (a receiver's boot-mouse interface, a combined
    /// keyboard+mouse interface), which can raise the Input Monitoring prompt or fail the whole
    /// manager with kIOReturnNotPermitted. Only accepted interfaces are opened, one by one, by
    /// `IOKitHIDTransport.open()`, which reports permission failures per interface.
    public func start() {
        isRunning = true
        // Receivers and the USB cable publish a dedicated HID++ interface (usage page
        // 0xFF00 or 0xFF43). Bluetooth mice do not: a Bluetooth MX mouse is one mouse
        // interface (usage page 0x01) that also carries the HID++ collection. Matching only
        // the vendor pages leaves those mice unmatched, so their buttons are never remapped.
        // No product IDs here: which Logitech interfaces to open is decided by the classifier.
        let matching: [[String: Any]] = InterfaceClassifier.matchCriteria.map { criterion in
            var entry: [String: Any] = [
                kIOHIDVendorIDKey: criterion.vendorID,
                kIOHIDDeviceUsagePageKey: criterion.usagePage,
            ]
            if let usage = criterion.usage { entry[kIOHIDDeviceUsageKey] = usage }
            return entry
        }
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

        // Scheduling the manager also schedules every device it enumerates (open or not), so
        // input reports of the interfaces opened later arrive on the main run loop.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        chosen.removeAll()
        ignored.removeAll()
        skipped.removeAll()
    }

    private func deliverMatch(_ device: IOHIDDevice) {
        let descriptor = HIDInterfaceDescriptor(device: device)
        if case .ignored(let reason) = InterfaceClassifier.classify(descriptor), !deliversIgnoredInterfaces {
            skipped.insert(device)
            onIgnored?(HIDInterfaceInfo(descriptor: descriptor), reason)
            return
        }
        let key = InterfaceClassifier.identityKey(descriptor)
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
        if skipped.remove(device) != nil { return }
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

    /// Same physical interface: serial when the device has one, otherwise location, otherwise
    /// the registry entry (see `InterfaceClassifier.identityKey`).
    private func identity(for device: IOHIDDevice) -> String {
        InterfaceClassifier.identityKey(HIDInterfaceDescriptor(device: device))
    }

    public static func info(for device: IOHIDDevice) -> HIDInterfaceInfo {
        HIDInterfaceInfo(device: device)
    }

    /// What Upright does with `device`: open it as a receiver or a direct mouse, or ignore it.
    public static func interfaceClass(for device: IOHIDDevice) -> InterfaceClass {
        InterfaceClassifier.classify(HIDInterfaceDescriptor(device: device))
    }

    /// Devices that currently match the criteria (before classification), including ones already
    /// present when monitoring started.
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
///
/// The monitor's manager is never opened, so `open()` is the only open on the device and
/// permission failures surface per device; balance it with `close()` while the device is still
/// present, or `deviceRemoved()` once IOKit has removed it.
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

    /// Closes a device that is still present (twin swap, re-matching, quitting).
    public func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Call when IOKit reports the device was removed. Unregisters the report callback without
    /// calling `IOHIDDeviceClose`, which is unsafe on a device that is already gone.
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
