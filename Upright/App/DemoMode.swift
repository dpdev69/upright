import AppKit
import Foundation

/// Launch options for Demo Mode. `--demo` runs the real UI driven by simulated mice, isolated
/// from IOKit, event taps, permission prompts and the user's settings. `--export-snapshots <dir>`
/// (which implies `--demo`) renders the UI offscreen, writes PNGs and `manifest.json` to `<dir>`,
/// then quits. See docs/dev/DEMO-MODE-SPEC.md.
///
/// This file also holds the demo scenario both modes show: the fleet (`DemoMode.Fleet`) and the
/// setup a typical user would have made (`DemoMode.Scenario`), so screenshots and a hands-on demo
/// look like a Mac that has been using Upright for a while. Everything is made up: fake serials
/// (`DEMO-00NN`), standard Apple apps only, nothing read from the user's Mac.
enum DemoMode {
    nonisolated(unsafe) private(set) static var isActive = false
    nonisolated(unsafe) private(set) static var exportDirectory: URL?

    /// Demo Mode's own defaults domain, wiped at start; the user's is never touched.
    static let defaultsSuiteName = "io.github.upright.Upright.demo"

    static var isExporting: Bool { exportDirectory != nil }

    /// Export only: the app profile (bundle ID) a newly shown Buttons pane starts on; nil starts
    /// on All Apps. `ButtonsPane` seeds its profile selection from it.
    nonisolated(unsafe) static var snapshotProfileBundleID: String?

    /// Call first thing at launch with `CommandLine.arguments`.
    ///
    /// - `--demo`: Demo Mode.
    /// - `--export-snapshots <dir>` or `--export-snapshots=<dir>`: export into `<dir>` (relative
    ///   paths resolve against the current directory), then quit. Implies `--demo`.
    static func configure(arguments: [String]) {
        exportDirectory = nil
        var arguments = arguments
        if !arguments.isEmpty { arguments.removeFirst() } // the executable
        for (index, argument) in arguments.enumerated() {
            if argument == "--export-snapshots", arguments.indices.contains(index + 1) {
                exportDirectory = directoryURL(arguments[index + 1])
            } else if argument.hasPrefix("--export-snapshots=") {
                let path = String(argument.dropFirst("--export-snapshots=".count))
                if !path.isEmpty { exportDirectory = directoryURL(path) }
            }
        }
        isActive = arguments.contains("--demo") || exportDirectory != nil
    }

    private static func directoryURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: base).standardizedFileURL
    }
}

// MARK: - Fleet

extension DemoMode {
    /// The simulated mice: an MX Vertical on a Unifying receiver, an MX Master 3S on a Bolt
    /// receiver and a Lift over Bluetooth, one per connection kind. Never touches IOKit.
    @MainActor
    final class Fleet {
        let source: SimulatedLinkSource
        let unifying: SimulatedReceiver
        let bolt: SimulatedReceiver
        let bluetooth: SimulatedDirect

        /// Each mouse's receiver slot (`SimulatedDirect.index` for the Bluetooth one).
        static let verticalSlot: UInt8 = 1
        static let masterSlot: UInt8 = 1

        init() {
            unifying = SimulatedReceiver.unifying([Self.verticalSlot: DeviceProfiles.mxVertical])
            bolt = SimulatedReceiver.bolt([Self.masterSlot: DeviceProfiles.mxMaster3S])
            bluetooth = SimulatedDirect(profile: DeviceProfiles.lift, connection: .bluetooth)
            source = SimulatedLinkSource([
                .receiver(unifying, registryID: 0xDE30_0011),
                .receiver(bolt, registryID: 0xDE30_0012),
                .direct(bluetooth, registryID: 0xDE30_0013),
            ])
            // The Bolt receiver answers a little later, so the two receivers' mice identify (and
            // are listed) in the same order every run: Lift (a direct link starts at once), MX
            // Vertical, MX Master 3S. `settle()` removes the delay.
            bolt.latency = 0.004
        }

        /// Every mouse answers right away again (after they have connected).
        func settle() {
            bolt.latency = 0
        }

        /// The three mice, in the order they appear in the UI.
        enum Mouse: CaseIterable {
            case vertical, master, lift

            var profile: SimulatedDeviceProfile {
                switch self {
                case .vertical: return DeviceProfiles.mxVertical
                case .master: return DeviceProfiles.mxMaster3S
                case .lift: return DeviceProfiles.lift
                }
            }

            /// The model the mouse identifies as (the catalog's key for any of its product IDs).
            var modelKey: ModelKey {
                let pids = [profile.bluetoothPID, profile.wirelessPID, profile.usbPID].compactMap { $0 }
                return pids.lazy.compactMap { DeviceCatalog.model(forPID: $0)?.key }.first
                    ?? ModelKey(productID: pids.first ?? 0)
            }
        }

        /// The mouse broadcasts a new battery level, as a real one does when it changes.
        func setBattery(_ percentage: Int, of mouse: Mouse, charging: Bool = false) {
            switch mouse {
            case .vertical: unifying.reportBattery(percentage: percentage, charging: charging, slot: Self.verticalSlot)
            case .master: bolt.reportBattery(percentage: percentage, charging: charging, slot: Self.masterSlot)
            case .lift: bluetooth.reportBattery(percentage: percentage, charging: charging)
            }
        }

        func batteryLevel(of mouse: Mouse) -> Int? {
            switch mouse {
            case .vertical: return unifying.batteryLevel(slot: Self.verticalSlot)
            case .master: return bolt.batteryLevel(slot: Self.masterSlot)
            case .lift: return bluetooth.batteryLevel
            }
        }
    }
}

// MARK: - Scenario

