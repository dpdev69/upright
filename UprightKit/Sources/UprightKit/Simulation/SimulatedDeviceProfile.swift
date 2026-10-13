import Foundation

/// Describes one simulated HID++ device: what it reports and how it answers. Profiles are
/// plain values; the per-unit state (diversion, pointer speed, battery, link) lives in the
/// transport that hosts them (`SimulatedReceiver`, `SimulatedDirect`).
///
/// Ready-made profiles are in `DeviceProfiles`. Unit IDs and serial numbers of simulated
/// devices must be obviously fake (Demo Mode shows them).
public struct SimulatedDeviceProfile: Hashable, Sendable {
    /// One entry of the feature table.
    public struct Feature: Hashable, Sendable {
        public var id: UInt16
        public var version: UInt8
        /// Feature type flags as getFeature / getFeatureID report them (obsolete 0x80,
        /// hidden 0x40, internal 0x20).
        public var flags: UInt8

        public init(_ id: UInt16, version: UInt8 = 0, flags: UInt8 = 0) {
            self.id = id
            self.version = version
            self.flags = flags
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

        /// The feature ID, nil for `.none`.
        public var featureID: UInt16? {
            switch self {
            case .unified: return 0x1004
            case .status: return 0x1000
            case .voltage: return 0x1001
            case .none: return nil
            }
        }
    }

    /// One DEVICE_FW_VERSION (0x0003) entity, as getFwInfo reports it.
    public struct Firmware: Hashable, Sendable {
        public var kind: FirmwareInfo.Kind
        /// Three ASCII characters ("RBM", "BOT"); empty for hardware entries.
        public var prefix: String
        /// BCD as reported: 0x16 is shown as "16".
        public var number: UInt8
        public var revision: UInt8
        public var build: UInt16

        public init(kind: FirmwareInfo.Kind, prefix: String = "", number: UInt8 = 0, revision: UInt8 = 0, build: UInt16 = 0) {
            self.kind = kind
            self.prefix = prefix
            self.number = number
            self.revision = revision
            self.build = build
        }

        public static func firmware(_ prefix: String, _ number: UInt8, _ revision: UInt8, build: UInt16) -> Firmware {
            Firmware(kind: .firmware, prefix: prefix, number: number, revision: revision, build: build)
        }

        public static func bootloader(_ prefix: String, _ number: UInt8, _ revision: UInt8, build: UInt16) -> Firmware {
            Firmware(kind: .bootloader, prefix: prefix, number: number, revision: revision, build: build)
        }

        /// A hardware entry; `revision` is shown as a decimal number.
        public static func hardware(_ revision: UInt8) -> Firmware {
            Firmware(kind: .hardware, number: revision)
        }

        public static let other = Firmware(kind: .other)

        /// getFwInfo reply parameters: [type, prefix (3), number, revision, build (2, BE)].
        public var parameters: [UInt8] {
            switch kind {
            case .firmware, .bootloader:
                var bytes: [UInt8] = [kind.rawValue]
                bytes += Array((Array(prefix.utf8) + [0, 0, 0]).prefix(3))
                bytes += [number, revision, UInt8(build >> 8), UInt8(build & 0xFF)]
                return bytes
            case .hardware:
                return [kind.rawValue, number]
            case .other:
                return [kind.rawValue]
            }
        }
    }

    /// The 0x0005 name ("MX Master 3S").
    public var name: String
    /// What the receiver lists as the device's codename and what DEVICE_FRIENDLY_NAME (0x0007)
    /// returns ("MX Vertical", "LIFT"). Defaults to `name`.
    public var codename: String
    public var kind: DeviceKind
    public var protocolMajor: UInt8
    public var protocolMinor: UInt8
    /// What a Unifying/Nano receiver reports for this device in a slot (Bolt: the BLE PID).
    public var wirelessPID: UInt16?
    public var bluetoothPID: UInt16?
    public var usbPID: UInt16?
    /// 0x0003 function 0; also the serial a receiver lists for the slot. Nil reports zero.
    public var unitID: UInt32?
    public var modelIDs: ModelIDs
    public var extendedModelID: UInt8
    /// 0x0003 getDeviceSerialNumber (version 4 and later). Nil makes the function fail.
    public var serialNumber: String?
    /// In feature-table order; index 0 is always ROOT (0x0000).
    public var features: [Feature]
    public var controls: [ControlInfo]
    /// 0x0003 entities, in order.
    public var firmware: [Firmware]
    /// getSensorDpiList values as the device encodes them (0xE000 | step marks a range step).
    public var dpiList: [UInt16]
    /// The sensor's default resolution; also where it starts and what it returns to when it
    /// forgets a speed set over HID++.
    public var defaultDPI: Int?
    public var battery: Battery
    /// The battery level the device starts with (percent).
    public var batteryLevel: Int
    public var hostCount: Int
    /// HOSTS_INFO names by channel; missing or nil entries are unnamed.
    public var hostNames: [String?]

