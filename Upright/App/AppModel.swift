import Combine
import SwiftUI
import os

/// App-wide state: every model's mappings, every mouse's preferences, the remapping switch, and
/// the services that act on them.
///
/// Routing (design §C steps 5–10):
/// - Mappings are per model (`MappingLibrary`). The engine asks, at each press, for the table of
///   the model of the mouse that pressed (`mappingsProvider`), with the frontmost app's profile.
/// - Each endpoint's configuration (diversion, raw XY, pointer speed) comes from
///   `ConfigurationPlanner`: pulled by the hub when the mouse identifies (`configurationProvider`),
///   then pushed again (`resync`) when anything it depends on changes, but only when it differs
///   from what was last applied to that address (`appliedConfig`).
/// - Gesture distance and the raw/cursor movement source are per device: that mouse's DPI and
///   whether that mouse reports raw XY for the control.
/// - Pointer-speed changes are stored for that unit only (`DevicePreferences.preferredDPI`).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(environment: .current)

    private static let remappingEnabledKey = "remappingEnabled"

    /// Every model's setup (a global table plus per-app profiles each). Saved and applied on every change.
    @Published var library: MappingLibrary {
        didSet {
            guard library != oldValue else { return }
            store.save(library)
            applyMappings()
        }
    }

    @Published var isRemappingEnabled: Bool {
        didSet {
            guard isRemappingEnabled != oldValue else { return }
            defaults.set(isRemappingEnabled, forKey: Self.remappingEnabledKey)
            engine.isEnabled = isRemappingEnabled
            resyncAll()
        }
    }

    /// The app whose profile is in effect (the frontmost app other than Upright).
    @Published private(set) var frontmostApp: FrontmostApp?

    @Published var selectedPane: SettingsPane = .buttons

    /// The mouse the Mice pane and the menu act on. Follows the unit across reconnects (a new
    /// address for the same `DeviceID`), and falls back to the first connected mouse when it goes.
    /// Choosing a mouse also points `selectedModel` at its model.
    @Published var selectedDevice: DeviceAddress? {
        didSet {
            guard selectedDevice != oldValue else { return }
            if let selectedDevice {
                selectedDeviceID = record(selectedDevice)?.deviceID
            } else {
                selectedDeviceID = nil
            }
            guard !isAdjustingSelection, let selectedDevice, let model = model(of: selectedDevice) else { return }
            selectedModel = model
        }
    }

    /// The model the Buttons pane edits. Until the user picks one (here or by choosing a mouse),
    /// it follows the selected mouse's model, else stays on the MX Vertical.
    @Published var selectedModel: ModelKey = .mxVertical {
        didSet {
            if !isAdjustingSelection, selectedModel != oldValue { modelWasChosen = true }
        }
    }

    /// The last mouse that sent a press (handled, i.e. from an active endpoint).
    @Published private(set) var focusedDevice: DeviceAddress?

    /// A button press a mouse reported to Upright, for live feedback in the UI.
    struct PressedControl: Equatable {
        let cid: UInt16
        /// The mouse that sent it.
        let source: DeviceAddress
        /// That mouse's model when it was pressed (nil if it hadn't identified).
        let model: ModelKey?
        let date: Date

        init(cid: UInt16, source: DeviceAddress = .unassigned, model: ModelKey? = nil, date: Date = Date()) {
            self.cid = cid
            self.source = source
            self.model = model
            self.date = date
        }
    }

    /// The latest diverted-button press, whether or not remapping is on or the button is mapped.
    /// Buttons left to the mouse don't report.
    @Published private(set) var lastPressedControl: PressedControl?

    let environment: AppEnvironment
    /// The defaults everything in this model reads and writes (Demo Mode has its own suite).
    let defaults: UserDefaults
    let devices: DeviceManager
    let permissions: PermissionsMonitor
    let loginItem: LoginItemController
    let frontmostMonitor: FrontmostAppMonitor
    /// Scroll, battery, pointer-speed presets and per-mouse preferences. Changes also republish this model.
    let settings: AppSettings
    /// Applies `settings.scrollSettings` to mouse-wheel events.
    let scroll: ScrollController
    let batteryNotifier: BatteryNotifier

    private let engine: RemapEngine
    private let store: MappingStore
    private let logger: Logger
    private var cancellables = Set<AnyCancellable>()
    /// What each endpoint was last told to do, by address.
    private(set) var appliedConfig: [DeviceAddress: EndpointConfiguration] = [:]
    /// Feeds cursor movement to gestures on buttons that can't report raw movement.
    private let movementMonitor = PointerMovementMonitor()
    private var started = false
    /// The unit behind `selectedDevice`, to find it again on a new address.
    private var selectedDeviceID: DeviceID?
    /// The user picked `selectedModel` (directly or by choosing a mouse); stop following devices.
    private var modelWasChosen = false
    private var isAdjustingSelection = false
    /// What was last recorded in `devicePreferences` per unit, so `lastSeen` isn't rewritten on
    /// every battery reading.
    private var recordedUnits: [DeviceID: RecordedUnit] = [:]
    /// The last battery reading fed to the notifier, per address.
    private var batteryReadings: [DeviceAddress: BatteryStatus] = [:]
    /// The last snapshot of every endpoint, kept after it goes so preferences can note when it left.
    private var lastSnapshots: [DeviceAddress: DeviceSnapshot] = [:]

    private struct RecordedUnit: Equatable {
        let name: String
        let controls: [UInt16]
        let connection: ConnectionKind
    }

    convenience init(defaults: UserDefaults = .standard, performer: ActionPerforming? = nil) {
        self.init(environment: .live, defaults: defaults, performer: performer)
    }

    /// `defaults` and `devices` default to the environment's; `performer` to the system one
    /// (live) or a no-op (demo).
    init(
        environment: AppEnvironment,
        defaults: UserDefaults? = nil,
        devices: DeviceManager? = nil,
        performer: ActionPerforming? = nil
    ) {
        self.environment = environment
        let defaults = defaults ?? environment.makeDefaults()
        self.defaults = defaults
        let logger = Logger(subsystem: "Upright", category: "Mappings")
        self.logger = logger
        store = MappingStore(defaults: defaults, log: { logger.notice("\($0, privacy: .public)") })
        // Load before anything writes "remappingEnabled", which also marks an upgrade.
        let loaded = store.loadLibrary()
        for issue in loaded.report.issues {
            logger.notice("Mappings: \(issue, privacy: .public)")
        }
        let enabled = defaults.object(forKey: Self.remappingEnabledKey) as? Bool ?? true
        library = loaded.library
        isRemappingEnabled = enabled
        self.devices = devices ?? environment.makeDeviceManager()
        permissions = PermissionsMonitor(defaults: defaults, environment: environment)
        loginItem = LoginItemController(environment: environment)
        frontmostMonitor = FrontmostAppMonitor()
        // AppSettings also copies the 2.x pointer speed into the MX Vertical's seed (once).
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        scroll = ScrollController()
        batteryNotifier = BatteryNotifier(isEnabled: settings.batteryAlertsEnabled)
        let performer = performer ?? (environment.isDemo ? NoOpActionPerformer() : SystemActionPerformer())
        engine = RemapEngine(mappings: ButtonMappings(), performer: performer)
        engine.isEnabled = enabled
        installEngineProviders()
        movementMonitor.onDelta = { [weak engine] dx, dy in engine?.handleCursorDelta(dx: dx, dy: dy) }

        // Views that observe the model also refresh for settings and scroll-tap changes.
        Publishers.Merge(settings.objectWillChange, scroll.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func installEngineProviders() {
        engine.mappingsProvider = { [weak self] source in
            guard let self else { return ButtonMappings() }
            return self.library.effectiveMappings(model: self.model(of: source), bundleID: self.frontmostApp?.bundleID)
        }
        // Raw movement is in sensor counts, so the gesture distance follows that mouse's speed.
        engine.rawThresholdProvider = { [weak self] source in
            GestureRecognizer.rawThreshold(dpi: self?.snapshot(of: source)?.dpi?.current)
        }
        engine.gestureSourceFor = { [weak self] source, cid in
            guard let control = self?.snapshot(of: source)?.controls.first(where: { $0.cid == cid }) else { return .rawSensor }
            return control.supportsRawXY ? .rawSensor : .cursor
        }
        engine.onSourcedDeviceAction = { [weak self] action, source in
            self?.perform(action, on: source)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        devices.configurationProvider = { [weak self] address, snapshot in
            self?.pullConfiguration(for: address, snapshot: snapshot) ?? .native
        }
        devices.onButtonEvent = { [weak self] event in self?.handle(event) }
        devices.onPointerDelta = { [weak self] delta in self?.engine.handlePointerDelta(delta) }
        devices.onEndpointsRemoved = { [weak self] addresses in self?.endpointsRemoved(addresses) }
        devices.onDeviceDPIChange = { [weak self] address, dpi in self?.storePreferredDPI(dpi, for: address) }
        devices.nameProvider = { [weak self] id in self?.settings.devicePreferences.devices[id]?.trimmedNickname }
        devices.rememberedControls = { [weak self] model in self?.rememberedControls(of: model) }

        permissions.$isAccessibilityTrusted
            .removeDuplicates()
            .sink { [weak self] _ in
                // The publisher fires before the property updates; read the new value on the next turn.
                Task { @MainActor in self?.resyncAll() }
            }
            .store(in: &cancellables)

        permissions.$inputMonitoring
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                guard status == .granted else { return }
                Task { @MainActor in self?.devices.reconnect(nil) }
            }
            .store(in: &cancellables)

        // Poll for Input Monitoring quickly only while its absence is actually hiding a mouse.
        devices.$blockedInterfaces
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] blocked in self?.permissions.needsInputMonitoring = blocked }
            .store(in: &cancellables)

        frontmostMonitor.$current
            .removeDuplicates()
            .sink { [weak self] app in
                Task { @MainActor in self?.frontmostAppDidChange(app) }
            }
            .store(in: &cancellables)

        // Records publish before they change; act on the next turn, when they have.
        devices.$records
            .sink { [weak self] _ in
                Task { @MainActor in self?.devicesDidChange() }
            }
            .store(in: &cancellables)

        // Nicknames, "Remap this mouse" and speeds change what each mouse should be doing.
        settings.$devicePreferences
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.devices.refreshNames()
                    self?.resyncAll()
                }
            }
            .store(in: &cancellables)

        startScrollAndBattery()

        permissions.start()
        frontmostMonitor.start()
        applyMappings()
        devices.start()
    }

    /// Installs or removes the scroll tap as settings, Accessibility and the mice change, and
    /// lets the battery notifier ask for permission. Publishers deliver new values before the
    /// properties update, so this works only with the values passed in. Demo Mode installs no tap
    /// and posts no notifications.
    private func startScrollAndBattery() {
        let present = devices.$summary
            .map(\.anyPresent)
            .removeDuplicates()
        let tapsAllowed = environment.usesEventTaps
        Publishers.CombineLatest3(settings.$scrollSettings, permissions.$isAccessibilityTrusted.removeDuplicates(), present)
            .sink { [weak self] scrollSettings, trusted, present in
                self?.scroll.update(settings: scrollSettings, accessibilityTrusted: trusted && tapsAllowed, mousePresent: present)
            }
            .store(in: &cancellables)

        guard environment.postsNotifications else { return }
        batteryNotifier.start()
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

    // MARK: Devices

    /// The record of a live endpoint.
    func record(_ address: DeviceAddress) -> DeviceRegistry.Record? {
        devices.records.first { $0.address == address }
    }

    /// The model of a live endpoint, once it has identified.
    func model(of address: DeviceAddress) -> ModelKey? {
        record(address)?.model ?? snapshot(of: address)?.identity?.model
    }

    /// The snapshot of an endpoint: live (connected or asleep), else the last one it identified
    /// with while it reconnects. During a connect the hub reports before the registry knows it.
    func snapshot(of address: DeviceAddress) -> DeviceSnapshot? {
        devices.snapshot(address) ?? lastSnapshots[address]
    }

    /// The first served, connected mouse in list order (`DeviceManager.primaryAddress`).
    var primaryDevice: DeviceAddress? {
        devices.primaryAddress
    }

    /// The controls last seen on a mouse of `model` (most recently seen first), for its rows
    /// while none is connected.
    private func rememberedControls(of model: ModelKey) -> [UInt16]? {
        settings.devicePreferences.rememberedDevices()
            .first { ($0.preferences.lastModel ?? $0.id.model) == model && !$0.preferences.lastControls.isEmpty }?
            .preferences.lastControls
    }

    /// The mouse the menu's button summary, pointer speed and Easy-Switch act on: the last one
    /// pressed, else the selected one, else the first connected.
    var menuDevice: DeviceAddress? {
        for candidate in [focusedDevice, selectedDevice] {
            if let candidate, record(candidate) != nil { return candidate }
        }
        return primaryDevice
    }

    /// Models with a mouse connected or asleep right now, in list order.
    var connectedModels: [ModelKey] {
        unique(devices.records.filter { $0.role != .unsupported && $0.snapshot != nil }.compactMap(\.model))
    }

    /// Models of mice seen before that aren't here now, most recently seen first.
    var rememberedModels: [ModelKey] {
        let present = Set(connectedModels)
        let connectedIDs = Set(devices.records.compactMap(\.deviceID))
        let remembered = settings.devicePreferences.rememberedDevices(excluding: connectedIDs)
            .compactMap { $0.preferences.lastModel ?? $0.id.model }
        return unique(remembered).filter { !present.contains($0) }
    }

    /// Every model worth offering in the Buttons pane: connected, then remembered, then any other
    /// model with a setup (by name). Always includes `selectedModel`.
    var knownModels: [ModelKey] {
        var models = connectedModels + rememberedModels
        let listed = Set(models)
        let others = library.models.keys.filter { !listed.contains($0) }
            .sorted { modelName($0).localizedStandardCompare(modelName($1)) == .orderedAscending }
        models += others
        if !models.contains(selectedModel) { models.append(selectedModel) }
        return models
    }

    /// The name shown for a model: the library's or catalog's, else what a connected mouse of it
    /// reports, else its key.
    func modelName(_ model: ModelKey) -> String {
        if library.modelNames[model] != nil || DeviceCatalog.model(model) != nil {
            return library.name(of: model)
        }
        if let reported = devices.records.first(where: { $0.model == model })?.snapshot?.name {
            return reported
        }
        if let remembered = settings.devicePreferences.devices.values.first(where: { $0.lastModel == model })?.lastName {
            return remembered
        }
        return library.name(of: model)
    }

    /// The live endpoints of a model (served ones first), e.g. for "Applies to every MX Vertical".
    func addresses(of model: ModelKey) -> [DeviceAddress] {
        devices.records.filter { $0.model == model && $0.role != .unsupported }.map(\.address)
    }

    /// The device whose controls best describe `model`: the selected mouse if it is one, else
    /// the first live one of that model.
    func representativeDevice(of model: ModelKey) -> DeviceAddress? {
        if let selectedDevice, self.model(of: selectedDevice) == model { return selectedDevice }
        return addresses(of: model).first
    }

    /// The controls to show for a model (live mouse, else remembered, else catalog).
    func controls(for model: ModelKey) -> [ControlDescriptor] {
        devices.controls(for: model, address: representativeDevice(of: model))
    }

    // MARK: Per-mouse preferences

    /// One mouse's preferences. Writes to a mouse without a stable ID are ignored (it can't be
    /// remembered), and the Mice pane says so.
    func preferences(_ id: DeviceID) -> Binding<DevicePreferences> {
        Binding(
            get: { self.devicePreferences(for: id) },
            set: { self.settings.devicePreferences.setPreferences($0, for: id) }
        )
    }

    func devicePreferences(for id: DeviceID) -> DevicePreferences {
        settings.devicePreferences.preferences(for: id, model: id.model ?? .mxVertical)
    }

    /// The preferences of a live endpoint (its unit's, or its model's seed when it can't be remembered).
    func devicePreferences(for address: DeviceAddress) -> DevicePreferences {
        guard let snapshot = snapshot(of: address) else {
            return record(address)?.deviceID.map(devicePreferences(for:)) ?? DevicePreferences()
        }
        return preferences(for: address, snapshot: snapshot)
    }

    /// Forgets a mouse: nickname, speed, remap switch and what was last seen of it.
    func forget(_ id: DeviceID) {
        settings.devicePreferences.forget(id)
        recordedUnits[id] = nil
    }

    /// Sets (or with nil, hands back to the mouse) one mouse's pointer speed, now and on every
    /// reconnect. Other mice keep theirs.
    func setPreferredDPI(_ dpi: Int?, for address: DeviceAddress) {
        // Stored first, so the resync it causes asks for the same speed.
        storePreferredDPI(dpi, for: address)
        devices.setDPI(dpi, on: address)
    }

    private func preferences(for address: DeviceAddress, snapshot: DeviceSnapshot) -> DevicePreferences {
        let model = snapshot.identity?.model ?? snapshot.modelKey
        let id = snapshot.identity?.deviceID(at: address) ?? .transient(address)
        return settings.devicePreferences.preferences(for: id, model: model)
    }

    /// A speed chosen on the mouse, by Cycle Pointer Speed or in the UI becomes that unit's own
    /// preference. Nothing is broadcast to other mice.
    private func storePreferredDPI(_ dpi: Int?, for address: DeviceAddress) {
        guard let snapshot = snapshot(of: address),
              let id = snapshot.identity?.deviceID(at: address), id.isStable
        else { return }
        var prefs = settings.devicePreferences.preferences(for: id, model: snapshot.identity?.model ?? snapshot.modelKey)
        guard prefs.preferredDPI != dpi else { return }
        prefs.preferredDPI = dpi
        settings.devicePreferences.setPreferences(prefs, for: id)
    }

    // MARK: Mappings of a model (what the Buttons pane edits)

    /// The selected model's setup (compat for views that predate multi-mouse).
    var profiles: MappingProfiles {
        get { library[selectedModel] }
        set { setProfiles(newValue, for: selectedModel) }
    }

    /// The selected model's global table. Per-app profiles override it button by button.
    var mappings: ButtonMappings {
        get { library[selectedModel].global }
        set { profiles.global = newValue }
    }

    func profiles(for model: ModelKey) -> MappingProfiles {
        library[model]
    }

    func setProfiles(_ profiles: MappingProfiles, for model: ModelKey) {
        guard library[model] != profiles else { return }
        library[model] = profiles
    }

    func binding(for cid: UInt16, model: ModelKey) -> Binding<ButtonAction> {
        Binding(
            get: { self.library[model].global[cid] },
            set: { self.library[model].global[cid] = $0 }
        )
    }

    /// `binding(for:model:)` for the selected model.
    func binding(for cid: UInt16) -> Binding<ButtonAction> {
        binding(for: cid, model: selectedModel)
    }

    /// Resets a model's global table to the fresh-install setup (nothing remapped). App profiles stay.
    func restoreDefaultMappings(model: ModelKey) {
        library[model].global = .defaults
    }

    func restoreDefaultMappings() {
        restoreDefaultMappings(model: selectedModel)
    }

    /// Clears a model's global table and removes its app profiles: every button native.
    func resetMappings(model: ModelKey) {
        library.models[model] = nil
    }

    /// Clears every model's setup.
    func resetAll() {
        var cleared = library
        cleared.models = [:]
        library = cleared
    }

    /// Replaces `target`'s setup (global table and app profiles) with a copy of `source`'s.
    func copySetup(from source: ModelKey, to target: ModelKey) {
        guard source != target else { return }
        var updated = library
        updated[target] = library[source]
        nameModel(target, in: &updated)
        library = updated
    }

    /// "Use this setup for all my mice": copies `source`'s setup to every other known model.
    func applySetupToAllModels(from source: ModelKey) {
        var updated = library
        for target in knownModels where target != source {
            updated[target] = library[source]
            nameModel(target, in: &updated)
        }
        library = updated
    }

    /// Keeps a readable name next to a model's setup (written to exports).
    private func nameModel(_ model: ModelKey, in library: inout MappingLibrary) {
        guard library.modelNames[model] == nil, DeviceCatalog.model(model) == nil else { return }
        let name = modelName(model)
        if name != model.rawValue { library.modelNames[model] = name }
    }

    // MARK: Per-app profiles

    /// The table in effect for a model right now, for the frontmost app.
    func effectiveMappings(model: ModelKey) -> ButtonMappings {
        library.effectiveMappings(model: model, bundleID: frontmostApp?.bundleID)
    }

    /// The table in effect right now on one mouse.
    func effectiveMappings(for address: DeviceAddress) -> ButtonMappings {
        library.effectiveMappings(model: model(of: address), bundleID: frontmostApp?.bundleID)
    }

    /// The table in effect right now on the menu's mouse (`menuDevice`), else for the selected model.
    var effectiveMappings: ButtonMappings {
        effectiveMappings(model: menuDevice.flatMap(model(of:)) ?? selectedModel)
    }

    /// An app's override for a button: nil inherits the global mapping, `.deviceDefault` leaves
    /// the button to the mouse in that app.
    func overrideBinding(for cid: UInt16, model: ModelKey, bundleID: String) -> Binding<ButtonAction?> {
        Binding(
            get: { self.library[model][app: bundleID]?[cid] },
            set: { self.library[model][app: bundleID]?[cid] = $0 }
        )
    }

    /// `overrideBinding(for:model:bundleID:)` for the selected model.
    func overrideBinding(for cid: UInt16, bundleID: String) -> Binding<ButtonAction?> {
        overrideBinding(for: cid, model: selectedModel, bundleID: bundleID)
    }

    func addAppProfile(bundleID: String, displayName: String, model: ModelKey) {
        library[model].addApp(bundleID: bundleID, displayName: displayName)
    }

    func addAppProfile(bundleID: String, displayName: String) {
        addAppProfile(bundleID: bundleID, displayName: displayName, model: selectedModel)
    }

    func removeAppProfile(bundleID: String, model: ModelKey) {
        library[model].removeApp(bundleID: bundleID)
    }

    func removeAppProfile(bundleID: String) {
        removeAppProfile(bundleID: bundleID, model: selectedModel)
    }

    func setAppProfileEnabled(_ enabled: Bool, bundleID: String, model: ModelKey) {
        library[model][app: bundleID]?.isEnabled = enabled
    }

    func setAppProfileEnabled(_ enabled: Bool, bundleID: String) {
        setAppProfileEnabled(enabled, bundleID: bundleID, model: selectedModel)
    }

    // MARK: Export / import

    /// Pretty-printed JSON of every model's setup (schema 3, plus the MX Vertical's at the top
    /// level for 2.x builds). Never per-Mac device preferences.
    func exportData() -> Data {
        store.export(library)
    }

    struct ImportSummary {
        /// Entries that couldn't be used and were left out.
        let skipped: [String]
        /// Imported actions that open apps, links or shortcuts, for the user to look over.
        let actionsToReview: [MappingStore.ReviewItem]
        /// The models whose setup the import replaced.
        let importedModels: [ModelKey]
        let format: MappingStore.ImportPreview.Format
        /// What the import replaced, for `undoImport`. Also backed up in UserDefaults.
        let previousLibrary: MappingLibrary
    }

    /// Reads an exported file without changing anything. A schema 3 file is imported model by
    /// model; a 2.x or 1.x file (made for the MX Vertical) goes to `targetModel`, by default the
    /// selected model. Throws `MappingStore.ImportError` when the file can't be used.
    func previewImport(_ data: Data, targetModel: ModelKey? = nil) throws -> MappingStore.ImportPreview {
        try store.prepareImport(data, targetModel: targetModel ?? selectedModel, protecting: protectedControls)
    }

    /// Applies a previewed import, after backing up the current library.
    @discardableResult
    func applyImport(_ preview: MappingStore.ImportPreview) -> ImportSummary {
        preview.skipped.forEach { logger.notice("Import: \($0, privacy: .public)") }
        let previous = library
        library = store.applyImport(preview, to: previous).library
        return ImportSummary(
            skipped: preview.skipped,
            actionsToReview: preview.actionsToReview,
            importedModels: preview.importedModels,
            format: preview.format,
            previousLibrary: previous
        )
    }

    /// `previewImport` then `applyImport`. Throws (and changes nothing) when the file can't be used.
    @discardableResult
    func importData(_ data: Data, targetModel: ModelKey? = nil) throws -> ImportSummary {
        applyImport(try previewImport(data, targetModel: targetModel))
    }

    /// Puts back what an import replaced.
    func undoImport(_ summary: ImportSummary) {
        library = summary.previousLibrary
    }

    /// Per model, the clicking buttons a connected mouse can't give up (flagged as mouse buttons
    /// and not divertable), which an import must never map.
    private var protectedControls: [ModelKey: Set<UInt16>] {
        var protected: [ModelKey: Set<UInt16>] = [:]
        for record in devices.records {
            guard let model = record.model, let snapshot = record.snapshot else { continue }
            let cids = snapshot.controls.filter { $0.isMouseButton && !$0.flags.contains(.divertable) }.map(\.cid)
            protected[model, default: []].formUnion(cids)
        }
        return protected
    }

    // MARK: Accessibility

    /// True when at least one mapping (any model, global or in an enabled app profile) needs Accessibility.
    var needsAccessibility: Bool {
        library.allActiveActions.contains { $0.requiresAccessibility }
    }

    var isMissingAccessibility: Bool {
        needsAccessibility && !permissions.isAccessibilityTrusted
    }

    // MARK: Gestures

    /// True when a button of `model` mapped to gestures right now can't report raw movement on
    /// that mouse, so gestures on it follow the cursor instead.
    func gesturesNeedRawXYFallback(model: ModelKey) -> Bool {
        effectiveMappings(model: model)
            .gestureControls(accessibilityGranted: permissions.isAccessibilityTrusted)
            .contains { !supportsRawXY($0, model: model) }
    }

    /// The same for one mouse.
    func gesturesNeedRawXYFallback(for address: DeviceAddress) -> Bool {
        effectiveMappings(for: address)
            .gestureControls(accessibilityGranted: permissions.isAccessibilityTrusted)
            .contains { !supportsRawXY($0, on: address) }
    }

    /// `gesturesNeedRawXYFallback(model:)` for the selected model.
    var gesturesNeedRawXYFallback: Bool {
        gesturesNeedRawXYFallback(model: selectedModel)
    }

    /// Whether a mouse can report raw movement for a control. Unknown (not identified) counts as yes.
    func supportsRawXY(_ cid: UInt16, on address: DeviceAddress) -> Bool {
        guard let snapshot = snapshot(of: address) else { return true }
        return snapshot.controls.first { $0.cid == cid }?.supportsRawXY ?? false
    }

    /// Whether a model's mouse (the selected one, else the first live one) can report raw
    /// movement for a control. No mouse of that model here counts as yes.
    func supportsRawXY(_ cid: UInt16, model: ModelKey) -> Bool {
        guard let address = representativeDevice(of: model) else { return true }
        return supportsRawXY(cid, on: address)
    }

    /// `supportsRawXY(_:model:)` for the selected model.
    func supportsRawXY(_ cid: UInt16) -> Bool {
        supportsRawXY(cid, model: selectedModel)
    }

    // MARK: Device actions

    /// Runs a device action (from a button or the UI) on one mouse. A set speed is remembered
    /// for that mouse; Cycle Pointer Speed's new speed is remembered when the mouse reports it.
    func perform(_ action: DeviceAction, on address: DeviceAddress) {
        if case .setDPI(let dpi) = action, action.isValid {
            storePreferredDPI(dpi, for: address)
        }
        devices.perform(action, on: address, presets: settings.dpiPresets)
    }

    // MARK: Routing

    private func handle(_ event: ButtonEvent) {
        if event.phase == .press {
            // DeviceManager drops presses of standby/unsupported endpoints; double-check.
            guard devices.isActive(event.source) else { return }
            focusedDevice = event.source
            lastPressedControl = PressedControl(cid: event.cid, source: event.source, model: model(of: event.source), date: Date())
        }
        engine.handle(event)
        updateMovementMonitor()
        // A button released after an app switch (or a role change) may have been kept diverted
        // only so this release arrived.
        if event.phase == .release, let applied = appliedConfig[event.source],
           applied.divert.contains(event.cid) || applied.rawXY.contains(event.cid) {
            resync(event.source)
        }
    }

    /// Watches cursor movement only while a gesture that follows the cursor is held (never in
    /// Demo Mode).
    private func updateMovementMonitor() {
        if environment.usesEventTaps, engine.needsCursorDeltas {
            movementMonitor.start()
        } else {
            movementMonitor.stop()
        }
    }

    private func frontmostAppDidChange(_ app: FrontmostApp?) {
        guard app != frontmostApp else { return }
        frontmostApp = app
        applyMappings()
    }

    private func applyMappings() {
        resyncAll()
    }

    // MARK: Configuration

    /// The hub asks when a mouse identifies, before anything is diverted. The registry hasn't
    /// seen it identify yet, so its role is the one it would get.
    private func pullConfiguration(for address: DeviceAddress, snapshot: DeviceSnapshot) -> EndpointConfiguration {
        let isActive = devices.prospectiveRole(address, snapshot: snapshot) == .active
        let configuration = configuration(for: address, snapshot: snapshot, isActive: isActive)
        appliedConfig[address] = configuration
        lastSnapshots[address] = snapshot
        return configuration
    }

    /// What one endpoint should be doing now.
    func configuration(for address: DeviceAddress, snapshot: DeviceSnapshot, isActive: Bool) -> EndpointConfiguration {
        let model = snapshot.identity?.model ?? snapshot.modelKey
        let prefs = preferences(for: address, snapshot: snapshot)
        let inputs = ConfigurationInputs(
            remappingEnabled: isRemappingEnabled,
            accessibilityGranted: permissions.isAccessibilityTrusted,
            deviceRemapEnabled: prefs.remapEnabled,
            isActive: isActive,
            preferredDPI: prefs.preferredDPI,
            held: engine.pressedControls(for: address),
            gesturesHeld: engine.gestureControls(for: address)
        )
        let mappings = library.effectiveMappings(model: model, bundleID: frontmostApp?.bundleID)
        return ConfigurationPlanner.configuration(mappings: mappings, snapshot: snapshot, inputs: inputs)
    }

    /// Pushes a changed configuration to one endpoint. Only identified endpoints (connected or
    /// asleep) are pushed; one that is still connecting pulls its own.
    private func resync(_ address: DeviceAddress) {
        guard let record = record(address), record.snapshot != nil, let snapshot = snapshot(of: address) else { return }
        let configuration = configuration(for: address, snapshot: snapshot, isActive: record.role == .active)
        guard appliedConfig[address] != configuration else { return }
        appliedConfig[address] = configuration
        devices.setConfiguration(configuration, for: address)
    }

    /// Recomputes every endpoint (app switch, mapping edit, Accessibility, remap switch,
    /// preferences, role changes).
    private func resyncAll() {
        updateMovementMonitor()
        for record in devices.records {
            resync(record.address)
        }
    }

    // MARK: Fleet changes

    private func devicesDidChange() {
        let records = devices.records
        for record in records {
            if let snapshot = record.snapshot { lastSnapshots[record.address] = snapshot }
        }
        rememberUnits(records)
        feedBatteryNotifier(records)
        updateSelection(records)
        resyncAll()
    }

    /// Endpoints that went away: end their holds, forget what they were told, note when they left.
    private func endpointsRemoved(_ addresses: [DeviceAddress]) {
        for address in addresses {
            engine.releaseAll(source: address)
            appliedConfig[address] = nil
            batteryReadings[address] = nil
            if let snapshot = lastSnapshots.removeValue(forKey: address),
               let id = snapshot.identity?.deviceID(at: address), id.isStable,
               settings.devicePreferences.devices[id] != nil {
                settings.devicePreferences.record(id, snapshot: snapshot)
            }
            if focusedDevice == address { focusedDevice = nil }
        }
        if environment.postsNotifications { batteryNotifier.endpointsRemoved(addresses) }
        updateMovementMonitor()
    }

    /// Records what was seen of each identified unit (name, controls, connection, time) when it
    /// first shows up or changes, for remembered mice and their controls while offline.
    private func rememberUnits(_ records: [DeviceRegistry.Record]) {
        var store = settings.devicePreferences
        for record in records where record.role != .unsupported {
            guard let snapshot = record.snapshot, let id = record.deviceID, id.isStable else { continue }
            let seen = RecordedUnit(
                name: snapshot.name,
                controls: snapshot.configurableControls.map(\.cid),
                connection: snapshot.connection
            )
            guard recordedUnits[id] != seen else { continue }
            recordedUnits[id] = seen
            store.record(id, snapshot: snapshot)
        }
        if store != settings.devicePreferences { settings.devicePreferences = store }
    }

    private func feedBatteryNotifier(_ records: [DeviceRegistry.Record]) {
        guard environment.postsNotifications else { return }
        for record in records where record.role != .unsupported {
            guard case .connected(let snapshot) = record.state, let battery = snapshot.battery,
                  batteryReadings[record.address] != battery
            else { continue }
            batteryReadings[record.address] = battery
            batteryNotifier.update(address: record.address, deviceID: record.deviceID, deviceName: record.displayName, battery: battery)
        }
        batteryNotifier.prune(keeping: Set(records.map(\.address)))
    }

    /// Keeps `selectedDevice` on a live mouse (the same unit on its new address, else the first
    /// connected one) and, until the user picks a model, `selectedModel` on its model.
    private func updateSelection(_ records: [DeviceRegistry.Record]) {
        isAdjustingSelection = true
        defer { isAdjustingSelection = false }

        if let selected = selectedDevice, let current = records.first(where: { $0.address == selected }) {
            if let id = current.deviceID { selectedDeviceID = id }
        } else if let id = selectedDeviceID, id.isStable,
                  let moved = records.first(where: { $0.deviceID == id && $0.role == .active }) ?? records.first(where: { $0.deviceID == id }) {
            selectedDevice = moved.address
        } else {
            // Gone: the first connected mouse, else nothing. The unit is still looked for when
            // nothing else is here, so it is selected again when it comes back.
            let unit = selectedDeviceID
            selectedDevice = primaryDevice
            if selectedDevice == nil { selectedDeviceID = unit }
        }

        if !modelWasChosen, let model = selectedDevice.flatMap(model(of:)), model != selectedModel {
            selectedModel = model
        }
    }

    private func unique(_ models: [ModelKey]) -> [ModelKey] {
        var seen = Set<ModelKey>()
        return models.filter { seen.insert($0).inserted }
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
        guard isRunning else { return }
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
