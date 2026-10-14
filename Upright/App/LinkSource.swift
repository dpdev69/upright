import Foundation
import IOKit.hid

/// One HID interface a `LinkSource` found: a receiver or a directly connected mouse that
/// `DeviceManager` may open as an `HIDPPLink`.
struct LinkInterface: Identifiable {
    /// Stable for as long as the source reports the interface present.
    let id: AnyHashable
    let descriptor: HIDInterfaceDescriptor
    /// What the interface is: decided by the source (the IOKit source asks `InterfaceClassifier`).
    let kind: TransportKind

    /// The interface's product name, or a generic one.
    var name: String {
        let name = descriptor.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Logitech device") : name
    }

    var productID: UInt16? { UInt16(exactly: descriptor.productID) }

    /// Survives re-matching the same interface (recovery counters are keyed by it).
    var identityKey: String { InterfaceClassifier.identityKey(descriptor) }
}

/// Why a source couldn't start watching, or an interface couldn't be opened.
enum LinkSourceError: Error {
    /// macOS refused access (Input Monitoring). `message` is user-facing.
    case permissionDenied(String)
    case failed(String)

    var message: String {
        switch self {
        case .permissionDenied(let message), .failed(let message): return message
        }
    }

    var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Where `DeviceManager` gets its HID interfaces from (amendment A2). The IOKit source is the
/// default; Demo Mode uses `SimulatedLinkSource`, which never touches IOKit.
///
/// Callbacks run on the main actor. `onMatch` may be called again for an interface that was
/// already reported (after `stop()`/`start()`); `DeviceManager` ignores repeats.
@MainActor
protocol LinkSource: AnyObject {
    var onMatch: ((LinkInterface) -> Void)? { get set }
    /// The interface with this ID went away (its transport is already dead).
    var onRemove: ((AnyHashable) -> Void)? { get set }
    /// An interface the source won't offer, with the reason. Once per interface.
    var onIgnored: ((HIDInterfaceDescriptor, String) -> Void)? { get set }

    /// The first activity-log line, e.g. "Watching for Logitech mice…".
    var watchingDescription: String { get }

    /// Starts watching. Matches may arrive during the call or later. Throws when watching as a
    /// whole was refused; interfaces found anyway are still reported.
    func start() throws
    func stop()

    /// Opens an interface for HID++. Throws `LinkSourceError`.
    func open(_ interface: LinkInterface) throws -> HIDPPTransport
    /// Balances `open`. `removed`: the interface is already gone, so only clean up.
    func close(_ interface: LinkInterface, transport: HIDPPTransport, removed: Bool)

    /// Shows the Input Monitoring prompt if the user hasn't decided yet; returns whether access
    /// is granted. Sources that need no permission return true without asking.
    func requestInputMonitoringAccess() -> Bool
}

// MARK: - IOKit

/// Logitech HID interfaces from IOKit (`HIDDeviceMonitor`). Nothing touches IOKit until
/// `start()`, so creating one is free.
@MainActor
final class IOKitLinkSource: LinkSource {
    var onMatch: ((LinkInterface) -> Void)?
    var onRemove: ((AnyHashable) -> Void)?
    var onIgnored: ((HIDInterfaceDescriptor, String) -> Void)?

    private var monitor: HIDDeviceMonitor?
    /// Delivered devices by interface ID, until removed.
    private var devices: [AnyHashable: IOHIDDevice] = [:]

    var watchingDescription: String {
        String(localized: "Watching for Logitech mice over USB, Unifying, Bolt and Nano receivers, and Bluetooth")
    }

    func start() throws {
        let monitor = self.monitor ?? HIDDeviceMonitor()
        self.monitor = monitor
        monitor.onMatch = { [weak self] device in
            MainActorDelivery.run { self?.deliver(device) }
        }
        monitor.onRemove = { [weak self] device in
            MainActorDelivery.run {
                guard let self else { return }
                let id = AnyHashable(device)
                self.devices[id] = nil
                self.onRemove?(id)
            }
        }
        monitor.onIgnored = { [weak self] info, reason in
            MainActorDelivery.run { self?.onIgnored?(info.descriptor, reason) }
        }
        // No Input Monitoring prompt here: watching opens nothing, and only the interfaces the
        // classifier accepts are opened (in `open(_:)`), each reporting its own permission
        // failure. The UI offers `requestInputMonitoringAccess()` when access is refused.
        monitor.start()
    }

    func stop() {
        monitor?.stop()
        devices.removeAll()
    }

    func open(_ interface: LinkInterface) throws -> HIDPPTransport {
        guard let device = devices[interface.id] else {
            throw LinkSourceError.failed(String(localized: "Unknown HID interface"))
        }
        let transport = IOKitHIDTransport(device: device)
        do {
            try transport.open()
        } catch let error as IOKitHIDError {
            throw error.isPermissionDenied ? LinkSourceError.permissionDenied(error.description) : LinkSourceError.failed(error.description)
        }
        return transport
    }

