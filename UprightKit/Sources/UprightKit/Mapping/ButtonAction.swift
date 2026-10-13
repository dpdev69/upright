import Foundation

/// NX_KEYTYPE_* values for media keys, posted as NSSystemDefined events.
public enum MediaKey: Int, Codable, Hashable, Sendable {
    case volumeUp = 0
    case volumeDown = 1
    case mute = 7
    case playPause = 16
    case nextTrack = 17
    case previousTrack = 18

    /// Volume keys repeat while held, like they do on a keyboard.
    public var repeatsWhileHeld: Bool { self == .volumeUp || self == .volumeDown }
}

/// Buttons as macOS numbers them in CGEvent's mouseEventButtonNumber field.
public enum SyntheticMouseButton: Int, Codable, Hashable, Sendable {
    case middle = 2
    case back = 3
    case forward = 4
}

/// Which view Mission Control opens. The value is the argument macOS's Mission Control binary accepts.
public enum MissionControlMode: String, Codable, Hashable, Sendable {
    case missionControl = ""
    case showDesktop = "1"
    case appExpose = "2"
}

/// An application to launch, identified by bundle ID. The name is only for display.
public struct AppReference: Codable, Hashable, Sendable {
    public var bundleID: String
    public var displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case bundleID, displayName }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)).flatMap { $0 } ?? bundleID
    }
}

/// Actions carried out by the mouse itself over HID++ rather than by posting events.
///
/// Encoded with Swift's synthesized enum format (`{"setDPI":{"_0":800}}`): keep case names and
/// payload labels unchanged.
public enum DeviceAction: Codable, Hashable, Sendable {
    /// Step to the next pointer-speed preset, like the top button does natively.
    case cycleDPI
    /// Switch to a specific sensor resolution. The device layer snaps to the nearest supported value.
    case setDPI(Int)
    /// Easy-Switch to channel 1, 2 or 3 (as printed on the mouse).
    case switchHost(Int)

    public static let dpiRange = 200...8000
    public static let hostRange = 1...3

    public var title: String {
        switch self {
        case .cycleDPI: return NSLocalizedString("Cycle Pointer Speed", comment: "Pointer speed action name")
        case .setDPI(let dpi): return String(format: NSLocalizedString("Pointer Speed %lld DPI", comment: "Action name; %lld is the sensor resolution in DPI"), Int64(dpi))
        case .switchHost(let host): return String(format: NSLocalizedString("Switch to Computer %lld", comment: "Action name; %lld is the Easy-Switch channel number"), Int64(host))
        }
    }

    /// A sentence describing the action, for tooltips.
    public var helpText: String {
        switch self {
        case .cycleDPI: return NSLocalizedString("Steps through the pointer-speed presets", comment: "Pointer speed action tooltip")
        case .setDPI(let dpi): return String(format: NSLocalizedString("Sets the pointer speed to %lld DPI (or the nearest speed the mouse supports)", comment: "Action tooltip; %lld is the sensor resolution in DPI"), Int64(dpi))
        case .switchHost(let host): return String(format: NSLocalizedString("Moves the mouse to Easy-Switch channel %lld; it disconnects from this Mac", comment: "Action tooltip; %lld is the Easy-Switch channel number"), Int64(host))
        }
    }

    public var symbolName: String {
        switch self {
        case .cycleDPI, .setDPI: return "speedometer"
        case .switchHost: return "laptopcomputer.and.arrow.down"
        }
    }

    public var isValid: Bool {
        switch self {
        case .cycleDPI: return true
        case .setDPI(let dpi): return Self.dpiRange.contains(dpi)
        case .switchHost(let host): return Self.hostRange.contains(host)
        }
    }
}

/// How an action is carried out.
public enum ActionEffect: Hashable, Sendable {
    case keyCombo(KeyCombo)
    case media(MediaKey)
    case mouseButton(SyntheticMouseButton)
    case missionControl(MissionControlMode)
    case launchApp(AppReference)
    case openURL(URL)
    case runShortcut(String)
    /// Handled by the mouse, not by the action performer; `RemapEngine` routes it to `onDeviceAction`.
    case device(DeviceAction)

    /// Posting synthetic keyboard and mouse events requires Accessibility access.
    public var requiresAccessibility: Bool {
        switch self {
        case .keyCombo, .media, .mouseButton: return true
        case .missionControl, .launchApp, .openURL, .runShortcut, .device: return false
        }
    }

