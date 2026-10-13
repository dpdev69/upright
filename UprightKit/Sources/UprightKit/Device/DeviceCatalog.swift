import Foundation

// Model data comes from Solaar's device dumps and libratbag's device files, as collected in
// scratchpad/research/devices.verified.json (entries with high or medium confidence only).
// Only the MX Vertical has been tested on hardware; every other entry is `.publishedDump`.
// The catalog is a convenience (names, suggested setups, receiver layouts): whether a device is
// served is decided by what it answers (see `EndpointController`), never by this table.

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

    /// Every product ID the model is known by, on any transport, without repeats. A Bolt
    /// device reports the same ID as its Bluetooth LE one.
    public var allPIDs: [UInt16] {
        var seen = Set<UInt16>()
        return (bluetoothPIDs + wirelessPIDs + usbPIDs).filter { seen.insert($0).inserted }
    }

    /// Sorts `cids` for display: the model's `controlOrder` first, the rest by CID.
    public func displayOrder(_ cids: [UInt16]) -> [UInt16] {
        DeviceCatalog.sort(cids, by: controlOrder)
    }
}

extension DeviceModel.Verification {
    /// Another spelling of `.publishedDump`.
    public static let publishedData: DeviceModel.Verification = .publishedDump
}

/// A Logitech receiver product. `layout == nil` means the receiver is never opened.
public struct ReceiverModel: Hashable, Sendable {
    /// The receiver's product line. Only the first three are opened.
    public enum Family: String, Hashable, Sendable {
        case unifying, bolt, nano, lightspeed
        /// The pre-Unifying 27 MHz receivers (HID++ 1.0 devices).
        case legacy27MHz
    }

    public var productID: UInt16
    /// How the mouse is reported to the user. Only meaningful when `layout` isn't nil.
    public var kind: ConnectionKind
    public var layout: PairingLayout?
    public var family: Family
    public var name: String

    public init(productID: UInt16, kind: ConnectionKind, layout: PairingLayout?, family: Family? = nil, name: String? = nil) {
        let resolved: Family
        switch (family, kind) {
        case (let family?, _): resolved = family
        case (nil, .bolt): resolved = .bolt
        case (nil, .nano): resolved = .nano
        default: resolved = .unifying
        }
        self.productID = productID
        self.kind = kind
        self.layout = layout
        self.family = resolved
        self.name = name ?? resolved.defaultName
    }

    /// Why the receiver is never opened, for the log; nil when it is served.
    public var exclusionReason: String? {
        guard layout == nil else { return nil }
        switch family {
        case .lightspeed:
            return "Lightspeed receiver: not supported (no programmable-button feature on its mice)"
        case .legacy27MHz:
            return "27 MHz receiver: not supported (pre-Unifying HID++ 1.0 devices)"
        case .unifying, .bolt, .nano:
            return "receiver not supported"
        }
    }
}

extension ReceiverModel.Family {
    var defaultName: String {
        switch self {
        case .unifying: return "Unifying receiver"
        case .bolt: return "Bolt receiver"
        case .nano: return "Nano receiver"
        case .lightspeed: return "Lightspeed receiver"
        case .legacy27MHz: return "27 MHz receiver"
        }
    }
}

/// A Logitech mouse known not to expose programmable buttons over HID++ (REPROG_CONTROLS_V4).
/// Listed for documentation and logs only: such a mouse, if its interface is opened at all,
/// ends in `.unsupported(.noReprogControls)` like any other.
public struct KnownUnsupportedDevice: Hashable, Sendable {
    public var name: String
    public var usbPIDs: [UInt16]
    public var bluetoothPIDs: [UInt16]
    public var wirelessPIDs: [UInt16]
    public var reason: String

    public var allPIDs: [UInt16] { bluetoothPIDs + wirelessPIDs + usbPIDs }
}

public enum DeviceCatalog {
    public static let vendorID: Int = 0x046D

