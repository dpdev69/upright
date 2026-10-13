import Foundation

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Symbols in the order macOS menus show them: ⌃⌥⇧⌘.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A keyboard shortcut: a virtual key code (Carbon kVK_* value) plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// What the key showed when it was recorded, so the shortcut reads naturally on any layout.
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: KeyModifiers = [], keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel ?? KeyCode.label(for: keyCode) ?? "Key \(keyCode)"
    }

    public var displayString: String { modifiers.symbols + keyLabel }

    /// Arrow and navigation keys carry the function/numeric-pad flags on real keyboards;
    /// some system shortcuts (like switching Spaces) only fire when they're present.
    public var isNavigationKey: Bool { KeyCode.navigationKeys.contains(keyCode) }
}

/// Carbon virtual key codes (kVK_*) Upright refers to by name.
public enum KeyCode {
    public static let a: UInt16 = 0x00
    public static let z: UInt16 = 0x06
    public static let c: UInt16 = 0x08
    public static let v: UInt16 = 0x09
    public static let q: UInt16 = 0x0C
    public static let w: UInt16 = 0x0D
    public static let t: UInt16 = 0x11
    public static let three: UInt16 = 0x14
    public static let four: UInt16 = 0x15
    public static let five: UInt16 = 0x17
    public static let rightBracket: UInt16 = 0x1E
    public static let leftBracket: UInt16 = 0x21
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let forwardDelete: UInt16 = 0x75
    public static let home: UInt16 = 0x73
    public static let end: UInt16 = 0x77
    public static let pageUp: UInt16 = 0x74
    public static let pageDown: UInt16 = 0x79
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E

    static let navigationKeys: Set<UInt16> = [home, end, pageUp, pageDown, leftArrow, rightArrow, downArrow, upArrow, forwardDelete]

    static let functionKeys: [UInt16: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19",
    ]

    static let ansiLetters: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x21: "[", 0x1E: "]", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x2A: "\\",
        0x1B: "-", 0x18: "=", 0x32: "`",
    ]

    /// Label for keys whose glyph doesn't depend on the keyboard layout (plus US-ANSI fallbacks).
    public static func label(for keyCode: UInt16) -> String? {
        switch keyCode {
        case returnKey: return "↩"
        case tab: return "⇥"
        case space: return "Space"
        case delete: return "⌫"
        case escape: return "⎋"
        case forwardDelete: return "⌦"
        case home: return "↖"
        case end: return "↘"
        case pageUp: return "⇞"
        case pageDown: return "⇟"
        case leftArrow: return "←"
        case rightArrow: return "→"
        case downArrow: return "↓"
        case upArrow: return "↑"
        default: return functionKeys[keyCode] ?? ansiLetters[keyCode]
        }
    }

    /// Keys that never carry a label from the layout (so the recorder must use `label(for:)`).
    public static func isLayoutIndependent(_ keyCode: UInt16) -> Bool {
        functionKeys[keyCode] != nil || [returnKey, tab, space, delete, escape].contains(keyCode) || navigationKeys.contains(keyCode)
    }
}