    /// Keys, clicks and repeating media keys follow the physical button (down on press,
    /// up on release); everything else fires once per press.
    public var tracksButtonState: Bool {
        switch self {
        case .keyCombo, .mouseButton: return true
        case .media(let key): return key.repeatsWhileHeld
        case .missionControl, .launchApp, .openURL, .runShortcut, .device: return false
        }
    }
}

/// Curated built-in actions.
public enum SystemAction: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case navigateBack
    case navigateForward
    case previousTab
    case nextTab
    case missionControl
    case appExpose
    case showDesktop
    case spaceLeft
    case spaceRight
    case spotlight
    case screenshot
    case lockScreen
    case middleClick
    case mouseBack
    case mouseForward
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
    case copy
    case paste
    case undo
    case redo

    public var id: String { rawValue }

    public enum Category: String, CaseIterable, Sendable {
        case navigation = "Navigation"
        case windows = "Windows & Spaces"
        case system = "System"
        case mouse = "Mouse"
        case media = "Media"
        case editing = "Editing"

        /// The localized name; `rawValue` stays a stable identifier.
        public var title: String {
            switch self {
            case .navigation: return NSLocalizedString("Navigation", comment: "Action category")
            case .windows: return NSLocalizedString("Windows & Spaces", comment: "Action category")
            case .system: return NSLocalizedString("System", comment: "Action category")
            case .mouse: return NSLocalizedString("Mouse Buttons", comment: "Action category")
            case .media: return NSLocalizedString("Media", comment: "Action category")
            case .editing: return NSLocalizedString("Editing", comment: "Action category")
            }
        }
    }

    public var category: Category {
        switch self {
        case .navigateBack, .navigateForward, .previousTab, .nextTab: return .navigation
        case .missionControl, .appExpose, .showDesktop, .spaceLeft, .spaceRight: return .windows
        case .spotlight, .screenshot, .lockScreen: return .system
        case .middleClick, .mouseBack, .mouseForward: return .mouse
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute: return .media
        case .copy, .paste, .undo, .redo: return .editing
        }
    }

    public var title: String {
        switch self {
        case .navigateBack: return NSLocalizedString("Back", comment: "Built-in action name")
        case .navigateForward: return NSLocalizedString("Forward", comment: "Built-in action name")
        case .previousTab: return NSLocalizedString("Previous Tab", comment: "Built-in action name")
        case .nextTab: return NSLocalizedString("Next Tab", comment: "Built-in action name")
        case .missionControl: return NSLocalizedString("Mission Control", comment: "Built-in action name")
        case .appExpose: return NSLocalizedString("App Exposé", comment: "Built-in action name")
        case .showDesktop: return NSLocalizedString("Show Desktop", comment: "Built-in action name")
        case .spaceLeft: return NSLocalizedString("Space Left", comment: "Built-in action name")
        case .spaceRight: return NSLocalizedString("Space Right", comment: "Built-in action name")
        case .spotlight: return NSLocalizedString("Spotlight", comment: "Built-in action name")
        case .screenshot: return NSLocalizedString("Screenshot Selection", comment: "Built-in action name")
        case .lockScreen: return NSLocalizedString("Lock Screen", comment: "Built-in action name")
        case .middleClick: return NSLocalizedString("Middle Click", comment: "Built-in action name")
        case .mouseBack: return NSLocalizedString("Mouse Button 4 (Back)", comment: "Built-in action name")
        case .mouseForward: return NSLocalizedString("Mouse Button 5 (Forward)", comment: "Built-in action name")
        case .playPause: return NSLocalizedString("Play / Pause", comment: "Built-in action name")
        case .nextTrack: return NSLocalizedString("Next Track", comment: "Built-in action name")
        case .previousTrack: return NSLocalizedString("Previous Track", comment: "Built-in action name")
        case .volumeUp: return NSLocalizedString("Volume Up", comment: "Built-in action name")
        case .volumeDown: return NSLocalizedString("Volume Down", comment: "Built-in action name")
        case .mute: return NSLocalizedString("Mute", comment: "Built-in action name")
        case .copy: return NSLocalizedString("Copy", comment: "Built-in action name")
        case .paste: return NSLocalizedString("Paste", comment: "Built-in action name")
        case .undo: return NSLocalizedString("Undo", comment: "Built-in action name")
        case .redo: return NSLocalizedString("Redo", comment: "Built-in action name")
        }
    }

    public var symbolName: String {
        switch self {
        case .navigateBack: return "arrow.backward"
        case .navigateForward: return "arrow.forward"
        case .previousTab: return "arrow.left.to.line"
        case .nextTab: return "arrow.right.to.line"
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "rectangle.stack"
        case .showDesktop: return "menubar.dock.rectangle"
        case .spaceLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .spaceRight: return "rectangle.righthalf.inset.filled.arrow.right"
        case .spotlight: return "magnifyingglass"
        case .screenshot: return "camera.viewfinder"
        case .lockScreen: return "lock"
        case .middleClick: return "computermouse"
        case .mouseBack: return "arrow.uturn.backward"
        case .mouseForward: return "arrow.uturn.forward"
        case .playPause: return "playpause"
        case .nextTrack: return "forward"
        case .previousTrack: return "backward"
        case .volumeUp: return "speaker.wave.3"
        case .volumeDown: return "speaker.wave.1"
        case .mute: return "speaker.slash"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .undo: return "arrow.uturn.backward.circle"
        case .redo: return "arrow.uturn.forward.circle"
        }
    }

    public var effect: ActionEffect {
        switch self {
        case .navigateBack: return .keyCombo(KeyCombo(keyCode: KeyCode.leftBracket, modifiers: .command))
        case .navigateForward: return .keyCombo(KeyCombo(keyCode: KeyCode.rightBracket, modifiers: .command))
        case .previousTab: return .keyCombo(KeyCombo(keyCode: KeyCode.tab, modifiers: [.control, .shift]))
        case .nextTab: return .keyCombo(KeyCombo(keyCode: KeyCode.tab, modifiers: .control))
        case .missionControl: return .missionControl(.missionControl)
        case .appExpose: return .missionControl(.appExpose)
        case .showDesktop: return .missionControl(.showDesktop)
        case .spaceLeft: return .keyCombo(KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control))
        case .spaceRight: return .keyCombo(KeyCombo(keyCode: KeyCode.rightArrow, modifiers: .control))
        case .spotlight: return .keyCombo(KeyCombo(keyCode: KeyCode.space, modifiers: .command))
        case .screenshot: return .keyCombo(KeyCombo(keyCode: KeyCode.four, modifiers: [.command, .shift]))
        case .lockScreen: return .keyCombo(KeyCombo(keyCode: KeyCode.q, modifiers: [.control, .command]))
        case .middleClick: return .mouseButton(.middle)
        case .mouseBack: return .mouseButton(.back)
        case .mouseForward: return .mouseButton(.forward)
        case .playPause: return .media(.playPause)
        case .nextTrack: return .media(.nextTrack)
        case .previousTrack: return .media(.previousTrack)
        case .volumeUp: return .media(.volumeUp)
        case .volumeDown: return .media(.volumeDown)
        case .mute: return .media(.mute)
        case .copy: return .keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: .command))
        case .paste: return .keyCombo(KeyCombo(keyCode: KeyCode.v, modifiers: .command))
        case .undo: return .keyCombo(KeyCombo(keyCode: KeyCode.z, modifiers: .command))
        case .redo: return .keyCombo(KeyCombo(keyCode: KeyCode.z, modifiers: [.command, .shift]))
        }
    }

    public static func actions(in category: Category) -> [SystemAction] {
        allCases.filter { $0.category == category }
    }
}