    /// Every model Upright knows by name, the MX Vertical first.
    public static let models: [DeviceModel] = [
        mxVertical,
        mxMaster, mxMaster2S, mxMaster3, mxMaster3ForBusiness, mxMaster3S, mxMaster4,
        mxAnywhere2, mxAnywhere2S, mxAnywhere3, mxAnywhere3ForBusiness,
        mxErgo, lift, liftForBusiness,
        m720, m585, m650L, m550, m575, m705, pebbleM350, m510v2, m185,
    ]

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
        // Lightspeed receivers are never opened (D8): every G and PRO mouse in the research data
        // lacks REPROG_CONTROLS_V4, the C53A also hosts a PowerPlay chip, and G HUB owns them.
        let lightspeed: [UInt16] = [0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D]
        for pid in lightspeed {
            table[pid] = ReceiverModel(productID: pid, kind: .unifying, layout: nil, family: .lightspeed)
        }
        // The 27 MHz receiver pairs pre-Unifying HID++ 1.0 devices.
        table[0xC517] = ReceiverModel(productID: 0xC517, kind: .unifying, layout: nil, family: .legacy27MHz)
        return table
    }()

    /// G-series and PRO gaming mice, which keep their buttons in onboard profiles.
    public static let knownUnsupported: [KnownUnsupportedDevice] = {
        let reason = "Gaming mouse: its buttons are stored in onboard profiles, not exposed as programmable controls"
        func device(_ name: String, usb: [UInt16] = [], bluetooth: [UInt16] = [], wireless: [UInt16]) -> KnownUnsupportedDevice {
            KnownUnsupportedDevice(name: name, usbPIDs: usb, bluetoothPIDs: bluetooth, wirelessPIDs: wireless, reason: reason)
        }
        return [
            device("G Pro Wireless", usb: [0xC088], wireless: [0x4079]),
            device("G304 / G305 Lightspeed", wireless: [0x4074]),
            device("G502 Lightspeed", usb: [0xC08D], wireless: [0x407F]),
            device("G502 X Plus", usb: [0xC095], wireless: [0x4099]),
            device("G604", bluetooth: [0xB024], wireless: [0x4085]),
            device("G703 Lightspeed", usb: [0xC087], wireless: [0x4070]),
            device("G903 Lightspeed", usb: [0xC091], wireless: [0x4087]),
            device("PRO X Wireless", usb: [0xC094], wireless: [0x4093]),
            device("PRO X 2", usb: [0xC09B], wireless: [0x40A9]),
        ]
    }()

    private static let modelsByKey: [ModelKey: DeviceModel] = {
        Dictionary(models.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    private static let modelsByPID: [UInt16: DeviceModel] = {
        var table: [UInt16: DeviceModel] = [:]
        for model in models {
            for pid in model.allPIDs where table[pid] == nil { table[pid] = model }
        }
        return table
    }()

    public static func model(_ key: ModelKey) -> DeviceModel? {
        modelsByKey[key]
    }

    /// The model any of whose USB, Bluetooth or wireless product IDs is `pid`.
    public static func model(forPID pid: UInt16) -> DeviceModel? {
        modelsByPID[pid]
    }

    /// The known gaming mouse with this product ID on any transport, if any.
    public static func knownUnsupported(forPID pid: UInt16) -> KnownUnsupportedDevice? {
        knownUnsupported.first { $0.allPIDs.contains(pid) }
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

    /// Sorts `cids` for display: the model's `controlOrder` first (nil or an unknown model has
    /// none), the rest by CID.
    public static func sortedControls(_ cids: [UInt16], for model: ModelKey?) -> [UInt16] {
        sort(cids, by: model.flatMap { Self.model($0) }?.controlOrder ?? [])
    }

    static func sort(_ cids: [UInt16], by order: [UInt16]) -> [UInt16] {
        cids.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs) ?? Int.max
            let r = order.firstIndex(of: rhs) ?? Int.max
            return l == r ? lhs < rhs : l < r
        }
    }

    /// The onboarding template for a mouse with these controls: Back and Forward navigate,
    /// a gesture button opens Mission Control, and everything else stays native. (The MX
    /// Vertical keeps what Upright 1.x shipped, `ButtonMappings.legacyDefaults`.)
    public static func suggestedMappings(forControls cids: [UInt16]) -> ButtonMappings {
        var table: [UInt16: ButtonAction] = [:]
        if cids.contains(KnownControl.back) { table[KnownControl.back] = .system(.navigateBack) }
        if cids.contains(KnownControl.forward) { table[KnownControl.forward] = .system(.navigateForward) }
        if let gesture = [KnownControl.gestureButton, KnownControl.multiPlatformGesture].first(where: cids.contains) {
            table[gesture] = .system(.missionControl)
        }
        return ButtonMappings(table)
    }

    // MARK: Models

    /// Builds a published-dump entry. The key is the canonical ID (D5): the model's first
    /// Bluetooth PID, else its first wireless one, else its USB one. Later Bluetooth and wireless
    /// PIDs are firmware revisions, which resolve to the same key.
    private static func entry(
        _ name: String,
        bluetooth: [UInt16] = [],
        wireless: [UInt16] = [],
        usb: [UInt16] = [],
        controls: [UInt16],
        text: [UInt16: ControlText] = [:]
    ) -> DeviceModel {
        guard let canonical = bluetooth.first ?? wireless.first ?? usb.first else {
            preconditionFailure("catalog entry \(name) has no product ID")
        }
        return DeviceModel(
            key: ModelKey(productID: canonical),
            name: name,
            usbPIDs: usb,
            bluetoothPIDs: bluetooth,
            wirelessPIDs: wireless,
            controlOrder: controls,
            controlText: text,
            suggested: suggestedMappings(forControls: controls),
            verification: .publishedDump
        )
    }

    private static let back = KnownControl.back
    private static let forward = KnownControl.forward
    private static let wheel = KnownControl.middleClick
    private static let gesture = KnownControl.gestureButton
    private static let smartShift = KnownControl.smartShift
    private static let tiltLeft = KnownControl.tiltLeft
    private static let tiltRight = KnownControl.tiltRight

    /// Tested on hardware: the only entry that is.
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

    // MX Master family. The original has two revisions (4041/B012 and 4071/B01E) that share a key.
    static let mxMaster = entry("MX Master", bluetooth: [0xB012, 0xB01E], wireless: [0x4041, 0x4071], controls: [back, forward, gesture, smartShift, wheel])
    static let mxMaster2S = entry("MX Master 2S", bluetooth: [0xB019], wireless: [0x4069], controls: [back, forward, gesture, smartShift, wheel])
    static let mxMaster3 = entry("MX Master 3", bluetooth: [0xB023], wireless: [0x4082], controls: [back, forward, gesture, smartShift, wheel])
    static let mxMaster3ForBusiness = entry("MX Master 3 for Business", bluetooth: [0xB028], wireless: [0xB028], controls: [back, forward, gesture, smartShift, wheel])
    static let mxMaster3S = entry("MX Master 3S", bluetooth: [0xB034], wireless: [0xB034], controls: [back, forward, gesture, smartShift, wheel])
    static let mxMaster4 = entry("MX Master 4", bluetooth: [0xB042], controls: [back, forward, gesture, KnownControl.hapticSense, smartShift, wheel])

    // MX Anywhere family. The 2 reports one of three Bluetooth IDs and one of three wireless IDs.
    static let mxAnywhere2 = entry("MX Anywhere 2", bluetooth: [0xB013, 0xB018, 0xB01F], wireless: [0x404A, 0x4072, 0x4063], controls: [back, forward, wheel, tiltLeft, tiltRight])
    static let mxAnywhere2S = entry("MX Anywhere 2S", bluetooth: [0xB01A], wireless: [0x406A], controls: [back, forward, wheel, tiltLeft, tiltRight])
    static let mxAnywhere3 = entry("MX Anywhere 3", bluetooth: [0xB025], wireless: [0x4090], controls: [back, forward, smartShift, wheel])
    static let mxAnywhere3ForBusiness = entry("MX Anywhere 3 for Business", bluetooth: [0xB02D], wireless: [0xB02D], controls: [back, forward, smartShift, wheel])

    static let mxErgo = entry(
        "MX Ergo",
        bluetooth: [0xB01D], wireless: [0x406F],
        controls: [back, forward, KnownControl.dpiChange, wheel, tiltLeft, tiltRight],
        text: [
            KnownControl.dpiChange: ControlText(
                name: NSLocalizedString("Precision Button", comment: "Mouse control name"),
                detail: NSLocalizedString("Changes the pointer speed (DPI)", comment: "Mouse control description"),
                symbolName: "speedometer"
            ),
        ]
    )

    // Lift's DPI button sits behind the wheel, like the MX Vertical's.
    private static let topButtonText: [UInt16: ControlText] = [KnownControl.dpiSwitch: ControlDescriptor(cid: KnownControl.dpiSwitch).text]
    static let lift = entry("Lift", bluetooth: [0xB031], wireless: [0xB031], controls: [back, forward, KnownControl.dpiSwitch, wheel], text: topButtonText)
    static let liftForBusiness = entry("Lift for Business", bluetooth: [0xB033], wireless: [0xB033], controls: [back, forward, KnownControl.dpiSwitch, wheel], text: topButtonText)

    static let m720 = entry("M720 Triathlon", bluetooth: [0xB015], wireless: [0x405E], controls: [back, forward, KnownControl.multiPlatformGesture, wheel, tiltLeft, tiltRight])
    static let m585 = entry("M585 / M590", bluetooth: [0xB01B], wireless: [0x406B], controls: [back, forward, wheel, tiltLeft, tiltRight])
    static let m650L = entry("Signature M650 L", bluetooth: [0xB02A], wireless: [0xB02A], controls: [back, forward, wheel])
    // The M550's thumb buttons are plain mouse buttons: only the wheel click is programmable.
    static let m550 = entry("Signature M550", bluetooth: [0xB02B], wireless: [0xB02B], controls: [wheel])
    static let m575 = entry("ERGO M575", bluetooth: [0xB027], wireless: [0x4096], controls: [back, forward, wheel])
    static let m705 = entry("Marathon M705", wireless: [0x406D], controls: [back, forward, wheel, tiltLeft, tiltRight])
    static let pebbleM350 = entry("Pebble M350", bluetooth: [0xB021], wireless: [0x4080], controls: [wheel])
    static let m510v2 = entry("M510 (v2)", wireless: [0x4051], controls: [back, forward, wheel, tiltLeft, tiltRight])
    // Left and Right report as divertable on this family but are never diverted (`ControlCatalog.neverDivert`).
    static let m185 = entry("M185 / M235 / M310", wireless: [0x4055], controls: [wheel])
}

extension ControlDescriptor {
    var text: ControlText { ControlText(name: name, detail: detail, symbolName: symbolName) }
}
