import Foundation

// Wave 0 scaffold: final signatures, MX Vertical and the receivers Upright already used.
// W1.1 owns this file and fills in the models and receivers from devices.verified.json.

/// What Upright knows about a mouse model before it is connected.
public struct DeviceModel: Hashable, Sendable, Identifiable {
    /// How well a model's entry is backed.
    public enum Verification: Hashable, Sendable {
        /// Tested on real hardware (the MX Vertical).
        case hardware
        /// Built from a published device dump (Solaar, libratbag); untested here.
        case publishedDump
        case unverified
    }

    public var key: ModelKey
    public var name: String
    public var usbPIDs: [UInt16]
    public var bluetoothPIDs: [UInt16]
    /// Receiver wireless PIDs (Unifying, Nano, Lightspeed), or the Bxxx PID a Bolt slot reports.
    public var wirelessPIDs: [UInt16]
    /// Display order of the model's controls; unlisted controls follow by CID.
    public var controlOrder: [UInt16]
    /// Per-model wording that overrides the generic control names.
    public var controlText: [UInt16: ControlText]
    /// The onboarding template.
    public var suggested: ButtonMappings
    public var verification: Verification

    public var id: ModelKey { key }

    public init(
        key: ModelKey,
        name: String,
        usbPIDs: [UInt16] = [],
        bluetoothPIDs: [UInt16] = [],
        wirelessPIDs: [UInt16] = [],
        controlOrder: [UInt16] = [],
        controlText: [UInt16: ControlText] = [:],
        suggested: ButtonMappings = ButtonMappings(),
        verification: Verification = .unverified
    ) {
        self.key = key
        self.name = name
        self.usbPIDs = usbPIDs
        self.bluetoothPIDs = bluetoothPIDs
        self.wirelessPIDs = wirelessPIDs
        self.controlOrder = controlOrder
        self.controlText = controlText
        self.suggested = suggested
        self.verification = verification
    }

    /// Every product ID the model is known by, on any transport.
    public var allPIDs: [UInt16] { bluetoothPIDs + wirelessPIDs + usbPIDs }
}

/// A Logitech receiver product. `layout == nil` means the receiver is never opened.
public struct ReceiverModel: Hashable, Sendable {
    public var productID: UInt16
    public var kind: ConnectionKind
    public var layout: PairingLayout?

    public init(productID: UInt16, kind: ConnectionKind, layout: PairingLayout?) {
        self.productID = productID
        self.kind = kind
        self.layout = layout
    }
}

public enum DeviceCatalog {
    public static let vendorID: Int = 0x046D

    public static let models: [DeviceModel] = [mxVertical]

    public static let receivers: [UInt16: ReceiverModel] = {
        var table: [UInt16: ReceiverModel] = [:]
        for pid: UInt16 in [0xC52B, 0xC532] {
            table[pid] = ReceiverModel(productID: pid, kind: .unifying, layout: .unifying)
        }
        table[0xC548] = ReceiverModel(productID: 0xC548, kind: .bolt, layout: .bolt)
        // Nano receivers use the Unifying pairing-register layout (D8).
        let nano: [UInt16] = [0xC52F, 0xC531, 0xC534, 0xC537, 0xC518, 0xC51A, 0xC51B, 0xC521, 0xC525, 0xC526, 0xC52E, 0xC535]
        for pid in nano {
            table[pid] = ReceiverModel(productID: pid, kind: .nano, layout: .unifying)
        }
        return table
    }()

    public static func model(_ key: ModelKey) -> DeviceModel? {
        models.first { $0.key == key }
    }

    public static func model(forPID pid: UInt16) -> DeviceModel? {
        models.first { $0.allPIDs.contains(pid) }
    }

    /// The canonical key (D5): the first catalog model matching any reported 0x0003 model ID,
    /// else the canonical 0x0003 ID itself, else the transport PID through catalog aliases,
    /// else the device name. Never reads `identity.model`.
    public static func modelKey(for identity: DeviceIdentity) -> ModelKey {
        for pid in identity.modelIDs.all {
            if let model = model(forPID: pid) { return model.key }
        }
        if let canonical = identity.modelIDs.canonical {
            return ModelKey(productID: canonical)
        }
        if let pid = identity.transportPID {
            return model(forPID: pid)?.key ?? ModelKey(productID: pid)
        }
        return ModelKey(name: identity.name)
    }

    // MARK: Models

    static let mxVertical = DeviceModel(
        key: .mxVertical,
        name: "MX Vertical",
        usbPIDs: [0xC08A],
        bluetoothPIDs: [0xB020],
        wirelessPIDs: [0x407B],
        controlOrder: [KnownControl.back, KnownControl.forward, KnownControl.dpiSwitch, KnownControl.middleClick],
        controlText: [
            KnownControl.back: ControlDescriptor(cid: KnownControl.back).text,
            KnownControl.forward: ControlDescriptor(cid: KnownControl.forward).text,
            KnownControl.dpiSwitch: ControlDescriptor(cid: KnownControl.dpiSwitch).text,
            KnownControl.dpiChange: ControlDescriptor(cid: KnownControl.dpiChange).text,
            KnownControl.middleClick: ControlDescriptor(cid: KnownControl.middleClick).text,
        ],
        suggested: .legacyDefaults,
        verification: .hardware
    )
}

extension ControlDescriptor {
    var text: ControlText { ControlText(name: name, detail: detail, symbolName: symbolName) }
}
