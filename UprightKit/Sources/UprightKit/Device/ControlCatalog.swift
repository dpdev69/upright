import Foundation

// Wave 0 scaffold: final signatures. W1.1 owns this file and completes the name table.

/// Control IDs (CIDs) used by REPROG_CONTROLS_V4, as listed in Solaar's special_keys table
/// and LogiOps' MX Vertical example configuration.
public enum KnownControl {
    public static let leftClick: UInt16 = 0x0050
    public static let rightClick: UInt16 = 0x0051
    public static let middleClick: UInt16 = 0x0052
    public static let back: UInt16 = 0x0053
    public static let forward: UInt16 = 0x0056
    public static let tiltLeft: UInt16 = 0x005B
    public static let tiltRight: UInt16 = 0x005D
    public static let gestureButton: UInt16 = 0x00C3
    public static let smartShift: UInt16 = 0x00C4
    public static let multiPlatformGesture: UInt16 = 0x00D0
    public static let virtualGesture: UInt16 = 0x00D7
    public static let dpiChange: UInt16 = 0x00ED
    public static let dpiSwitch: UInt16 = 0x00FD
    public static let hapticSense: UInt16 = 0x01A0

    public static let primaryClicks: Set<UInt16> = [leftClick, rightClick]
}

/// User-facing wording for a control.
public struct ControlText: Hashable, Sendable {
    public var name: String
    public var detail: String
    public var symbolName: String

    public init(name: String, detail: String, symbolName: String) {
        self.name = name
        self.detail = detail
        self.symbolName = symbolName
    }
}

/// Names and rules for controls across models.
public enum ControlCatalog {
    /// Wording for a control: the model's own override, then the generic name of the CID,
    /// then "Button 0x%04X".
    public static func text(for cid: UInt16, model: ModelKey?) -> ControlText {
        if let model, let text = DeviceCatalog.model(model)?.controlText[cid] {
            return text
        }
        if let text = genericText[cid] {
            return text
        }
        return ControlText(
            name: String(format: NSLocalizedString("Button 0x%04X", comment: "Mouse control name; %04X is its hexadecimal ID"), Int(cid)),
            detail: NSLocalizedString("Additional programmable control", comment: "Mouse control description"),
            symbolName: "button.programmable"
        )
    }

    /// Never diverted, whatever a device's flags say: losing the primary clicks locks the user out.
    public static let neverDivert: Set<UInt16> = [KnownControl.leftClick, KnownControl.rightClick]

    /// Model-independent names, from Solaar's special_keys table. W1.1 completes this table.
    static let genericText: [UInt16: ControlText] = [
        KnownControl.middleClick: ControlText(
            name: NSLocalizedString("Wheel Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Press the scroll wheel", comment: "Mouse control description"),
            symbolName: "smallcircle.filled.circle"
        ),
        KnownControl.back: ControlText(
            name: NSLocalizedString("Back Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb button", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        KnownControl.forward: ControlText(
            name: NSLocalizedString("Forward Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb button", comment: "Mouse control description"),
            symbolName: "chevron.forward.circle"
        ),
    ]
}

/// User-facing description of a control.
public struct ControlDescriptor: Hashable, Sendable, Identifiable {
    public var cid: UInt16
    public var name: String
    public var detail: String
    public var symbolName: String

    public var id: UInt16 { cid }

    /// The MX Vertical wording (what Upright has always shown).
    public init(cid: UInt16) {
        self.cid = cid
        switch cid {
        case KnownControl.back:
            name = NSLocalizedString("Back Button", comment: "Mouse control name")
            detail = NSLocalizedString("Lower thumb button", comment: "Mouse control description")
            symbolName = "chevron.backward.circle"
        case KnownControl.forward:
            name = NSLocalizedString("Forward Button", comment: "Mouse control name")
            detail = NSLocalizedString("Upper thumb button", comment: "Mouse control description")
            symbolName = "chevron.forward.circle"
        case KnownControl.dpiSwitch, KnownControl.dpiChange:
            name = NSLocalizedString("Top Button", comment: "Mouse control name")
            detail = NSLocalizedString("Pointer-speed (DPI) button behind the wheel", comment: "Mouse control description")
            symbolName = "speedometer"
        case KnownControl.middleClick:
            name = NSLocalizedString("Wheel Click", comment: "Mouse control name")
            detail = NSLocalizedString("Press the scroll wheel", comment: "Mouse control description")
            symbolName = "smallcircle.filled.circle"
        default:
            name = String(format: NSLocalizedString("Control 0x%04X", comment: "Mouse control name; %04X is its hexadecimal ID"), cid)
            detail = NSLocalizedString("Additional programmable control", comment: "Mouse control description")
            symbolName = "button.programmable"
        }
    }

    public var hexID: String { String(format: "0x%04X", cid) }
}

extension ControlDescriptor {
    /// Wording for `cid` on `model`, from `ControlCatalog.text(for:model:)`.
    public init(cid: UInt16, model: ModelKey? = nil) {
        let text = ControlCatalog.text(for: cid, model: model)
        self.cid = cid
        name = text.name
        detail = text.detail
        symbolName = text.symbolName
    }
}
