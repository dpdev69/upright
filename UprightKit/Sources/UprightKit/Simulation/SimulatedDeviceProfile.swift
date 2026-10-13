import Foundation

// Wave 0 scaffold. W1.6 owns `Simulation/` and may reshape these types freely: nothing outside
// the simulator depends on them yet. Data must come from devices.verified.json (high/medium
// confidence), and unit IDs and serials must be obviously fake.

/// Describes one simulated HID++ device: what it reports and how it answers.
public struct SimulatedDeviceProfile: Hashable, Sendable {
    public struct Feature: Hashable, Sendable {
        public var id: UInt16
        public var version: UInt8

        public init(_ id: UInt16, version: UInt8 = 0) {
            self.id = id
            self.version = version
        }
    }

    /// Which battery feature the device reports.
    public enum Battery: Hashable, Sendable {
        /// UNIFIED_BATTERY (0x1004).
        case unified
        /// BATTERY_STATUS (0x1000).
        case status
        /// BATTERY_VOLTAGE (0x1001).
        case voltage
        case none
    }

    public var name: String
    public var kind: DeviceKind
    public var protocolMajor: UInt8
    public var protocolMinor: UInt8
    /// What a Unifying/Nano receiver reports for this device in a slot (Bolt: the BLE PID).
    public var wirelessPID: UInt16?
    public var bluetoothPID: UInt16?
    public var usbPID: UInt16?
    /// 0x0003 function 0.
    public var unitID: UInt32?
    public var modelIDs: ModelIDs
    public var serialNumber: String?
    /// In feature-table order; index 0 is always ROOT (0x0000).
    public var features: [Feature]
    public var controls: [ControlInfo]
    /// getSensorDpiList values as the device encodes them (0xE000 | step marks a range step).
    public var dpiList: [UInt16]
    public var defaultDPI: Int?
    public var battery: Battery
    public var hostCount: Int

    public init(
        name: String,
        kind: DeviceKind = .mouse,
        protocolMajor: UInt8 = 4,
        protocolMinor: UInt8 = 5,
        wirelessPID: UInt16? = nil,
        bluetoothPID: UInt16? = nil,
        usbPID: UInt16? = nil,
        unitID: UInt32? = nil,
        modelIDs: ModelIDs = ModelIDs(),
        serialNumber: String? = nil,
        features: [Feature] = [],
        controls: [ControlInfo] = [],
        dpiList: [UInt16] = [],
        defaultDPI: Int? = nil,
        battery: Battery = .none,
        hostCount: Int = 0
    ) {
        self.name = name
        self.kind = kind
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.wirelessPID = wirelessPID
        self.bluetoothPID = bluetoothPID
        self.usbPID = usbPID
        self.unitID = unitID
        self.modelIDs = modelIDs
        self.serialNumber = serialNumber
        self.features = features
        self.controls = controls
        self.dpiList = dpiList
        self.defaultDPI = defaultDPI
        self.battery = battery
        self.hostCount = hostCount
    }

    /// The feature-table index of `id`, as the device reports it.
    public func featureIndex(of id: UInt16) -> UInt8? {
        features.firstIndex { $0.id == id }.map(UInt8.init)
    }
}