/// What a mouse button does.
///
/// Encoded with Swift's synthesized enum format (`{"system":{"_0":"navigateBack"}}`), which v1
/// mappings already use: keep case names and payload labels unchanged, and add new kinds as new cases.
public enum ButtonAction: Codable, Hashable, Sendable {
    /// Leave the button alone; the mouse handles it natively.
    case deviceDefault
    /// Divert the button and ignore it.
    case disabled
    case system(SystemAction)
    case keyCombo(KeyCombo)
    case launchApp(AppReference)
    case openURL(URL)
    /// Runs a Shortcuts.app shortcut by name.
    case runShortcut(String)
    case device(DeviceAction)
    /// Hold the button and move the mouse to pick one of four actions, or click it for a fifth.
    /// The slots hold plain actions only: nested gestures are invalid.
    indirect case gestures(GestureSet)

    /// The broad kind of action, for pickers that choose a kind before its details.
    public enum Kind: String, CaseIterable, Sendable {
        case deviceDefault, disabled, system, keyCombo, launchApp, openURL, runShortcut, device, gestures
    }

    public var kind: Kind {
        switch self {
        case .deviceDefault: return .deviceDefault
        case .disabled: return .disabled
        case .system: return .system
        case .keyCombo: return .keyCombo
        case .launchApp: return .launchApp
        case .openURL: return .openURL
        case .runShortcut: return .runShortcut
        case .device: return .device
        case .gestures: return .gestures
        }
    }