    func close(_ interface: LinkInterface, transport: HIDPPTransport, removed: Bool) {
        guard let transport = transport as? IOKitHIDTransport else { return }
        if removed {
            transport.deviceRemoved()
        } else {
            transport.close()
        }
    }

    func requestInputMonitoringAccess() -> Bool {
        HIDDeviceMonitor.requestInputMonitoringAccess()
    }

    private func deliver(_ device: IOHIDDevice) {
        let descriptor = HIDInterfaceDescriptor(device: device)
        guard let kind = InterfaceClassifier.classify(descriptor).transportKind else { return }
        let id = AnyHashable(device)
        devices[id] = device
        onMatch?(LinkInterface(id: id, descriptor: descriptor, kind: kind))
    }
}

// MARK: - Simulation

/// Simulated receivers and mice from `K/Simulation`, for Demo Mode. Never touches IOKit, asks
/// for no permission, and opening an interface always succeeds.
///
/// The transports stay alive for the whole process: closing an interface keeps its simulated
/// devices (and their state), so Reconnect reopens the same ones. `transports` lets Demo Mode
/// drive the devices (battery levels, button presses, sleep).
@MainActor
final class SimulatedLinkSource: LinkSource {
    struct Interface {
        let transport: SimulatedHIDPPTransport
        let descriptor: HIDInterfaceDescriptor
    }

    var onMatch: ((LinkInterface) -> Void)?
    var onRemove: ((AnyHashable) -> Void)?
    var onIgnored: ((HIDInterfaceDescriptor, String) -> Void)?

    /// In delivery order: the order the devices first appear in.
    let interfaces: [Interface]
    private var isRunning = false
    private var generation = 0

    init(_ interfaces: [Interface]) {
        self.interfaces = interfaces
    }

    /// The Demo Mode fleet: an MX Vertical over Bluetooth, then an MX Master 3S and a Lift on a
    /// Bolt receiver (slots 1 and 2). A direct link starts its mouse right away and a receiver
    /// lists its slots in order, so the devices keep this order in every run.
    static func demo() -> SimulatedLinkSource {
        SimulatedLinkSource([
            .direct(SimulatedDirect(profile: DeviceProfiles.mxVertical, connection: .bluetooth), registryID: 0xDE30_0001),
            .receiver(SimulatedReceiver.bolt([1: DeviceProfiles.mxMaster3S, 2: DeviceProfiles.lift]), registryID: 0xDE30_0002),
        ])
    }

    /// All simulated transports, in delivery order.
    var transports: [SimulatedHIDPPTransport] { interfaces.map(\.transport) }

    var watchingDescription: String {
        String(localized: "Demo Mode: showing simulated mice; no real device is opened")
    }

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let generation = generation
        // Delivered on the next turn, like IOKit's matching callbacks, so late replies to a
        // previous link's last requests don't reach the new one.
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            for (offset, interface) in self.interfaces.enumerated() where !interface.transport.isDisconnected {
                self.onMatch?(LinkInterface(id: AnyHashable(offset), descriptor: interface.descriptor, kind: interface.transport.transportKind))
            }
        }
    }

    func stop() {
        isRunning = false
    }

    func open(_ interface: LinkInterface) throws -> HIDPPTransport {
        guard let offset = interface.id.base as? Int, interfaces.indices.contains(offset) else {
            throw LinkSourceError.failed(String(localized: "Unknown HID interface"))
        }
        return interfaces[offset].transport
    }

    func close(_ interface: LinkInterface, transport: HIDPPTransport, removed: Bool) {}

    func requestInputMonitoringAccess() -> Bool { true }
}

extension SimulatedLinkSource.Interface {
    static func receiver(_ receiver: SimulatedReceiver, registryID: UInt64) -> Self {
        Self(transport: receiver, descriptor: HIDInterfaceDescriptor(
            vendorID: DeviceCatalog.vendorID,
            productID: Int(receiver.productID),
            transport: "USB",
            usagePage: 0xFF00,
            usage: 0x01,
            registryID: registryID,
            productName: DeviceCatalog.receivers[receiver.productID]?.name ?? receiver.connection.title
        ))
    }

    static func direct(_ direct: SimulatedDirect, registryID: UInt64) -> Self {
        let bluetooth = direct.connection == .bluetooth
        return Self(transport: direct, descriptor: HIDInterfaceDescriptor(
            vendorID: DeviceCatalog.vendorID,
            productID: Int(direct.productID ?? 0),
            transport: bluetooth ? "Bluetooth Low Energy" : "USB",
            usagePage: bluetooth ? 0x01 : 0xFF00,
            usage: bluetooth ? 0x02 : 0x01,
            serial: direct.profile.serialNumber ?? "",
            registryID: registryID,
            productName: direct.profile.name
        ))
    }
}
