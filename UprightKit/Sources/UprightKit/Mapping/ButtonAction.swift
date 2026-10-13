import Foundation

/// NX_KEYTYPE_* values for media keys, posted as NSSystemDefined events.
public enum MediaKey: Int, Codable, Hashable, Sendable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case playPause = 16
    case nextTrack = 17
    case previousTrack = 18
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

/// How a system action is carried out.
public enum ActionEffect: Hashable, Sendable {
    case keyCombo(KeyCombo)
    case media(MediaKey)
    case mouseButton(SyntheticMouseButton)
    case missionControl(MissionControlMode)

    /// Posting synthetic keyboard and mouse events requires Accessibility access.
    public var requiresAccessibility: Bool {
        if case .missionControl = self { return false }
        return true
    }

    /// Keys and clicks follow the physical button (down on press, up on release);
    /// everything else fires once per press.
    public var tracksButtonState: Bool {
        switch self {
        case .keyCombo, .mouseButton: return true
        case .media, .missionControl: return false
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
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .previousTab: return "Previous Tab"
        case .nextTab: return "Next Tab"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .spaceLeft: return "Space Left"
        case .spaceRight: return "Space Right"
        case .spotlight: return "Spotlight"
        case .screenshot: return "Screenshot Selection"
        case .lockScreen: return "Lock Screen"
        case .middleClick: return "Middle Click"
        case .mouseBack: return "Mouse Button 4 (Back)"
        case .mouseForward: return "Mouse Button 5 (Forward)"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .undo: return "Undo"
        case .redo: return "Redo"
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
public enum ButtonAction: Codable, Hashable, Sendable {
    /// Leave the button alone; the mouse handles it natively.
    case deviceDefault
    /// Divert the button and ignore it.
    case disabled
    case system(SystemAction)
    case keyCombo(KeyCombo)

    public var effect: ActionEffect? {
        switch self {
        case .deviceDefault, .disabled: return nil
        case .system(let action): return action.effect
        case .keyCombo(let combo): return .keyCombo(combo)
        }
    }

    public var requiresDiversion: Bool { self != .deviceDefault }
    public var requiresAccessibility: Bool { effect?.requiresAccessibility ?? false }

    public var title: String {
        switch self {
        case .deviceDefault: return "Default"
        case .disabled: return "Do Nothing"
        case .system(let action): return action.title
        case .keyCombo(let combo): return combo.displayString
        }
    }

    public var symbolName: String {
        switch self {
        case .deviceDefault: return "computermouse"
        case .disabled: return "nosign"
        case .system(let action): return action.symbolName
        case .keyCombo: return "keyboard"
        }
    }
}
