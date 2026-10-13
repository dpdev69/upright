import Combine
import SwiftUI
import os

/// App-wide state: the user's mappings, the remapping switch, and the services that act on them.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private static let remappingEnabledKey = "remappingEnabled"

    /// The global table plus per-app profiles. Saved and applied on every change.
    @Published var profiles: MappingProfiles {
        didSet {
            guard profiles != oldValue else { return }
            store.save(profiles)
            applyMappings()
        }
    }

    @Published var isRemappingEnabled: Bool {
        didSet {
            defaults.set(isRemappingEnabled, forKey: Self.remappingEnabledKey)
            engine.isEnabled = isRemappingEnabled
            syncDiversion()
        }
    }

    /// The app whose profile is in effect (the frontmost app other than Upright).
    @Published private(set) var frontmostApp: FrontmostApp?

    @Published var selectedPane: SettingsPane = .buttons

    /// A button press the mouse reported to Upright, for live feedback in the UI.
    struct PressedControl: Equatable {
        let cid: UInt16
        let date: Date
    }

    /// The latest diverted-button press, whether or not remapping is on or the button is mapped.
    /// Buttons left to the mouse don't report.
    @Published private(set) var lastPressedControl: PressedControl?

    let devices: DeviceManager
    let permissions: PermissionsMonitor
    let loginItem: LoginItemController
    let frontmostMonitor: FrontmostAppMonitor
    /// Scroll, battery and pointer-speed preferences. Changes also republish this model.
    let settings: AppSettings
    /// Applies `settings.scrollSettings` to mouse-wheel events.
    let scroll: ScrollController
    let batteryNotifier: BatteryNotifier

    private let engine: RemapEngine
    private let defaults: UserDefaults
    private let store: MappingStore
    private let logger: Logger
    private var cancellables = Set<AnyCancellable>()
    private var appliedDiversion: Set<UInt16>?
    private var appliedRawXY: Set<UInt16>?
    /// Feeds cursor movement to gestures on buttons that can't report raw movement.
    private let movementMonitor = PointerMovementMonitor()
    private var started = false

    init(defaults: UserDefaults = .standard, performer: ActionPerforming? = nil) {
        self.defaults = defaults
        let logger = Logger(subsystem: "Upright", category: "Mappings")
        self.logger = logger
        store = MappingStore(defaults: defaults, log: { logger.notice("\($0, privacy: .public)") })
        // Load before anything writes "remappingEnabled", which also marks an upgrade.
        let profiles = store.load()
        let enabled = defaults.object(forKey: Self.remappingEnabledKey) as? Bool ?? true
        self.profiles = profiles
        self.isRemappingEnabled = enabled
        devices = DeviceManager()
        permissions = PermissionsMonitor(defaults: defaults)
        loginItem = LoginItemController()
        frontmostMonitor = FrontmostAppMonitor()
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        scroll = ScrollController()
        batteryNotifier = BatteryNotifier(isEnabled: settings.batteryAlertsEnabled)
        engine = RemapEngine(mappings: profiles.global, performer: performer ?? SystemActionPerformer())
        engine.isEnabled = enabled
        engine.onDeviceAction = { [weak self] action in self?.performDeviceAction(action) }
        movementMonitor.onDelta = { [weak engine] dx, dy in engine?.handlePointerDelta(dx: dx, dy: dy, source: .cursor) }
        engine.gestureSource = { [weak self] cid in
            self?.supportsRawXY(cid) == false ? .cursor : .rawSensor
        }

        // Views that observe the model also refresh for settings and scroll-tap changes.
        Publishers.Merge(settings.objectWillChange, scroll.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true

        devices.onButtonEvent = { [weak self] event in self?.handle(event) }
        devices.onPointerDelta = { [weak self] dx, dy in self?.engine.handlePointerDelta(dx: dx, dy: dy, source: .rawSensor) }
        permissions.$isAccessibilityTrusted
            .removeDuplicates()
            .sink { [weak self] _ in
                // The publisher fires before the property updates; read the new value on the next turn.
                Task { @MainActor in self?.syncDiversion() }
            }
            .store(in: &cancellables)

        permissions.$inputMonitoring
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                guard status == .granted else { return }
                Task { @MainActor in self?.devices.reconnect() }
            }
            .store(in: &cancellables)

        // Poll for Input Monitoring quickly only while its absence is actually hiding the mouse.
        devices.$status
            .map { $0 == .accessDenied }
            .removeDuplicates()
            .sink { [weak self] denied in self?.permissions.needsInputMonitoring = denied }
            .store(in: &cancellables)

        frontmostMonitor.$current
            .removeDuplicates()
            .sink { [weak self] app in
                Task { @MainActor in self?.frontmostAppDidChange(app) }
            }
            .store(in: &cancellables)

        startScrollAndBattery()

        // Restore the kept pointer speed before the first connection, then persist what the mouse keeps.
        devices.setDesiredDPI(settings.preferredDPI)
        devices.$desiredDPI
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] dpi in self?.settings.preferredDPI = dpi }
            .store(in: &cancellables)

        permissions.start()
        frontmostMonitor.start()
        applyMappings()
        devices.start()
    }

    /// Installs or removes the scroll tap as settings, Accessibility and the connection change,
    /// and feeds battery readings to the notifier. Publishers deliver new values before the
    /// properties update, so this works only with the values passed in.
    private func startScrollAndBattery() {
        let connected = devices.$status
            .map { Self.snapshot(of: $0) != nil }
            .removeDuplicates()
        Publishers.CombineLatest3(settings.$scrollSettings, permissions.$isAccessibilityTrusted.removeDuplicates(), connected)
            .sink { [weak self] scrollSettings, trusted, connected in
                self?.scroll.update(settings: scrollSettings, accessibilityTrusted: trusted, mxVerticalConnected: connected)
            }
            .store(in: &cancellables)

        batteryNotifier.start()
        devices.$status
            .compactMap { Self.snapshot(of: $0) }
            .map { BatteryReading(battery: $0.battery, deviceName: $0.name) }
            .removeDuplicates()
            .sink { [weak self] reading in
                self?.batteryNotifier.update(battery: reading.battery, deviceName: reading.deviceName)
            }
            .store(in: &cancellables)

        settings.$batteryAlertsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                let wasEnabled = self.batteryNotifier.isEnabled
                self.batteryNotifier.isEnabled = enabled
                // Ask for notification permission when the user turns alerts on, not at launch.
                if enabled, !wasEnabled { self.batteryNotifier.requestAuthorization() }
            }
            .store(in: &cancellables)
    }

    private struct BatteryReading: Equatable {
        let battery: BatteryStatus?
        let deviceName: String
    }

    private static func snapshot(of status: DeviceManager.Status) -> DeviceSnapshot? {
        switch status {
        case .connected(let snapshot), .asleep(let snapshot): return snapshot
        default: return nil
        }
    }

    // MARK: Global mappings (what the Buttons pane edits)

    /// The global table. Per-app profiles override it button by button.
    var mappings: ButtonMappings {
        get { profiles.global }
        set { profiles.global = newValue }
    }

    func binding(for cid: UInt16) -> Binding<ButtonAction> {
        Binding(
            get: { self.profiles.global[cid] },
            set: { self.profiles.global[cid] = $0 }
        )
    }

    /// Resets the global table to the fresh-install setup (nothing remapped). App profiles stay.
    func restoreDefaultMappings() {
        profiles.global = .defaults
    }

    /// Clears the global table and removes every app profile.
    func resetAll() {
        profiles = MappingProfiles()
    }

    // MARK: Per-app profiles

    /// The mappings in effect right now, for the frontmost app.
    var effectiveMappings: ButtonMappings {
        profiles.effectiveMappings(forBundleID: frontmostApp?.bundleID)
    }

    /// An app's override for a button: nil inherits the global mapping, `.deviceDefault` leaves
    /// the button to the mouse in that app.
    func overrideBinding(for cid: UInt16, bundleID: String) -> Binding<ButtonAction?> {
        Binding(
            get: { self.profiles[app: bundleID]?[cid] },
            set: { self.profiles[app: bundleID]?[cid] = $0 }
        )
    }

    func addAppProfile(bundleID: String, displayName: String) {
        profiles.addApp(bundleID: bundleID, displayName: displayName)
    }

    func removeAppProfile(bundleID: String) {
        profiles.removeApp(bundleID: bundleID)
    }

    func setAppProfileEnabled(_ enabled: Bool, bundleID: String) {
        profiles[app: bundleID]?.isEnabled = enabled
    }

    // MARK: Export / import

    /// Pretty-printed JSON of every mapping and profile, with a schema version.
    func exportData() -> Data {
        do {
            return try MappingStore.exportData(profiles)
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return Data()
        }
    }

    struct ImportSummary {
        /// Entries that couldn't be used and were left out.
        let skipped: [String]
        /// Imported actions that open apps, links or shortcuts, for the user to look over.
        let actionsToReview: [MappingStore.ReviewItem]
        /// What the import replaced, for `undoImport`. Also backed up in UserDefaults.
        let previousProfiles: MappingProfiles
    }

    /// Replaces all mappings with an exported file's, after backing up the current ones.
    /// Throws `MappingStore.ImportError` (and changes nothing) when the file can't be used.
    @discardableResult
    func importData(_ data: Data) throws -> ImportSummary {
        let report = MappingDecodingReport()
        let outcome = try store.prepareImport(data, replacing: profiles, report: report)
        report.issues.forEach { logger.notice("Import: \($0, privacy: .public)") }
        let summary = ImportSummary(skipped: report.issues, actionsToReview: outcome.actionsToReview, previousProfiles: profiles)
        profiles = outcome.profiles
        return summary
    }

    /// Puts back what an import replaced.
    func undoImport(_ summary: ImportSummary) {
        profiles = summary.previousProfiles
    }

    // MARK: Accessibility

    /// True when at least one mapping (global or in an enabled app profile) needs Accessibility.
    var needsAccessibility: Bool {
        profiles.allActiveActions.contains { $0.requiresAccessibility }
    }

    var isMissingAccessibility: Bool {
        needsAccessibility && !permissions.isAccessibilityTrusted
    }

    // MARK: Gestures

    /// True when a button mapped to gestures right now can't report raw movement, so gestures on
    /// it follow the cursor instead (which moves while the button is held).
    var gesturesNeedRawXYFallback: Bool {
        effectiveMappings
            .gestureControls(accessibilityGranted: permissions.isAccessibilityTrusted)
            .contains { !supportsRawXY($0) }
    }

    /// Whether the connected mouse can report raw movement for a control. Unknown (no mouse yet) counts as yes.
    func supportsRawXY(_ cid: UInt16) -> Bool {
        guard let snapshot = devices.snapshot else { return true }
        return snapshot.controls.first { $0.cid == cid }?.supportsRawXY ?? false
    }

    // MARK: Routing

    private func handle(_ event: ButtonEvent) {
        if event.phase == .press {
            lastPressedControl = PressedControl(cid: event.cid, date: Date())
            // Raw movement is in sensor counts, so the gesture distance follows the pointer speed.
            engine.rawGestureThreshold = GestureRecognizer.rawThreshold(dpi: devices.snapshot?.dpi?.current)
        }
        engine.handle(event)
        updateMovementMonitor()
        // A button released after an app switch may have been kept diverted only so this release arrived.
        if event.phase == .release,
           appliedDiversion?.contains(event.cid) == true || appliedRawXY?.contains(event.cid) == true {
            syncDiversion()
        }
    }

    /// Watches cursor movement only while a gesture button without raw XY is held.
    private func updateMovementMonitor() {
        let needsFallback = engine.gestureControls.contains { !supportsRawXY($0) }
        if needsFallback { movementMonitor.start() } else { movementMonitor.stop() }
    }

    private func frontmostAppDidChange(_ app: FrontmostApp?) {
        guard app != frontmostApp else { return }
        frontmostApp = app
        applyMappings()
    }

    private func applyMappings() {
        engine.mappings = effectiveMappings
        syncDiversion()
    }

    /// Diverts what the frontmost app's mappings need, plus any button still held, so its release
    /// reaches the engine even if the new app leaves that button to the mouse. Gesture buttons also
    /// report raw movement, and keep doing so while a gesture is in progress.
    private func syncDiversion() {
        let trusted = permissions.isAccessibilityTrusted
        let mappings = effectiveMappings
        let cids = isRemappingEnabled
            ? mappings.divertedControls(accessibilityGranted: trusted).union(engine.pressedControls)
            : []
        let rawXY = isRemappingEnabled
            ? mappings.gestureControls(accessibilityGranted: trusted).union(engine.gestureControls)
            : []
        updateMovementMonitor()
        if rawXY != appliedRawXY {
            appliedRawXY = rawXY
            devices.setDesiredRawXY(rawXY)
        }
        guard cids != appliedDiversion else { return }
        appliedDiversion = cids
        devices.setDesiredDiversion(cids)
    }

    private func performDeviceAction(_ action: DeviceAction) {
        switch action {
        case .cycleDPI: devices.cycleDPI(presets: settings.dpiPresets)
        case .setDPI, .switchHost: devices.perform(action)
        }
    }
}

/// Reports cursor movement (in points, positive y down) while started. Used for gestures on
/// buttons whose raw movement the mouse can't divert; global monitors need no extra permission.
@MainActor
private final class PointerMovementMonitor {
    var onDelta: ((Int, Int) -> Void)?

    private var monitors: [Any] = []
    private var remainder = (x: 0.0, y: 0.0)

    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard !isRunning else { return }
        remainder = (0, 0)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            let delta = (x: Double(event.deltaX), y: Double(event.deltaY))
            MainActorDelivery.run { self?.handle(delta) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            let delta = (x: Double(event.deltaX), y: Double(event.deltaY))
            MainActorDelivery.run { self?.handle(delta) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ delta: (x: Double, y: Double)) {
        // Keep fractional movement so slow drags still add up.
        let x = remainder.x + delta.x
        let y = remainder.y + delta.y
        let dx = Int(x.rounded(.towardZero))
        let dy = Int(y.rounded(.towardZero))
        remainder = (x - Double(dx), y - Double(dy))
        guard dx != 0 || dy != 0 else { return }
        onDelta?(dx, dy)
    }
}
