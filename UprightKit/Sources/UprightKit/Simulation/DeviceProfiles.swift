import Foundation

// Wave 0 scaffold: the MX Vertical only. W1.6 adds the other profiles (MX Master 3S, Lift,
// MX Keys, an HID++ 1.0 device, ...) from devices.verified.json, noting each source.

/// Ready-made simulated devices, for tests and Demo Mode.
public enum DeviceProfiles {
    /// PIDs and features from devices.verified.json (Solaar dump: btleid B020, wpid 407B,
    /// usbid C08A). The DPI list mirrors the test simulator; unit ID and serial are fake.
    public static let mxVertical = SimulatedDeviceProfile(
        name: "MX Vertical",
        kind: .mouse,
        wirelessPID: 0x407B,
        bluetoothPID: 0xB020,
        usbPID: 0xC08A,
        unitID: 0x1A2B_3C4D,
        modelIDs: ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A),
        serialNumber: "DEMO-0001",
        features: [
            .init(0x0000), .init(0x0001), .init(0x0005), .init(0x1000), .init(0x1B04, version: 4), .init(0x1D4B),
            .init(0x0003, version: 4), .init(0x2201), .init(0x1814), .init(0x1815),
        ],
        // Control table from the published dump in devices.verified.json (flags; additional
        // flags bit 0 = raw XY). Task IDs aren't published, so they are 0.
        controls: [
            ControlInfo(cid: 0x0050, taskID: 0, flags: [.mouseButton, .reprogrammable]),
            ControlInfo(cid: 0x0051, taskID: 0, flags: [.mouseButton, .reprogrammable]),
            ControlInfo(cid: 0x0052, taskID: 0, flags: [.mouseButton, .reprogrammable, .divertable, .persistentlyDivertable], additionalFlags: 0x01),
            ControlInfo(cid: 0x0053, taskID: 0, flags: [.mouseButton, .reprogrammable, .divertable, .persistentlyDivertable], additionalFlags: 0x01),
            ControlInfo(cid: 0x0056, taskID: 0, flags: [.mouseButton, .reprogrammable, .divertable, .persistentlyDivertable], additionalFlags: 0x01),
            ControlInfo(cid: 0x00FD, taskID: 0, flags: [.mouseButton, .reprogrammable, .divertable, .persistentlyDivertable], additionalFlags: 0x01),
            ControlInfo(cid: 0x00D7, taskID: 0, flags: [.divertable, .virtual], additionalFlags: 0x01),
        ],
        dpiList: [400, UInt16(0xE000) | UInt16(50), 4000],
        defaultDPI: 1000,
        battery: .status,
        hostCount: 3
    )

    public static let all: [SimulatedDeviceProfile] = [mxVertical]
}
