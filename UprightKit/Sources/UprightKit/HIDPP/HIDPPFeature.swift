/// HID++ 2.0 feature IDs used by Upright. Values come from the public HID++ 2.0
/// specification drafts and the open-source projects credited in the README.
public enum HIDPPFeature: UInt16, CaseIterable, Sendable {
    case root = 0x0000
    case featureSet = 0x0001
    case deviceFirmwareVersion = 0x0003
    case deviceName = 0x0005
    case batteryStatus = 0x1000
    case batteryVoltage = 0x1001
    case unifiedBattery = 0x1004
    case changeHost = 0x1814
    case hostsInfo = 0x1815
    /// Older REPROG_CONTROLS revisions. Upright needs v4 (0x1B04); these are named for reports.
    case reprogControls = 0x1B00
    case reprogControlsV2 = 0x1B01
    case reprogControlsV2_2 = 0x1B02
    case reprogControlsV3 = 0x1B03
    case reprogControlsV4 = 0x1B04
    case persistentRemappableAction = 0x1C00
    case wirelessDeviceStatus = 0x1D4B
    case smartShift = 0x2110
    case hiResWheel = 0x2121
    case adjustableDPI = 0x2201
    /// Pointer speed on some gaming mice; Upright reads speed through 0x2201 only.
    case extendedAdjustableDPI = 0x2202
    /// Pointer-speed multiplier on mice without 0x2201 (M720, MX Ergo); not used for speed.
    case pointerSpeed = 0x2205

    public var name: String {
        switch self {
        case .root: return "Root"
        case .featureSet: return "Feature Set"
        case .deviceFirmwareVersion: return "Firmware Version"
        case .deviceName: return "Device Name"
        case .batteryStatus: return "Battery Status"
        case .batteryVoltage: return "Battery Voltage"
        case .unifiedBattery: return "Unified Battery"
        case .changeHost: return "Easy-Switch"
        case .hostsInfo: return "Hosts Info"
        case .reprogControls: return "Reprog Controls"
        case .reprogControlsV2: return "Reprog Controls v2"
        case .reprogControlsV2_2: return "Reprog Controls v2.2"
        case .reprogControlsV3: return "Reprog Controls v3"
        case .reprogControlsV4: return "Reprog Controls v4"
        case .persistentRemappableAction: return "Persistent Remappable Action"
        case .wirelessDeviceStatus: return "Wireless Device Status"
        case .smartShift: return "SmartShift"
        case .hiResWheel: return "Hi-Res Wheel"
        case .adjustableDPI: return "Adjustable DPI"
        case .extendedAdjustableDPI: return "Extended Adjustable DPI"
        case .pointerSpeed: return "Pointer Speed"
        }
    }

    /// The feature's name for logs and device reports, or "Feature 0x%04X" when unknown.
    public static func name(for id: UInt16) -> String {
        HIDPPFeature(rawValue: id)?.name ?? otherNames[id] ?? String(format: "Feature 0x%04X", id)
    }

    /// Names of features Upright doesn't use, so device reports stay readable
    /// (IDs as listed in Solaar's `SupportedFeature`).
    private static let otherNames: [UInt16: String] = [
        0x0002: "Feature Info",
        0x0004: "Unit ID",
        0x0006: "Device Groups",
        0x0007: "Friendly Name",
        0x0008: "Keep Alive",
        0x0011: "Property Access",
        0x0020: "Config Change",
        0x0021: "Crypto ID",
        0x0030: "Target Software",
        0x0080: "Wireless Signal Strength",
        0x00C0: "DFU Control (Legacy)",
        0x00C1: "DFU Control (Unsigned)",
        0x00C2: "DFU Control (Signed)",
        0x00C3: "DFU Control",
        0x00D0: "DFU",
        0x1010: "Charging Control",
        0x1300: "LED Control",
        0x1500: "Force Pairing",
        0x1800: "Generic Test",
        0x1802: "Device Reset",
        0x1805: "OOB State",
        0x1806: "Config Device Props",
        0x1816: "BLE Pro Pre-Pairing",
        0x1981: "Backlight",
        0x1982: "Backlight 2",
        0x1983: "Backlight 3",
        0x1990: "Illumination",
        0x19B0: "Haptic",
        0x19C0: "Force Sensing Button",
        0x1A00: "Presenter Control",
        0x1B05: "Full Key Customization",
        0x1B10: "Control List",
        0x1DF0: "Remaining Pairing",
        0x1E00: "Enable Hidden Features",
        0x1F1F: "Firmware Properties",
        0x1F20: "ADC Measurement",
        0x2001: "Left/Right Swap",
        0x2005: "Swap Button Cancel",
        0x2006: "Pointer Axis Orientation",
        0x2100: "Vertical Scrolling",
        0x2111: "SmartShift Enhanced",
        0x2120: "Hi-Res Scrolling",
        0x2130: "Low-Res Wheel",
        0x2150: "Thumb Wheel",
        0x2200: "Mouse Pointer",
        0x2230: "Angle Snapping",
        0x2240: "Surface Tuning",
        0x2250: "XY Stats",
        0x2251: "Wheel Stats",
        0x2400: "Hybrid Tracking",
        0x40A0: "Fn Inversion",
        0x4100: "Encryption",
        0x4220: "Lock Key State",
        0x4520: "Keyboard Layout",
        0x4531: "Multi-Platform",
        0x6100: "Touchpad Raw XY",
        0x6500: "Gesture",
        0x6501: "Gesture 2",
        0x8060: "Report Rate",
        0x8061: "Extended Report Rate",
        0x8070: "Color LED Effects",
        0x8071: "RGB Effects",
        0x8090: "Mode Status",
        0x8100: "Onboard Profiles",
        0x8110: "Mouse Button Spy",
        0x8111: "Latency Monitoring",
    ]
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
