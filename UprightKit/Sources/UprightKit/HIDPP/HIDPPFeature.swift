/// HID++ 2.0 feature IDs used by Upright. Values come from the public HID++ 2.0
/// specification drafts and the open-source projects credited in the README.
public enum HIDPPFeature: UInt16, CaseIterable, Sendable {
    case root = 0x0000
    case featureSet = 0x0001
    case deviceFirmwareVersion = 0x0003
    case deviceName = 0x0005
    case batteryStatus = 0x1000
    case unifiedBattery = 0x1004
    case changeHost = 0x1814
    case hostsInfo = 0x1815
    case reprogControlsV4 = 0x1B04
    case wirelessDeviceStatus = 0x1D4B
    case smartShift = 0x2110
    case hiResWheel = 0x2121
    case adjustableDPI = 0x2201

    public var name: String {
        switch self {
        case .root: return "Root"
        case .featureSet: return "Feature Set"
        case .deviceFirmwareVersion: return "Firmware Version"
        case .deviceName: return "Device Name"
        case .batteryStatus: return "Battery Status"
        case .unifiedBattery: return "Unified Battery"
        case .changeHost: return "Easy-Switch"
        case .hostsInfo: return "Hosts Info"
        case .reprogControlsV4: return "Reprog Controls v4"
        case .wirelessDeviceStatus: return "Wireless Device Status"
        case .smartShift: return "SmartShift"
        case .hiResWheel: return "Hi-Res Wheel"
        case .adjustableDPI: return "Adjustable DPI"
        }
    }

    public static func name(for id: UInt16) -> String {
        HIDPPFeature(rawValue: id)?.name ?? String(format: "Feature 0x%04X", id)
    }
}

/// One row of a device's feature table.
public struct FeatureEntry: Hashable, Sendable, Identifiable {
    public var index: UInt8
    public var featureID: UInt16
    public var version: UInt8
    public var flags: UInt8

    public var id: UInt8 { index }
    public var name: String { HIDPPFeature.name(for: featureID) }

    public init(index: UInt8, featureID: UInt16, version: UInt8, flags: UInt8) {
        self.index = index
        self.featureID = featureID
        self.version = version
        self.flags = flags
    }
}