    public var effect: ActionEffect? {
        switch self {
        case .deviceDefault, .disabled, .gestures: return nil
        case .system(let action): return action.effect
        case .keyCombo(let combo): return .keyCombo(combo)
        case .launchApp(let app): return .launchApp(app)
        case .openURL(let url): return .openURL(url)
        case .runShortcut(let name): return .runShortcut(name)
        case .device(let action): return .device(action)
        }
    }

    public var requiresDiversion: Bool { self != .deviceDefault }

    public var requiresAccessibility: Bool {
        if case .gestures(let set) = self { return set.requiresAccessibility }
        return effect?.requiresAccessibility ?? false
    }

    /// Gestures need the mouse's movement while the button is held (raw XY diversion).
    public var isGestures: Bool {
        if case .gestures = self { return true }
        return false
    }

    /// False for actions whose details can't be carried out (empty names, URLs without a scheme,
    /// out-of-range DPI). Invalid actions are dropped when mappings are imported.
    public var isValid: Bool {
        switch self {
        case .deviceDefault, .disabled, .system, .keyCombo: return true
        case .launchApp(let app): return !app.bundleID.trimmingCharacters(in: .whitespaces).isEmpty
        case .openURL(let url): return url.scheme?.isEmpty == false
        case .runShortcut(let name): return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .device(let action): return action.isValid
        case .gestures(let set): return set.isValid
        }
    }

    public var title: String {
        switch self {
        case .deviceDefault: return NSLocalizedString("Default", comment: "Button action name")
        case .disabled: return NSLocalizedString("Do Nothing", comment: "Button action name")
        case .system(let action): return action.title
        case .keyCombo(let combo): return combo.displayString
        case .launchApp(let app): return String(format: NSLocalizedString("Open %@", comment: "Button action name; %@ is an app name"), app.displayName)
        case .openURL(let url): return String(format: NSLocalizedString("Open %@", comment: "Button action name; %@ is an app name"), url.host ?? url.absoluteString)
        case .runShortcut(let name): return String(format: NSLocalizedString("Run “%@”", comment: "Button action name; %@ is a Shortcuts.app shortcut name"), name)
        case .device(let action): return action.title
        case .gestures: return NSLocalizedString("Gestures", comment: "Button action name")
        }
    }

    /// A sentence describing what the button will do, for tooltips.
    public var helpText: String {
        switch self {
        case .deviceDefault: return NSLocalizedString("The mouse handles this button itself", comment: "Button action tooltip")
        case .disabled: return NSLocalizedString("The button is ignored", comment: "Button action tooltip")
        case .system(let action): return action.title
        case .keyCombo(let combo): return String(format: NSLocalizedString("Sends %@", comment: "Button action tooltip; %@ is a key combination such as ⌘C"), combo.displayString)
        case .launchApp(let app): return String(format: NSLocalizedString("Opens %@ (%@)", comment: "Button action tooltip; app name and bundle identifier"), app.displayName, app.bundleID)
        case .openURL(let url): return String(format: NSLocalizedString("Opens %@", comment: "Button action tooltip; %@ is a URL"), url.absoluteString)
        case .runShortcut(let name): return String(format: NSLocalizedString("Runs the shortcut “%@”", comment: "Button action tooltip; %@ is a shortcut name"), name)
        case .device(let action): return action.helpText
        case .gestures(let set): return set.summary
        }
    }

    public var symbolName: String {
        switch self {
        case .deviceDefault: return "computermouse"
        case .disabled: return "nosign"
        case .system(let action): return action.symbolName
        case .keyCombo: return "keyboard"
        case .launchApp: return "app"
        case .openURL: return "link"
        case .runShortcut: return "square.2.layers.3d"
        case .device(let action): return action.symbolName
        case .gestures: return "hand.draw"
        }
    }
}

extension ButtonAction {
    /// Link schemes Open URL accepts, from the editor and from imported files. Other schemes can
    /// run local files (`file:`) or hand data to arbitrary apps, which a shared file shouldn't bind.
    public static let allowedURLSchemes: Set<String> = ["http", "https", "mailto"]

    public static func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedURLSchemes.contains(scheme)
    }

    /// True for actions that open something outside Upright: an app, a link or a shortcut.
    public var opensExternally: Bool {
        switch self {
        case .launchApp, .openURL, .runShortcut: return true
        default: return false
        }
    }
}
