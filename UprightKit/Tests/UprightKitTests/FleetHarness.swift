import Foundation
import XCTest
@testable import UprightKit

/// The app's multi-mouse wiring (§C steps 2 and 5–11), built from the Kit's own parts: real
/// `HIDPPLink`s on simulated transports, `DeviceRegistry`, `ConfigurationPlanner`, a
/// `MappingLibrary`, `DevicePreferencesStore` and `RemapEngine`. It mirrors what DeviceManager
/// and AppModel do, minus IOKit and AppKit, so end-to-end routing can be tested on Linux.
///
/// - Each attached interface gets the next link number (never reused).
/// - The configuration of an endpoint is pulled when it identifies (before anything is diverted)
///   and pushed again whenever something it depends on changes: the frontmost app, the mappings,
///   preferences, a role change in the registry, or the release of one of its buttons.
/// - Presses from endpoints that aren't active (standby twins, pending, unsupported) are dropped.
///   Releases and raw movement always reach the engine, which only applies them to holds the
///   same endpoint started while it was active; dropping them could leave an effect stuck down
///   when an endpoint loses the active role mid-hold.
/// - A removed endpoint's holds are released (`engine.releaseAll(source:)`) and its record goes.
/// - Pointer-speed changes made on a mouse (or by Cycle Pointer Speed) are stored for that unit
///   only; nothing is broadcast to other mice.
@MainActor
final class FleetHarness {
    let registry = DeviceRegistry()
    let performer: BalanceCheckingPerformer
    let engine: RemapEngine
    let tuning: ControllerTuning

    var library: MappingLibrary {
        didSet { if library != oldValue { resyncAll() } }
    }
    var frontmostBundleID: String? {
        didSet { if frontmostBundleID != oldValue { resyncAll() } }
    }
    var preferences = DevicePreferencesStore() {
        didSet { if preferences != oldValue { resyncAll() } }
    }
    var remappingEnabled = true {
        didSet { if remappingEnabled != oldValue { resyncAll() } }
    }
    var accessibilityGranted = true {
        didSet { if accessibilityGranted != oldValue { resyncAll() } }
    }
    /// The global presets Cycle Pointer Speed steps through.
    var dpiPresets: [Int] = []

    /// Open hubs by link number.
    private(set) var links: [UInt32: HIDPPLink] = [:]
    /// The simulator behind every hub ever attached, by link number (kept after it closes).
    private(set) var simulators: [UInt32: SimulatedHIDPPTransport] = [:]
    /// What was last handed to each endpoint, by address.
    private(set) var appliedConfig: [DeviceAddress: EndpointConfiguration] = [:]
    /// Every button event a hub delivered, in order, including dropped ones.
    private(set) var events: [ButtonEvent] = []
    /// Presses dropped because their endpoint wasn't active.
    private(set) var droppedPresses: [ButtonEvent] = []
    /// `HIDPPLink.onDeviceDPIChange` notifications, in order.
    private(set) var deviceDPIChanges: [(address: DeviceAddress, dpi: Int?)] = []
    private(set) var removals: [(address: DeviceAddress, reason: HIDPPLink.RemovalReason)] = []
    /// Device actions the engine fired, with the device that fired them.
    private(set) var deviceActions: [(action: DeviceAction, source: DeviceAddress)] = []
    /// The last device that sent a press that was handled.
    private(set) var focusedDevice: DeviceAddress?
    /// Bumped by every hub callback; with the simulators' traffic it tells `settle()` when
    /// things have stopped moving.
    private(set) var activity = 0
    /// Every hub log line, prefixed with its address (when `keepsLog`).
    private(set) var log: [String] = []
    var keepsLog = false

    private var nextLink: UInt32 = 1

    init(library: MappingLibrary = MappingLibrary(), tuning: ControllerTuning = .fastTests) {
        let performer = BalanceCheckingPerformer()
        self.performer = performer
        self.library = library
        self.tuning = tuning
        engine = RemapEngine(mappings: ButtonMappings(), performer: performer)
        engine.mappingsProvider = { [weak self] source in
            guard let self else { return ButtonMappings() }
            return self.library.effectiveMappings(model: self.model(of: source), bundleID: self.frontmostBundleID)
        }
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
        registry.onChange = { [weak self] in
            self?.activity += 1
            self?.resyncAll()
        }
    }

    // MARK: Interfaces