extension DemoMode {
    /// What the demo shows besides the mice: button setups (with a gesture button and app
    /// profiles), scrolling, pointer speeds and battery levels.
    enum Scenario {
        static let safari = AppReference(bundleID: "com.apple.Safari", displayName: "Safari")
        static let music = AppReference(bundleID: "com.apple.Music", displayName: "Music")
        static let finder = AppReference(bundleID: "com.apple.finder", displayName: "Finder")

        /// Battery levels the mice report once connected.
        static let batteryLevels: [Fleet.Mouse: Int] = [.vertical: 85, .master: 60, .lift: 45]
        /// The low-battery variant: the Lift is almost empty.
        static let lowBatteryLevel = 8

        /// Pointer speeds kept per mouse.
        static let pointerSpeeds: [Fleet.Mouse: Int] = [.vertical: 1600, .master: 1000, .lift: 1200]

        /// The MX Vertical's Top Button as a gesture button, with every slot set.
        static let topButtonGestures = GestureSet(
            tap: .system(.missionControl),
            up: .system(.showDesktop),
            down: .system(.appExpose),
            left: .system(.spaceLeft),
            right: .system(.spaceRight)
        )

        /// Top Button actions for the `buttons.global.N` variants.
        static let topButtonVariants: [ButtonAction] = [
            .system(.missionControl),
            .system(.spaceLeft),
            .system(.playPause),
            .launchApp(AppReference(bundleID: "com.apple.Notes", displayName: "Notes")),
            .openURL(URL(string: "https://github.com/dpdev69/upright")!),
            .runShortcut(String(localized: "Start Focus Session", comment: "Name of a Shortcuts.app shortcut shown in Demo Mode")),
        ]

        /// Every model's setup: a global table each, Safari and Music profiles for the MX Vertical,
        /// a Safari profile for the MX Master 3S.
        static var library: MappingLibrary {
            var library = MappingLibrary()

            var vertical = MappingProfiles()
            vertical.global[KnownControl.middleClick] = .system(.missionControl)
            vertical.global[KnownControl.forward] = .system(.navigateForward)
            vertical.global[KnownControl.dpiSwitch] = .gestures(topButtonGestures)
            vertical.upsert(AppProfile(bundleID: safari.bundleID, displayName: safari.displayName, overrides: [
                KnownControl.back: .system(.previousTab),
                KnownControl.forward: .system(.nextTab),
                KnownControl.middleClick: .keyCombo(KeyCombo(keyCode: 13, modifiers: .command, keyLabel: "W")),
            ]))
            vertical.upsert(AppProfile(bundleID: music.bundleID, displayName: music.displayName, overrides: [
                KnownControl.back: .system(.previousTrack),
                KnownControl.forward: .system(.nextTrack),
                KnownControl.middleClick: .system(.playPause),
            ]))
            library[Fleet.Mouse.vertical.modelKey] = vertical

            var master = MappingProfiles()
            master.global[KnownControl.gestureButton] = .gestures(.standard)
            master.global[KnownControl.middleClick] = .system(.missionControl)
            master.upsert(AppProfile(bundleID: safari.bundleID, displayName: safari.displayName, overrides: [
                KnownControl.back: .system(.previousTab),
                KnownControl.forward: .system(.nextTab),
            ]))
            library[Fleet.Mouse.master.modelKey] = master

            var lift = MappingProfiles()
            lift.global[KnownControl.dpiSwitch] = .device(.cycleDPI)
            lift.global[KnownControl.middleClick] = .system(.appExpose)
            library[Fleet.Mouse.lift.modelKey] = lift

            return library
        }

        /// Reverse and smooth scrolling on, a little faster than macOS.
        static let scrollSettings = ScrollSettings(reverseVertical: true, speed: 1.25, smoothScrolling: true)

        /// Applies the setup to a Demo Mode model. Never call it on a live one: it replaces the
        /// mappings and settings.
        @MainActor
        static func apply(to model: AppModel) {
            precondition(model.environment.isDemo, "The demo scenario only goes into a Demo Mode model")
            model.library = library
            model.isRemappingEnabled = true
            model.selectedModel = Fleet.Mouse.vertical.modelKey
            model.settings.scrollSettings = scrollSettings
            model.settings.showBatteryInMenuBar = true
            model.settings.batteryAlertsEnabled = true
            model.settings.hasCompletedOnboarding = true
        }
    }

    /// `--demo` (not exporting): seeds the scenario into the running Demo Mode model and adds the
    /// app's real wake message to the activity log. Call after `AppModel.start()`.
    @MainActor
    static func didStart(model: AppModel) {
        guard isActive, !isExporting, model.environment.isDemo else { return }
        Scenario.apply(to: model)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            model.devices.systemDidWake()
        }
    }
}

// MARK: - Frontmost app

extension DemoMode {
    /// Makes Upright believe `app` became the frontmost app, so the per-app profile UI can be shown
    /// without switching apps. The notification is posted on this process's own workspace
    /// notification center only; nothing outside Upright sees it. The app must be a standard
    /// Apple app (privacy: the user's own apps are never shown).
    @MainActor
    static func pretendFrontmost(_ app: AppReference) {
        let running = DemoRunningApplication(app)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: running]
        )
    }
}

/// A stand-in `NSRunningApplication` for `DemoMode.pretendFrontmost`: it only answers its bundle
/// identifier and name.
private final class DemoRunningApplication: NSRunningApplication, @unchecked Sendable {
    private let reference: AppReference

    init(_ reference: AppReference) {
        self.reference = reference
        super.init()
    }

    override var bundleIdentifier: String? { reference.bundleID }
    override var localizedName: String? { reference.displayName }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
}
