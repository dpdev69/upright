import Foundation

/// Ready-made simulated devices, for tests and Demo Mode.
///
/// Sources: `scratchpad/research/devices.verified.json` (high and medium confidence entries
/// only), which cites the Solaar device dumps (`Solaar/docs/devices/*.txt`) each profile
/// copies its name, kind, protocol, product IDs, feature table (order, versions and flags
/// where the dump prints them), control table and firmware strings from. The MX Keys and the
/// HID++ 1.0 M510 aren't mice in that file's list; their dumps are cited directly.
///
/// Not published anywhere, so made up: DPI lists (read at runtime on real hardware), task IDs
/// (0), battery levels, host names, and every unit ID and serial number. Unit IDs follow the
/// obviously fake pattern `0x?A2B3C4D` and serials `DEMO-00NN`; nothing is a real device's.
public enum DeviceProfiles {
    // MARK: Mice

    /// MX Vertical, the model Upright is tested on (Unifying, Bluetooth LE, USB).
    ///
    /// devices.verified.json "MX Vertical (Advanced Ergonomic Mouse)" (high): wpid 407B, btid
    /// B020, usbid C08A; 0x0003 Transport IDs btleid B020, wpid 407B, usbid C08A. Feature table,
    /// controls, name and firmware from "MX Vertical Wireless Mouse 407B.txt". That dump prints
    /// no feature versions: 0x0003 v4 (serial readable) and 0x1B04 v4 are the values Upright's
    /// tests have always used. The DPI list (400...4000 in steps of 50) is the tests' stand-in.
    public static let mxVertical = SimulatedDeviceProfile(
        name: "MX Vertical Advanced Ergonomic Mouse",
        codename: "MX Vertical",
        kind: .mouse,
        wirelessPID: 0x407B,
        bluetoothPID: 0xB020,
        usbPID: 0xC08A,
        unitID: 0x1A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A),
        serialNumber: "DEMO-0001",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003, version: 4), .init(0x0005), .init(0x1D4B), .init(0x0020),
            .init(0x0021), .init(0x0007), .init(0x1000), .init(0x1002), .init(0x1B04, version: 4), .init(0x1C00),
            .init(0x1814), .init(0x1815), .init(0x2250), .init(0x18B1, flags: 0x60), .init(0x2100), .init(0x2130),
            .init(0x2201), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60), .init(0x1806, flags: 0x60),
            .init(0x1813, flags: 0x60), .init(0x1805, flags: 0x60), .init(0x1830, flags: 0x60), .init(0x1890, flags: 0x60),
            .init(0x1891, flags: 0x60), .init(0x18A1, flags: 0x60), .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40),
            .init(0x1EB0, flags: 0x60), .init(0x1E22, flags: 0x60), .init(0x1861, flags: 0x60), .init(0x18C0, flags: 0x60),
        ],
        controls: [
            control(0x0050, [.mouseButton, .reprogrammable], group: 1, mask: g1, analytics: true),
            control(0x0051, [.mouseButton, .reprogrammable], group: 1, mask: g1, analytics: true),
            control(0x0052, persistentButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x0053, persistentButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x0056, persistentButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x00FD, persistentButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            virtualGestureButton(group: 3),
        ],
        firmware: [.bootloader("BOT", 0x78, 0x00, build: 0x0009), .firmware("MPM", 0x16, 0x00, build: 0x0009), .other],
        dpiList: [400, step(50), 4000],
        defaultDPI: 1000,
        battery: .status,
        batteryLevel: 50,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// A second MX Vertical: same model, another unit (identical-model pairs).
    public static let mxVerticalSecondUnit = mxVertical.unit(0x1A2B_3C4E, serialNumber: "DEMO-0002")

    /// MX Master 3S (Bolt and Bluetooth LE only; a Bolt receiver reports its BLE PID).
    ///
    /// devices.verified.json "MX Master 3S" (high): btid B034, wpid B034 (Bolt); 0x0003 Transport
    /// IDs btleid B034. Everything else, including every feature version (0x1B04 v5), from
    /// "MX Master 3S B034.txt". The DPI list (200...8000 in steps of 50) is a stand-in; the dump
    /// shows 1000 DPI in use.
    public static let mxMaster3S = SimulatedDeviceProfile(
        name: "MX Master 3S",
        codename: "MX Master 3S",
        kind: .mouse,
        wirelessPID: 0xB034,
        bluetoothPID: 0xB034,
        unitID: 0x2A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB034),
        serialNumber: "DEMO-0003",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003, version: 4), .init(0x0005), .init(0x1D4B), .init(0x0020),
            .init(0x0021, version: 1), .init(0x0007), .init(0x1004, version: 3), .init(0x1B04, version: 5),
            .init(0x1814, version: 1), .init(0x1815, version: 2), .init(0x2250, version: 1), .init(0x2201, version: 2),
            .init(0x2110), .init(0x2121, version: 1), .init(0x2150), .init(0x2251), .init(0x00C3),
            .init(0x1802, flags: 0x70), .init(0x1803, flags: 0x70), .init(0x1806, version: 8, flags: 0x70),
            .init(0x1816, flags: 0x70), .init(0x1805, flags: 0x60), .init(0x1830, flags: 0x70),
            .init(0x1891, version: 7, flags: 0x68), .init(0x18A1, flags: 0x70), .init(0x1E00, flags: 0x40),
            .init(0x1E02, flags: 0x60), .init(0x1602), .init(0x1EB0, flags: 0x70), .init(0x1861, version: 1, flags: 0x70),
            .init(0x9300, flags: 0x70), .init(0x9001, flags: 0x70), .init(0x1E22, flags: 0x70), .init(0x9205, flags: 0x70),
        ],
        controls: [
            control(0x0050, [.mouseButton], group: 1, mask: g1, analytics: true),
            control(0x0051, [.mouseButton], group: 1, mask: g1, analytics: true),
            control(0x0052, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x0053, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x0056, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x00C3, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x00C4, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            virtualGestureButton(group: 3),
        ],
        firmware: [.bootloader("BL1", 0x69, 0x00, build: 0x0003), .firmware("RBM", 0x22, 0x00, build: 0x0003), .other],
        dpiList: [200, step(50), 8000],
        defaultDPI: 1000,
        battery: .unified,
        batteryLevel: 25,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// Lift (Bolt and Bluetooth LE): the MX Vertical's buttons, nothing persistently divertable.
    ///
    /// devices.verified.json "Lift (LIFT VERTICAL ERGONOMIC MOUSE)" (high): btid B031, wpid B031
    /// (Bolt); 0x0003 Transport IDs btleid B031. Table, controls (including the unnamed 0x0800
    /// key flag on Back and Forward) and firmware from "LIFT VERTICAL ERGONOMIC MOUSE B031.txt".
    /// That dump prints no versions; 0x0003 v4, 0x1004 v3, 0x1B04 v5, 0x1814 v1, 0x1815 v2 and
    /// 0x2201 v2 come from the "LIFT For Business B033.txt" dump (same RBM 21 firmware family).
    /// The DPI list (400...4000 in steps of 50) is a stand-in; the dump shows 2400 DPI in use.
    public static let lift = SimulatedDeviceProfile(
        name: "LIFT VERTICAL ERGONOMIC MOUSE",
        codename: "LIFT",
        kind: .mouse,
        wirelessPID: 0xB031,
        bluetoothPID: 0xB031,
        unitID: 0x3A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB031),
        serialNumber: "DEMO-0004",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003, version: 4), .init(0x0005), .init(0x1D4B), .init(0x0020),
            .init(0x0021), .init(0x0007), .init(0x1004, version: 3), .init(0x1B04, version: 5), .init(0x1814, version: 1),
            .init(0x1815, version: 2), .init(0x2250), .init(0x2130), .init(0x2201, version: 2), .init(0x00C3),
            .init(0x1802, flags: 0x70), .init(0x1803, flags: 0x70), .init(0x1806, flags: 0x70), .init(0x1816, flags: 0x70),
            .init(0x1805, flags: 0x60), .init(0x1830, flags: 0x70), .init(0x1891, flags: 0x68), .init(0x18A1, flags: 0x70),
            .init(0x1E00, flags: 0x40), .init(0x1E02, flags: 0x60), .init(0x1E22, flags: 0x70), .init(0x1602),
            .init(0x1EB0, flags: 0x70), .init(0x1861, flags: 0x70), .init(0x18B1, flags: 0x70),
        ],
        controls: [
            control(0x0050, [.mouseButton], group: 1, mask: 0, analytics: true),
            control(0x0051, [.mouseButton], group: 1, mask: 0, analytics: true),
            control(0x0052, divertableButton, group: 3, mask: g1g2g3, rawXY: true, analytics: true),
            control(0x0053, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true, extra: 0x08),
            control(0x0056, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true, extra: 0x08),
            control(0x00FD, divertableButton, group: 3, mask: g1g2g3, rawXY: true, analytics: true),
            virtualGestureButton(group: 4),
        ],
        firmware: [.bootloader("BL1", 0x56, 0x00, build: 0x0008), .firmware("RBM", 0x21, 0x00, build: 0x0008), .other],
        dpiList: [400, step(50), 4000],
        defaultDPI: 1000,
        battery: .unified,
        batteryLevel: 100,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// MX Master 3 (Unifying and Bluetooth LE).
    ///
    /// devices.verified.json "MX Master 3" (high): btid B023, wpid 4082; 0x0003 Transport IDs
    /// btleid B023, wpid 4082. Table, controls, name and firmware from "MX Master 3 Wireless
    /// Mouse 4082.txt", which prints no versions (0x0003 v0: no readable serial). The DPI list
    /// (200...4000 in steps of 50) is a stand-in; the dump shows 1600 DPI in use.
    public static let mxMaster3 = SimulatedDeviceProfile(
        name: "Wireless Mouse MX Master 3",
        codename: "MX Master 3",
        kind: .mouse,
        wirelessPID: 0x4082,
        bluetoothPID: 0xB023,
        unitID: 0x4A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB023, wireless: 0x4082),
        serialNumber: "DEMO-0005",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003), .init(0x0005), .init(0x1D4B), .init(0x0020), .init(0x0021),
            .init(0x0007), .init(0x1000), .init(0x1B04), .init(0x1814), .init(0x2250), .init(0x2201), .init(0x2110),
            .init(0x2121), .init(0x2150), .init(0x2251), .init(0x00C2), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60),
            .init(0x1806, flags: 0x60), .init(0x1813, flags: 0x60), .init(0x1805, flags: 0x60), .init(0x1830, flags: 0x60),
            .init(0x1890, flags: 0x60), .init(0x1891, flags: 0x60), .init(0x18A1, flags: 0x60), .init(0x1DF3, flags: 0x60),
            .init(0x1E00, flags: 0x40), .init(0x1EB0, flags: 0x60), .init(0x1861, flags: 0x60), .init(0x9001, flags: 0x60),
            .init(0x9203, flags: 0x60), .init(0x9205, flags: 0x60),
        ],
        controls: [
            control(0x0050, [.mouseButton], group: 1, mask: g1, analytics: true),
            control(0x0051, [.mouseButton], group: 1, mask: g1, analytics: true),
            control(0x0052, divertableButton, group: 3, mask: g1g2g3, rawXY: true, analytics: true),
            control(0x0053, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x0056, divertableButton, group: 2, mask: g1g2, rawXY: true, analytics: true),
            control(0x00C3, divertableButton, group: 3, mask: g1g2g3, rawXY: true, analytics: true),
            control(0x00C4, divertableButton, group: 3, mask: g1g2g3, rawXY: true, analytics: true),
            virtualGestureButton(group: 4),
        ],
        firmware: [.bootloader("BOT", 0x95, 0x01, build: 0x0015), .firmware("MPM", 0x19, 0x01, build: 0x0015), .other],
        dpiList: [200, step(50), 4000],
        defaultDPI: 1000,
        battery: .status,
        batteryLevel: 100,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// M720 Triathlon: tilt buttons and a 0xD0 thumb button, but no ADJUSTABLE_DPI (only
    /// 0x2205 pointer speed), so Upright shows no DPI controls for it.
    ///
    /// devices.verified.json "M720 Triathlon" (high): btid B015, wpid 405E; 0x0003 Transport IDs
    /// btleid B015, wpid 405E. Table, controls, name and firmware from "M720 Triathlon
    /// Multi-Device Mouse 405E.txt" (no versions printed).
    public static let m720 = SimulatedDeviceProfile(
        name: "M720 Triathlon Multi-Device Mouse",
        codename: "M720 Triathlon",
        kind: .mouse,
        wirelessPID: 0x405E,
        bluetoothPID: 0xB015,
        unitID: 0x5A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB015, wireless: 0x405E),
        serialNumber: "DEMO-0006",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003), .init(0x0005), .init(0x1D4B), .init(0x0020), .init(0x0021),
            .init(0x0007), .init(0x1000), .init(0x1814), .init(0x1815), .init(0x1B04), .init(0x1C00), .init(0x2205),
            .init(0x2100), .init(0x00C1), .init(0x00C2), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60),
            .init(0x1806, flags: 0x60), .init(0x1805, flags: 0x60), .init(0x1813, flags: 0x60), .init(0x1830, flags: 0x60),
            .init(0x1861, flags: 0x60), .init(0x1890, flags: 0x60), .init(0x1891, flags: 0x60), .init(0x18A1, flags: 0x60),
            .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40), .init(0x1EB0, flags: 0x60), .init(0x18B1, flags: 0x60),
            .init(0x1850, flags: 0x60), .init(0x1E22), .init(0x1F03, flags: 0x60), .init(0x18C0, flags: 0x60), .init(0x2121),
        ],
        controls: [
            control(0x0050, [.mouseButton, .reprogrammable], group: 1, mask: g1),
            control(0x0051, [.mouseButton, .reprogrammable], group: 1, mask: g1),
            control(0x0052, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x0053, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x0056, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x005B, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x005D, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x00D0, persistentButton, group: 2, mask: g1g2, rawXY: true),
            virtualGestureButton(group: 3),
        ],
        firmware: [.bootloader("BOT", 0x34, 0x01, build: 0x0005), .firmware("MPM", 0x04, 0x10, build: 0x0013), .other],
        battery: .status,
        batteryLevel: 90,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// MX Ergo: a trackball (0x0005 kind 5) with tilt buttons and a precision-mode key, no
    /// ADJUSTABLE_DPI.
    ///
    /// devices.verified.json "MX Ergo (Multi-Device Trackball)" (high): btid B01D, wpid 406F;
    /// 0x0003 Transport IDs btleid B01D, wpid 406F. Table, controls, name and firmware from
    /// "MX Ergo Multi-Device Trackball 406F.txt" (no versions printed).
    public static let mxErgo = SimulatedDeviceProfile(
        name: "MX Ergo Multi-Device Trackball",
        codename: "MX Ergo",
        kind: .trackball,
        wirelessPID: 0x406F,
        bluetoothPID: 0xB01D,
        unitID: 0x6A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB01D, wireless: 0x406F),
        serialNumber: "DEMO-0007",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003), .init(0x0005), .init(0x1D4B), .init(0x0007), .init(0x0020),
            .init(0x0021), .init(0x1000), .init(0x1300), .init(0x1B04), .init(0x1C00), .init(0x2006), .init(0x2205),
            .init(0x2100), .init(0x00C2), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60), .init(0x1806, flags: 0x60),
            .init(0x1805, flags: 0x60), .init(0x1813, flags: 0x60), .init(0x1814), .init(0x1815), .init(0x1830, flags: 0x60),
            .init(0x1861, flags: 0x60), .init(0x1890, flags: 0x60), .init(0x1891, flags: 0x60), .init(0x18A1, flags: 0x60),
            .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40), .init(0x1EB0, flags: 0x60), .init(0x18B1, flags: 0x60),
            .init(0x1850, flags: 0x60), .init(0x1F03, flags: 0x60), .init(0x18C0, flags: 0x60),
        ],
        controls: [
            control(0x0050, [.mouseButton, .reprogrammable], group: 1, mask: g1),
            control(0x0051, [.mouseButton, .reprogrammable], group: 1, mask: g1),
            control(0x0052, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x0053, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x0056, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x00ED, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x005B, persistentButton, group: 2, mask: g1g2, rawXY: true),
            control(0x005D, persistentButton, group: 2, mask: g1g2, rawXY: true),
            virtualGestureButton(group: 3),
        ],
        firmware: [.bootloader("BOT", 0x49, 0x00, build: 0x0001), .firmware("MPM", 0x06, 0x03, build: 0x0022), .other],
        battery: .status,
        batteryLevel: 50,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// M185 / M235 / M310 (wpid 4055): a budget HID++ 2.0 mouse whose Left and Right buttons
    /// are flagged divertable (Upright must still never divert them), no DPI, no Easy-Switch.
    /// Nano receivers host 40xx mice like it.
    ///
    /// devices.verified.json "M185 / M235 / M310 (wpid 4055)" (medium); 0x0003 Transport IDs
    /// wpid 4055 only. Table, controls, name and firmware from "Wireless Mouse M185,M235,M310
    /// 4055.txt" (no versions printed, no bootloader entity).
    public static let m185 = SimulatedDeviceProfile(
        name: "Wireless Mouse",
        codename: "M185/M235/M310",
        kind: .mouse,
        wirelessPID: 0x4055,
        unitID: 0x7A2B_3C4D,
        modelIDs: ModelIDs(wireless: 0x4055),
        serialNumber: "DEMO-0008",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003), .init(0x0005), .init(0x0020), .init(0x1000),
            .init(0x1810, flags: 0x60), .init(0x1830, flags: 0x60), .init(0x1802, flags: 0x60), .init(0x1862, flags: 0x60),
            .init(0x1890, flags: 0x60), .init(0x18A0, flags: 0x60), .init(0x18B1, flags: 0x60), .init(0x1B04), .init(0x1D4B),
            .init(0x1DF0, flags: 0x40), .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40), .init(0x1EB0, flags: 0x60),
            .init(0x1F03, flags: 0x60), .init(0x2130),
        ],
        controls: [
            control(0x0050, [.mouseButton, .divertable], group: 1, mask: g1),
            control(0x0051, [.mouseButton, .divertable], group: 1, mask: g1),
            control(0x0052, divertableButton, group: 2, mask: g1g2, rawXY: true),
        ],
        firmware: [.firmware("RQM", 0x65, 0x00, build: 0x0003)],
        battery: .status,
        batteryLevel: 70
    )

    /// G502 Lightspeed: HID++ 4.2 with no REPROG_CONTROLS_V4 (its buttons live in onboard
    /// profiles, 0x8100), so Upright reports it unsupported. Battery through 0x1001 (voltage).
    ///
    /// devices.verified.json "G502 Lightspeed (G502 Hero Wireless)" (medium): wpid 407F, usbid
    /// C08D, Lightspeed receiver; 0x0003 Model ID 407FC08D0000. Table (with versions), name and
    /// firmware from "G502 Lightspeed Wireless Gaming Mouse 407F.txt". The DPI list is a
    /// stand-in; the dump shows 900 DPI in use.
    public static let g502Lightspeed = SimulatedDeviceProfile(
        name: "G502 LIGHTSPEED Wireless Gaming Mouse",
        codename: "G502",
        kind: .mouse,
        protocolMajor: 4,
        protocolMinor: 2,
        wirelessPID: 0x407F,
        usbPID: 0xC08D,
        unitID: 0x9A2B_3C4D,
        modelIDs: ModelIDs(wireless: 0x407F, usb: 0xC08D),
        serialNumber: "DEMO-0010",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003, version: 2), .init(0x0005), .init(0x1D4B), .init(0x0020),
            .init(0x1001, version: 2), .init(0x8070, version: 4), .init(0x1300), .init(0x8100), .init(0x8110), .init(0x8060),
            .init(0x2201, version: 1), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60), .init(0x1805, flags: 0x60),
            .init(0x1806, version: 4, flags: 0x60), .init(0x1811, flags: 0x60), .init(0x1830, flags: 0x60),
            .init(0x1890, version: 4, flags: 0x60), .init(0x1891, version: 4, flags: 0x60), .init(0x18A1, flags: 0x60),
            .init(0x1801, flags: 0x60), .init(0x18B1, flags: 0x60), .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40),
            .init(0x1EB0, flags: 0x60), .init(0x1863, flags: 0x60), .init(0x1E22, flags: 0x60), .init(0x2121),
        ],
        firmware: [.bootloader("BOT", 0x92, 0x00, build: 0x0008), .firmware("MPM", 0x17, 0x00, build: 0x0008), .other],
        dpiList: [100, step(50), 8000],
        defaultDPI: 800,
        battery: .voltage,
        batteryLevel: 90
    )

    /// A mouse that reports no unit ID and no serial number (its `DeviceID` falls back to a
    /// transient one): the MX Master 3 with both removed.
    public static let mouseWithoutUnitID = mxMaster3.unit(nil, serialNumber: nil)

    // MARK: Not mice

    /// MX Keys: a keyboard (0x0005 kind 0, pairing kind 1) whose 0x1B04 table is full of
    /// divertable keys. Upright must never write to it (the anti-hijack test).
    ///
    /// From "MX Keys Keyboard 408A.txt" (keyboards aren't in devices.verified.json): wpid 408A,
    /// 0x0003 Transport IDs btleid B35B, wpid 408A, every feature version, name and firmware.
    /// Key CIDs come from devices.verified.json `cidTableFull` by name; the six "… Fn" media keys
    /// and "Lock PC" have no entry there and are left out.
    public static let mxKeys = SimulatedDeviceProfile(
        name: "MX Keys Wireless Keyboard",
        codename: "MX Keys",
        kind: .keyboard,
        wirelessPID: 0x408A,
        bluetoothPID: 0xB35B,
        unitID: 0x8A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB35B, wireless: 0x408A),
        serialNumber: "DEMO-0009",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0003, version: 2), .init(0x0005), .init(0x1D4B), .init(0x0020),
            .init(0x0007), .init(0x1000, version: 1), .init(0x1B04, version: 4), .init(0x1814, version: 1),
            .init(0x1815, version: 1), .init(0x1982, version: 1), .init(0x40A3), .init(0x4100), .init(0x4220), .init(0x4521),
            .init(0x4531, version: 1), .init(0x00C2), .init(0x1802, flags: 0x60), .init(0x1803, flags: 0x60),
            .init(0x1806, version: 5, flags: 0x60), .init(0x1813, flags: 0x60), .init(0x1805, flags: 0x60),
            .init(0x1830, flags: 0x60), .init(0x1890, version: 5, flags: 0x60), .init(0x1891, version: 5, flags: 0x60),
            .init(0x18A1, flags: 0x60), .init(0x1DF3, flags: 0x60), .init(0x1E00, flags: 0x40), .init(0x1EB0, flags: 0x60),
            .init(0x1861, flags: 0x60), .init(0x1A20, flags: 0x60),
        ],
        controls: [
            control(0x00D1, [.nonStandard, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00D2, [.nonStandard, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00D3, [.nonStandard, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00C7, fnKey, position: 1, analytics: true),
            control(0x00C8, fnKey, position: 2, analytics: true),
            control(0x00E0, fnKey, position: 3, analytics: true),
            control(0x00E1, fnKey, position: 4, analytics: true),
            control(0x006E, fnKey, position: 5, analytics: true),
            control(0x00E2, fnKey, position: 6, analytics: true),
            control(0x00E3, fnKey, position: 7, analytics: true),
            control(0x000A, [.nonStandard, .reprogrammable, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00BF, [.nonStandard, .reprogrammable, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00EA, [.nonStandard, .reprogrammable, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00EC, [.nonStandard, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00EB, [.nonStandard, .divertable, .persistentlyDivertable], analytics: true),
            control(0x00DE, [.fnKey], analytics: true),
            control(0x0034, [.nonStandard], analytics: true),
        ],
        firmware: [.bootloader("BL1", 0x08, 0x00, build: 0x0011), .firmware("MPK", 0x12, 0x00, build: 0x0011), .other],
        battery: .status,
        batteryLevel: 50,
        hostCount: 3,
        hostNames: demoHostNames
    )

    /// Wireless Mouse M510 (wpid 1025): HID++ 1.0 only, so every HID++ 2.0 request fails with
    /// "invalid sub-ID" and Upright reports it unsupported.
    ///
    /// devices.verified.json "M510 (v2)" notes "older M510 wpid 1025 is HID++ 1.0"; name,
    /// codename and protocol from "Wireless Mouse M510 1025.txt". Its unit ID is only what the
    /// receiver lists as the slot's serial.
    public static let m510HIDPP10 = SimulatedDeviceProfile(
        name: "Wireless Mouse M510",
        codename: "M510",
        kind: .mouse,
        protocolMajor: 1,
        protocolMinor: 0,
        wirelessPID: 0x1025,
        unitID: 0xAA2B_3C4D
    )

    /// The three mice Demo Mode shows by default.
    public static let demoMice: [SimulatedDeviceProfile] = [mxVertical, mxMaster3S, lift]

    public static let all: [SimulatedDeviceProfile] = [
        mxVertical, mxVerticalSecondUnit, mxMaster3S, lift, mxMaster3, m720, mxErgo, m185, g502Lightspeed,
        mouseWithoutUnitID, mxKeys, m510HIDPP10,
    ]

    // MARK: Building blocks

    /// Made up: real host names in the dumps are people's computers.
    static let demoHostNames: [String?] = ["Demo Mac", nil, nil]

    private static let g1: UInt8 = 0x01
    private static let g1g2: UInt8 = 0x03
    private static let g1g2g3: UInt8 = 0x07

    /// "mse, reprogrammable, divertable"
    private static let divertableButton: ControlFlags = [.mouseButton, .reprogrammable, .divertable]
    /// "mse, reprogrammable, divertable, persistently divertable"
    private static let persistentButton: ControlFlags = [.mouseButton, .reprogrammable, .divertable, .persistentlyDivertable]
    /// "is FN, FN sensitive, reprogrammable, divertable, persistently divertable"
    private static let fnKey: ControlFlags = [.fnKey, .fnSensitive, .reprogrammable, .divertable, .persistentlyDivertable]

    /// A range step in getSensorDpiList (top three bits set).
    private static func step(_ value: UInt16) -> UInt16 {
        UInt16(0xE000) | value
    }

    /// One getCidInfo entry. Additional flags (Solaar's KeyFlag >> 8): raw XY 0x01, force raw
    /// XY 0x02, analytics key events 0x04; `extra` carries bits the dump shows as unknown.
    private static func control(
        _ cid: UInt16,
        _ flags: ControlFlags,
        position: UInt8 = 0,
        group: UInt8 = 0,
        mask: UInt8 = 0,
        rawXY: Bool = false,
        forceRawXY: Bool = false,
        analytics: Bool = false,
        extra: UInt8 = 0
    ) -> ControlInfo {
        var additional = extra
        if rawXY { additional |= 0x01 }
        if forceRawXY { additional |= 0x02 }
        if analytics { additional |= 0x04 }
        return ControlInfo(cid: cid, taskID: 0, flags: flags, position: position, group: group, groupMask: mask, additionalFlags: additional)
    }

    /// 0x00D7 "divertable, virtual, raw XY, force raw XY", group mask empty.
    private static func virtualGestureButton(group: UInt8) -> ControlInfo {
        control(0x00D7, [.divertable, .virtual], group: group, rawXY: true, forceRawXY: true)
    }
}