    /// Opens a hub on `simulator` with the next link number and starts it (DeviceManager.attach).
    @discardableResult
    func attach(_ simulator: SimulatedHIDPPTransport, start: Bool = true) -> HIDPPLink {
        let number = nextLink
        nextLink += 1
        let direct = simulator as? SimulatedDirect
        let hub = HIDPPLink(
            transport: simulator,
            kind: simulator.transportKind,
            link: number,
            tuning: tuning,
            productID: direct?.productID ?? (simulator as? SimulatedReceiver)?.productID,
            productName: direct?.profile.name
        )
        hub.client.defaultTimeout = tuning.probeTimeout
        hub.client.busyRetryDelay = 0.01
        let connection = simulator.transportKind.connection

        hub.configurationProvider = { [weak self] address, snapshot in
            guard let self else { return .native }
            let role = self.registry.prospectiveRole(address, snapshot: snapshot)
            let configuration = self.configuration(for: address, snapshot: snapshot, isActive: role == .active)
            self.appliedConfig[address] = configuration
            return configuration
        }
        hub.onEndpointChange = { [weak self] address, state in
            guard let self else { return }
            self.activity += 1
            self.registry.update(address, connection: connection, state: state)
        }
        hub.onEndpointRemoved = { [weak self] address, reason in
            guard let self else { return }
            self.activity += 1
            self.removals.append((address, reason))
            self.engine.releaseAll(source: address)
            self.appliedConfig[address] = nil
            self.registry.remove(address)
        }
        hub.onButtonEvent = { [weak self] event in self?.handle(event) }
        hub.onPointerDelta = { [weak self] delta in
            self?.activity += 1
            self?.engine.handlePointerDelta(delta)
        }
        hub.onDeviceDPIChange = { [weak self] address, dpi in self?.deviceDidChangeDPI(address, dpi) }
        hub.onLog = { [weak self] address, text in
            guard let self else { return }
            self.activity += 1
            if self.keepsLog { self.log.append("[\(address?.description ?? "link \(number)")] \(text)") }
        }

        links[number] = hub
        simulators[number] = simulator
        if start { hub.start() }
        return hub
    }

    /// Unplugs the interface (the IOHIDDevice goes away) and waits until the hub has closed and
    /// dropped every endpoint.
    func detach(_ link: UInt32, file: StaticString = #filePath, line: UInt = #line) async {
        guard let hub = links[link] else { return }
        simulators[link]?.disconnect()
        await eventually("link \(link) closed", file: file, line: line) { hub.isClosed && hub.endpoints.isEmpty }
        forgetClosedLinks()
    }

    /// Drops hubs whose transport closed on its own, and any record they left behind.
    func forgetClosedLinks() {
        for (number, hub) in links.sorted(by: { $0.key < $1.key }) where hub.isClosed && hub.endpoints.isEmpty {
            links[number] = nil
            registry.removeLink(number)
        }
    }

    /// Hands every mouse's buttons back and closes every hub (quitting the app).
    func shutdown() {
        for number in links.keys.sorted() {
            links[number]?.shutdown()
        }
        forgetClosedLinks()
    }

    // MARK: Lookups

    func address(link: UInt32, index: UInt8) -> DeviceAddress {
        DeviceAddress(link: link, index: index)
    }

    func endpoint(_ address: DeviceAddress) -> EndpointController? {
        links[address.link]?.endpoints[address.index]
    }

    /// The live snapshot of the endpoint at `address` (identified, connected or asleep).
    func snapshot(of address: DeviceAddress) -> DeviceSnapshot? {
        endpoint(address)?.snapshot
    }

    func isConnected(_ address: DeviceAddress) -> Bool {
        if case .connected = endpoint(address)?.state { return true }
        return false
    }

    func model(of address: DeviceAddress) -> ModelKey? {
        registry.record(address)?.model ?? snapshot(of: address)?.modelKey
    }

    /// The stable unit ID of the endpoint at `address`, if it has one.
    func deviceID(of address: DeviceAddress) -> DeviceID? {
        guard let id = snapshot(of: address)?.identity?.deviceID(at: address), id.isStable else { return nil }
        return id
    }

    // MARK: Driving

    /// Re-reads battery, pointer speed and channel on every mouse (the menu opening).
    func refreshDeviceInfo() {
        for number in links.keys.sorted() {
            links[number]?.refreshDeviceInfo(at: nil)
        }
    }

    /// The Mac woke from sleep.
    func refreshAll() {
        for number in links.keys.sorted() {
            links[number]?.refresh()
        }
    }

    /// Waits until every hub has finished its queued work.
    func waitUntilIdle() async {
        for number in links.keys.sorted() {
            await links[number]?.waitUntilIdle()
        }
    }

    /// Waits until nothing has happened for `quietPolls` consecutive polls: no hub callback and
    /// no request sent. Unlike `waitUntilIdle()` it doesn't wait out requests nobody answers.
    func settle(quietPolls: Int = 3, pollInterval: TimeInterval = 0.001, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = activityStamp
        var quiet = 0
        while quiet < quietPolls, Date() < deadline {
            await pause(pollInterval)
            let now = activityStamp
            if now == last {
                quiet += 1
            } else {
                quiet = 0
                last = now
            }
        }
    }

    private var activityStamp: Int {
        simulators.values.reduce(activity) { $0 + $1.sentReports.count }
    }

    // MARK: Configuration (AppModel)

