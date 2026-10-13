import Foundation

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

    /// The CIDs that have a model-independent name: every entry of Solaar's CONTROL table
    /// that a Logitech mouse is known to report (33), in ascending order.
    public static var namedControls: [UInt16] { solaarNames.keys.sorted() }

    /// Solaar's name for a control (its `special_keys.CONTROL` table), for logs, probe output and
    /// device reports. Not localized; nil for a CID Solaar doesn't list.
    public static func solaarName(for cid: UInt16) -> String? { solaarNames[cid] }

    static let solaarNames: [UInt16: String] = [
        0x0050: "Left Button",
        0x0051: "Right Button",
        0x0052: "Middle Button",
        0x0053: "Back Button",
        0x0054: "Back",
        0x0055: "Back As Alt Win Arrow",
        0x0056: "Forward Button",
        0x0057: "Forward As HID",
        0x0058: "Forward As Alt Win Arrow",
        0x0059: "Button 6",
        0x005A: "Left Scroll As Button 7",
        0x005B: "Left Tilt",
        0x005C: "Right Scroll As Button 8",
        0x005D: "Right Tilt",
        0x005E: "Button 9",
        0x005F: "Button 10",
        0x0097: "Analog HScroll",
        0x00AC: "Back Hscroll",
        0x00B7: "Fn Left Click",
        0x00B8: "Second Left Click",
        0x00B9: "Fn Second Left Click",
        0x00C3: "Mouse Gesture Button",
        0x00C4: "Smart Shift",
        0x00CE: "MultiPlatform Back",
        0x00CF: "MultiPlatform Forward",
        0x00D0: "MultiPlatform Gesture Button",
        0x00D7: "Virtual Gesture Button",
        0x00D8: "Cursor Button Long Press",
        0x00ED: "DPI Change",
        0x00FD: "DPI Switch",
        0x0102: "LeftAndRightClick",
        0x01A0: "Haptic",
        0x01B4: "AI",
    ]

    /// Model-independent wording for the 33 CIDs in `solaarNames`. Models that describe a
    /// control differently (the MX Vertical's "Top Button") override it in `DeviceModel.controlText`.
    static let genericText: [UInt16: ControlText] = [
        0x0050: ControlText(
            name: NSLocalizedString("Left Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Primary click", comment: "Mouse control description"),
            symbolName: "cursorarrow.click"
        ),
        0x0051: ControlText(
            name: NSLocalizedString("Right Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Secondary click", comment: "Mouse control description"),
            symbolName: "contextualmenu.and.cursorarrow"
        ),
        0x0052: ControlText(
            name: NSLocalizedString("Wheel Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Press the scroll wheel", comment: "Mouse control description"),
            symbolName: "smallcircle.filled.circle"
        ),
        0x0053: ControlText(
            name: NSLocalizedString("Back Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb button", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        0x0054: ControlText(
            name: NSLocalizedString("Back (Alternate)", comment: "Mouse control name"),
            detail: NSLocalizedString("Alternate back button", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        0x0055: ControlText(
            name: NSLocalizedString("Back (Arrow Key)", comment: "Mouse control name"),
            detail: NSLocalizedString("Back, sent as an Alt or Windows arrow key", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        0x0056: ControlText(
            name: NSLocalizedString("Forward Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb button", comment: "Mouse control description"),
            symbolName: "chevron.forward.circle"
        ),
        0x0057: ControlText(
            name: NSLocalizedString("Forward (HID)", comment: "Mouse control name"),
            detail: NSLocalizedString("Forward, sent as a standard mouse button", comment: "Mouse control description"),
            symbolName: "chevron.forward.circle"
        ),
        0x0058: ControlText(
            name: NSLocalizedString("Forward (Arrow Key)", comment: "Mouse control name"),
            detail: NSLocalizedString("Forward, sent as an Alt or Windows arrow key", comment: "Mouse control description"),
            symbolName: "chevron.forward.circle"
        ),
        0x0059: ControlText(
            name: NSLocalizedString("Button 6", comment: "Mouse control name"),
            detail: NSLocalizedString("Additional programmable control", comment: "Mouse control description"),
            symbolName: "button.programmable"
        ),
        0x005A: ControlText(
            name: NSLocalizedString("Scroll Left (Button 7)", comment: "Mouse control name"),
            detail: NSLocalizedString("Horizontal scroll to the left, reported as a button", comment: "Mouse control description"),
            symbolName: "arrow.left.circle"
        ),
        0x005B: ControlText(
            name: NSLocalizedString("Tilt Left", comment: "Mouse control name"),
            detail: NSLocalizedString("Tilt the scroll wheel to the left", comment: "Mouse control description"),
            symbolName: "arrow.left.circle"
        ),
        0x005C: ControlText(
            name: NSLocalizedString("Scroll Right (Button 8)", comment: "Mouse control name"),
            detail: NSLocalizedString("Horizontal scroll to the right, reported as a button", comment: "Mouse control description"),
            symbolName: "arrow.right.circle"
        ),
        0x005D: ControlText(
            name: NSLocalizedString("Tilt Right", comment: "Mouse control name"),
            detail: NSLocalizedString("Tilt the scroll wheel to the right", comment: "Mouse control description"),
            symbolName: "arrow.right.circle"
        ),
        0x005E: ControlText(
            name: NSLocalizedString("Button 9", comment: "Mouse control name"),
            detail: NSLocalizedString("Additional programmable control", comment: "Mouse control description"),
            symbolName: "button.programmable"
        ),
        0x005F: ControlText(
            name: NSLocalizedString("Button 10", comment: "Mouse control name"),
            detail: NSLocalizedString("Additional programmable control", comment: "Mouse control description"),
            symbolName: "button.programmable"
        ),
        0x0097: ControlText(
            name: NSLocalizedString("Analog Horizontal Scroll", comment: "Mouse control name"),
            detail: NSLocalizedString("Horizontal scroll wheel", comment: "Mouse control description"),
            symbolName: "arrow.left.and.right.circle"
        ),
        0x00AC: ControlText(
            name: NSLocalizedString("Back (Horizontal Scroll)", comment: "Mouse control name"),
            detail: NSLocalizedString("Back, sent as a horizontal scroll", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        0x00B7: ControlText(
            name: NSLocalizedString("Fn + Left Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Left click while the Fn key is held", comment: "Mouse control description"),
            symbolName: "cursorarrow.click"
        ),
        0x00B8: ControlText(
            name: NSLocalizedString("Second Left Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Additional left-click button", comment: "Mouse control description"),
            symbolName: "cursorarrow.click.2"
        ),
        0x00B9: ControlText(
            name: NSLocalizedString("Fn + Second Left Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Second left click while the Fn key is held", comment: "Mouse control description"),
            symbolName: "cursorarrow.click.2"
        ),
        0x00C3: ControlText(
            name: NSLocalizedString("Gesture Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb gesture button", comment: "Mouse control description"),
            symbolName: "hand.point.up.left"
        ),
        0x00C4: ControlText(
            name: NSLocalizedString("SmartShift Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Switches the scroll wheel mode", comment: "Mouse control description"),
            symbolName: "slider.horizontal.3"
        ),
        0x00CE: ControlText(
            name: NSLocalizedString("Multi-Platform Back", comment: "Mouse control name"),
            detail: NSLocalizedString("Back button of a multi-platform mouse", comment: "Mouse control description"),
            symbolName: "chevron.backward.circle"
        ),
        0x00CF: ControlText(
            name: NSLocalizedString("Multi-Platform Forward", comment: "Mouse control name"),
            detail: NSLocalizedString("Forward button of a multi-platform mouse", comment: "Mouse control description"),
            symbolName: "chevron.forward.circle"
        ),
        0x00D0: ControlText(
            name: NSLocalizedString("Multi-Platform Gesture Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Thumb gesture button", comment: "Mouse control description"),
            symbolName: "hand.point.up.left"
        ),
        0x00D7: ControlText(
            name: NSLocalizedString("Virtual Gesture Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Software gesture button", comment: "Mouse control description"),
            symbolName: "hand.point.up.left"
        ),
        0x00D8: ControlText(
            name: NSLocalizedString("Cursor Button (Long Press)", comment: "Mouse control name"),
            detail: NSLocalizedString("Long press of the cursor button", comment: "Mouse control description"),
            symbolName: "cursorarrow"
        ),
        0x00ED: ControlText(
            name: NSLocalizedString("DPI Change Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Changes the pointer speed (DPI)", comment: "Mouse control description"),
            symbolName: "speedometer"
        ),
        0x00FD: ControlText(
            name: NSLocalizedString("DPI Switch Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Cycles through pointer speeds (DPI)", comment: "Mouse control description"),
            symbolName: "speedometer"
        ),
        0x0102: ControlText(
            name: NSLocalizedString("Left + Right Click", comment: "Mouse control name"),
            detail: NSLocalizedString("Left and right buttons pressed together", comment: "Mouse control description"),
            symbolName: "cursorarrow.click.2"
        ),
        0x01A0: ControlText(
            name: NSLocalizedString("Haptic Sense Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Haptic thumb panel", comment: "Mouse control description"),
            symbolName: "waveform"
        ),
        0x01B4: ControlText(
            name: NSLocalizedString("AI Button", comment: "Mouse control name"),
            detail: NSLocalizedString("Dedicated AI button", comment: "Mouse control description"),
            symbolName: "sparkles"
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