    public init(
        name: String,
        codename: String? = nil,
        kind: DeviceKind = .mouse,
        protocolMajor: UInt8 = 4,
        protocolMinor: UInt8 = 5,
        wirelessPID: UInt16? = nil,
        bluetoothPID: UInt16? = nil,
        usbPID: UInt16? = nil,
        unitID: UInt32? = nil,
        modelIDs: ModelIDs = ModelIDs(),
        extendedModelID: UInt8 = 0,
        serialNumber: String? = nil,
        features: [Feature] = [],
        controls: [ControlInfo] = [],
        firmware: [Firmware] = [],
        dpiList: [UInt16] = [],
        defaultDPI: Int? = nil,
        battery: Battery = .none,
        batteryLevel: Int = 80,
        hostCount: Int = 0,
        hostNames: [String?] = []
    ) {
        self.name = name
        self.codename = codename ?? name
        self.kind = kind
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.wirelessPID = wirelessPID
        self.bluetoothPID = bluetoothPID
        self.usbPID = usbPID
        self.unitID = unitID
        self.modelIDs = modelIDs
        self.extendedModelID = extendedModelID
        self.serialNumber = serialNumber
        self.features = features
        self.controls = controls
        self.firmware = firmware
        self.dpiList = dpiList
        self.defaultDPI = defaultDPI
        self.battery = battery
        self.batteryLevel = batteryLevel
        self.hostCount = hostCount
        self.hostNames = hostNames
    }

    // MARK: Lookups

    /// The feature-table index of `id`, as the device reports it.
    public func featureIndex(of id: UInt16) -> UInt8? {
        features.firstIndex { $0.id == id }.map(UInt8.init)
    }

    public func feature(_ id: UInt16) -> Feature? {
        features.first { $0.id == id }
    }

    public func control(_ cid: UInt16) -> ControlInfo? {
        controls.first { $0.cid == cid }
    }

    /// Answers HID++ 2.0 feature requests; false for a HID++ 1.0 device.
    public var speaksHIDPP20: Bool { protocolMajor >= 2 }

    /// The values getSensorDpiList describes, ascending.
    public var supportedDPI: [Int] {
        DPIInfo.parseList(dpiList.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }).values
    }

    /// DEVICE_NAME getDeviceType (0x0005 function 2); nil when the device can't tell.
    public var deviceTypeCode: UInt8? {
        switch kind {
        case .keyboard: return 0
        case .remote: return 1
        case .numpad: return 2
        case .mouse: return 3
        case .touchpad: return 4
        case .trackball: return 5
        case .presenter: return 6
        case .receiver: return 7
        case .other(let value): return value
        case .unknown: return nil
        }
    }

    /// The HID++ 1.0 kind nibble a receiver reports in pairing records and 0x41 notifications.
    public var pairingKindNibble: UInt8 {
        switch kind {
        case .unknown, .receiver: return 0
        case .keyboard: return 1
        case .mouse: return 2
        case .numpad: return 3
        case .presenter: return 4
        case .remote: return 7
        case .trackball: return 8
        case .touchpad: return 9
        case .other(let value): return value & 0x0F
        }
    }

    /// DEVICE_FW_VERSION getEntityCount reply (0x0003 function 0): [entity count, unit ID (4),
    /// transport (2), model IDs (6), extended model ID, capabilities]. One big-endian ID per
    /// transport bit (Bluetooth 0x01, BLE 0x02, wireless 0x04, USB 0x08), packed in bit order;
    /// at most three fit.
    public var firmwareIDsReply: [UInt8] {
        let unit = unitID ?? 0
        var bits: UInt8 = 0
        var ids: [UInt8] = []
        let transports: [(bit: UInt8, id: UInt16?)] = [
            (0x01, modelIDs.bluetooth), (0x02, modelIDs.bluetoothLE), (0x04, modelIDs.wireless), (0x08, modelIDs.usb),
        ]
        for (bit, id) in transports {
            guard let id else { continue }
            bits |= bit
            ids += [UInt8(id >> 8), UInt8(id & 0xFF)]
        }
        ids = Array((ids + [0, 0, 0, 0, 0, 0]).prefix(6))
        let hasSerial = serialNumber != nil && (feature(0x0003)?.version ?? 0) >= 4
        var reply: [UInt8] = [UInt8(clamping: firmware.count)]
        reply += [UInt8(unit >> 24), UInt8((unit >> 16) & 0xFF), UInt8((unit >> 8) & 0xFF), UInt8(unit & 0xFF)]
        reply += [0x00, bits]
        reply += ids
        reply += [extendedModelID, hasSerial ? 0x01 : 0x00]
        return reply
    }

    // MARK: Variants

    /// The same model with another unit ID and serial number: an identical second mouse.
    public func unit(_ unitID: UInt32?, serialNumber: String?) -> SimulatedDeviceProfile {
        var copy = self
        copy.unitID = unitID
        copy.serialNumber = serialNumber
        return copy
    }

    /// The same device under another 0x0005 name (the codename is kept).
    public func named(_ name: String) -> SimulatedDeviceProfile {
        var copy = self
        copy.name = name
        return copy
    }
}