    /// What the endpoint at `address` should be doing now (§C step 5 and 9).
    func configuration(for address: DeviceAddress, snapshot: DeviceSnapshot, isActive: Bool) -> EndpointConfiguration {
        let model = snapshot.identity?.model ?? snapshot.modelKey
        let id = snapshot.identity?.deviceID(at: address) ?? .transient(address)
        let prefs = preferences.preferences(for: id, model: model)
        let inputs = ConfigurationInputs(
            remappingEnabled: remappingEnabled,
            accessibilityGranted: accessibilityGranted,
            deviceRemapEnabled: prefs.remapEnabled,
            isActive: isActive,
            preferredDPI: prefs.preferredDPI,
            held: engine.pressedControls(for: address),
            gesturesHeld: engine.gestureControls(for: address)
        )
        let mappings = library.effectiveMappings(model: model, bundleID: frontmostBundleID)
        return ConfigurationPlanner.configuration(mappings: mappings, snapshot: snapshot, inputs: inputs)
    }

    /// Pushes a changed configuration to one endpoint. Only endpoints the registry has seen
    /// identify (connected or asleep) are pushed; one that is still connecting pulls its own.
    func resync(_ address: DeviceAddress) {
        guard let record = registry.record(address), record.snapshot != nil,
              let link = links[address.link], let snapshot = link.endpoints[address.index]?.snapshot
        else { return }
        let configuration = configuration(for: address, snapshot: snapshot, isActive: record.role == .active)
        guard appliedConfig[address] != configuration else { return }
        appliedConfig[address] = configuration
        link.setConfiguration(configuration, at: address.index)
    }

    func resyncAll() {
        for record in registry.records {
            resync(record.address)
        }
    }

    // MARK: Events (DeviceManager + AppModel)

    private func handle(_ event: ButtonEvent) {
        activity += 1
        events.append(event)
        if event.phase == .press {
            guard registry.isActive(event.source) else {
                droppedPresses.append(event)
                return
            }
            focusedDevice = event.source
        }
        engine.handle(event)
        // A release may end a keep-alive diversion (held across an app switch or a role change).
        if event.phase == .release { resync(event.source) }
    }

    /// DeviceManager.perform(_:on:presets:).
    private func perform(_ action: DeviceAction, on source: DeviceAddress) {
        activity += 1
        deviceActions.append((action, source))
        guard let link = links[source.link] else { return }
        switch action {
        case .cycleDPI:
            link.cycleDPI(at: source.index, presets: dpiPresets)
        case .setDPI(let dpi):
            // Stored first, so the resync it causes asks for the same speed.
            storePreferredDPI(dpi, for: source)
            link.setDPI(dpi, at: source.index)
        case .switchHost(let host):
            link.switchToHost(host - 1, at: source.index)
        }
    }

    /// A speed chosen on the mouse (or stepped by Cycle Pointer Speed) becomes that unit's own
    /// preference. The endpoint's snapshot is used, not the registry: during a connect the
    /// change arrives before the registry has seen the endpoint identify.
    private func deviceDidChangeDPI(_ address: DeviceAddress, _ dpi: Int?) {
        activity += 1
        deviceDPIChanges.append((address, dpi))
        storePreferredDPI(dpi, for: address)
    }

    private func storePreferredDPI(_ dpi: Int?, for address: DeviceAddress) {
        guard let id = deviceID(of: address), let model = snapshot(of: address)?.modelKey else { return }
        var prefs = preferences.preferences(for: id, model: model)
        guard prefs.preferredDPI != dpi else { return }
        prefs.preferredDPI = dpi
        preferences.setPreferences(prefs, for: id)
    }
}

/// Records what the engine performs and checks it as it happens: an effect that tracks its
/// button goes up exactly once per down, and one that doesn't never goes up.
@MainActor
final class BalanceCheckingPerformer: ActionPerforming {
    struct Entry: Hashable {
        var effect: ActionEffect
        var phase: ActionPhase
    }

    private(set) var log: [Entry] = []
    /// Downs not yet matched by an up, per effect (tracking effects only).
    private(set) var outstanding: [ActionEffect: Int] = [:]
    /// Ups without a down, and ups of effects that don't track their button.
    private(set) var violations: [String] = []

    func perform(_ effect: ActionEffect, phase: ActionPhase) {
        log.append(Entry(effect: effect, phase: phase))
        guard effect.tracksButtonState else {
            if phase == .up { violations.append("up for an effect without a held state: \(effect)") }
            return
        }
        switch phase {
        case .down:
            outstanding[effect, default: 0] += 1
        case .up:
            let count = outstanding[effect, default: 0] - 1
            if count < 0 { violations.append("up without a down: \(effect)") }
            outstanding[effect] = count == 0 ? nil : count
        }
    }

    /// Effects still down (or driven negative), by count.
    var stuck: [ActionEffect: Int] { outstanding.filter { $0.value != 0 } }

    func count(_ effect: ActionEffect, _ phase: ActionPhase) -> Int {
        log.filter { $0.effect == effect && $0.phase == phase }.count
    }

    func removeAll() {
        log.removeAll()
    }
}
