import AppKit

/// Opens every supported Logitech HID interface a `LinkSource` reports (IOKit by default, the
/// simulator in Demo Mode), runs one `HIDPPLink` per interface, and publishes every mouse on
/// them as a `DeviceRegistry.Record` (§B11, §C steps 2, 6, 7, 11 and 12).
///
/// - Events: button events and raw movement carry their `DeviceAddress`. Presses and movement
///   from endpoints that aren't active (standby twins, unidentified or unsupported devices) are
///   dropped; a release always follows a press that was delivered.
/// - Configuration is pulled: a link asks `configurationProvider` right after a mouse identifies,
///   before anything is diverted. AppModel pushes later changes with `setConfiguration(_:for:)`.
/// - Recovery is per interface: a link whose mouse stops answering is re-opened on its own (a
///   few times, with backoff); when no other interface has a mouse, the source is restarted, as
///   Upright always did. Unsupported devices never trigger it.
/// - The activity log labels every line with its device: "MX Master 3S · Bolt slot 2: …".
@MainActor
final class DeviceManager: ObservableObject {
    enum Status: Equatable {
        case searching
        case accessDenied
        case probing(ConnectionKind)
        case waiting(ConnectionKind)
        case connected(DeviceSnapshot)
        case asleep(DeviceSnapshot)
        case failed(String)
    }

    typealias LogEntry = DeviceActivityLog.Entry

    /// Every endpoint: pointers first by first-seen order, unsupported devices last.
    @Published private(set) var records: [DeviceRegistry.Record] = []
    @Published private(set) var summary = FleetSummary()
    /// Names of the interfaces macOS refused to open (Input Monitoring).
    @Published private(set) var blockedInterfaces: [String] = []
    /// The activity log, observed on its own so a new line doesn't re-render every view of the fleet.
    let activity = DeviceActivityLog()
    /// Raw HID++ traffic is only formatted (and its handler installed) while this is on.
    @Published var logsTraffic = false {
        didSet {
            guard logsTraffic != oldValue else { return }
            entries.values.forEach { installTrafficLogging(on: $0.link) }
        }
    }

    var needsInputMonitoring: Bool { !blockedInterfaces.isEmpty }

    /// Asked synchronously when a mouse identifies, before anything is diverted. Only active
    /// endpoints are asked (see `prospectiveRole`); others get `.native`. Nil means `.native`.
    var configurationProvider: (@MainActor (DeviceAddress, DeviceSnapshot) -> EndpointConfiguration)?
    var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw movement from a held raw-XY control, stamped with its device.
    var onPointerDelta: ((PointerDelta) -> Void)?
    /// Endpoints that went away (their held buttons were released first). Addresses are never reused.
    var onEndpointsRemoved: (([DeviceAddress]) -> Void)?
    /// The pointer speed one mouse keeps changed without the app asking (its own DPI button, or
    /// Cycle Pointer Speed). Only that mouse; nothing is broadcast.
    var onDeviceDPIChange: ((DeviceAddress, Int?) -> Void)?
    /// Nicknames by device ID (`DevicePreferences.nickname`). Call `refreshNames()` after one changes.
    var nameProvider: ((DeviceID) -> String?)? {
        get { registry.nameProvider }
        set {
            registry.nameProvider = newValue
            registry.refreshNames()
        }
    }
    /// The controls last seen on a model (`DevicePreferences.lastControls`), for
    /// `controls(for:address:)` while no mouse of that model is connected.
    var rememberedControls: ((ModelKey) -> [UInt16]?)?

    private struct Entry {
        let interface: LinkInterface
        let transport: HIDPPTransport
        let link: HIDPPLink
    }

    private let source: LinkSource
    private let registry = DeviceRegistry()
    private let tuning: ControllerTuning
    private var entries: [AnyHashable: Entry] = [:]
    private var linkIDs: [UInt32: AnyHashable] = [:]
    private var nextLink: UInt32 = 1
    /// Interfaces macOS refused, by interface ID.
    private var blocked: [AnyHashable: String] = [:]
    /// Watching as a whole was refused and nothing could be opened.
    private var watchingDenied = false
    /// Presses delivered to `onButtonEvent` and not released yet.
    private var deliveredPresses: Set<ControlKey> = []
    /// Recovery state by interface identity, so it survives re-matching an interface.
    private var recoveryAttempts: [String: Int] = [:]
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private static let maxRecoveries = 3

    /// `source` nil: the simulated fleet in Demo Mode, otherwise IOKit.
    init(source: LinkSource? = nil, tuning: ControllerTuning = .init()) {
        self.source = source ?? (DemoMode.isActive ? SimulatedLinkSource.demo() : IOKitLinkSource())
        self.tuning = tuning
        registry.onChange = { [weak self] in self?.refreshPublished() }
    }

    func start() {
        guard !started else { return }
        started = true
        source.onMatch = { [weak self] interface in self?.attach(interface) }
        source.onRemove = { [weak self] id in self?.interfaceRemoved(id) }
        source.onIgnored = { [weak self] descriptor, reason in
            self?.append(String(localized: "Ignoring \(descriptor.summary): \(reason)"))
        }
        append(source.watchingDescription)
        startSource()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActorDelivery.run { self?.systemDidWake() }
            })
        }
        refreshPublished()
    }

    /// Hands every mouse's buttons back. Called when the app quits.
    func shutdown() {
        recoveryTasks.values.forEach { $0.cancel() }
        recoveryTasks.removeAll()
        entries.values.forEach { $0.link.shutdown() }
    }

    // MARK: Queries

    func snapshot(_ a: DeviceAddress) -> DeviceSnapshot? {
        registry.record(a)?.snapshot
    }

    func record(_ a: DeviceAddress) -> DeviceRegistry.Record? {
        registry.record(a)
    }

    /// False for standby, unsupported and unidentified endpoints.
    func isActive(_ a: DeviceAddress) -> Bool {
        registry.isActive(a)
    }

    /// The role an endpoint that is identifying right now will get; for a configuration provider,
    /// which is asked before the endpoint's record says it is connected.
    func prospectiveRole(_ a: DeviceAddress, snapshot: DeviceSnapshot) -> DeviceRegistry.Role {
        registry.prospectiveRole(a, snapshot: snapshot)
    }

    func refreshNames() {
        registry.refreshNames()
    }

    /// The controls of `model`, in display order: what a connected mouse of that model reports
    /// (the one at `address` first), else what one reported last time (`rememberedControls`),
    /// else the catalog's list.
    func controls(for model: ModelKey, address: DeviceAddress?) -> [ControlDescriptor] {
        func reported(_ record: DeviceRegistry.Record?) -> [UInt16]? {
            guard let record, record.role != .unsupported, record.model == model, let snapshot = record.snapshot else { return nil }
            return snapshot.configurableControls.map(\.cid)
        }
        let cids = reported(address.flatMap(registry.record))
            ?? registry.records.lazy.compactMap(reported).first
            ?? rememberedControls?(model).flatMap { $0.isEmpty ? nil : $0 }
            ?? DeviceCatalog.model(model)?.controlOrder
            ?? []
        return DeviceCatalog.sortedControls(cids, for: model).map { ControlDescriptor(cid: $0, model: model) }
    }

    /// The device the single-mouse UI shows: the first active connected mouse, else the first
    /// active one that is asleep, else the first that isn't unsupported.
    var primaryAddress: DeviceAddress? {
        let active = records.filter { $0.role == .active }
        return active.first(where: \.isConnected)?.address
            ?? active.first(where: { $0.snapshot != nil })?.address
            ?? records.first(where: { $0.role != .unsupported })?.address
    }

    // MARK: Per-device actions

    /// Runs a device action on one mouse. `.unassigned` means the primary mouse.
    func perform(_ action: DeviceAction, on a: DeviceAddress, presets: [Int]) {
        guard action.isValid else {
            append(String(localized: "Ignoring invalid device action: \(action.title)"), address: a)
            return
        }
        switch action {
        case .cycleDPI:
            guard let (link, address) = serving(a, for: action.title) else { return }
            link.cycleDPI(at: address.index, presets: presets)
        case .setDPI(let dpi):
            setDPI(dpi, on: a)
        case .switchHost(let host):
            switchToHost(host - 1, on: a)
        }
    }

    /// Sets the pointer speed of one mouse (snapped to what it supports) and keeps it across
    /// reconnects; nil stops keeping one and leaves the mouse's own setting alone. A speed chosen
    /// here is not reported through `onDeviceDPIChange`: the caller already knows it.
    func setDPI(_ dpi: Int?, on a: DeviceAddress) {
        guard let (link, address) = serving(a, for: String(localized: "Pointer Speed")) else { return }
        link.setDPI(dpi, at: address.index)
        refreshDesiredDPI()
    }

    /// Easy-Switch one mouse to a zero-based channel. It disconnects from this Mac right away.
    func switchToHost(_ host: Int, on a: DeviceAddress) {
        guard let (link, address) = serving(a, for: String(localized: "Easy-Switch")) else { return }
        link.switchToHost(host, at: address.index)
    }

    func setConfiguration(_ c: EndpointConfiguration, for a: DeviceAddress) {
        guard let link = link(of: a) else { return }
        link.setConfiguration(c, at: a.index)
        refreshDesiredDPI()
    }

    /// Identifies one mouse again; nil drops every interface and matches them again
    /// (Reconnect All). A Bluetooth re-pair keeps the serial, but the old interface stops answering.
    func reconnect(_ a: DeviceAddress? = nil) {
        guard let a else {
            append(String(localized: "Reconnecting all devices"))
            recoveryAttempts.removeAll()
            restartSource()
            return
        }
        guard let id = linkIDs[a.link], let entry = entries[id] else { return }
        append(String(localized: "Reconnecting"), address: a)
        recoveryAttempts[entry.interface.identityKey] = nil
        entry.link.reconnect(index: a.index)
    }

    /// Re-reads battery, pointer speed and Easy-Switch channel (e.g. when the menu opens): one
    /// mouse, or all. A mouse's DPI button changes the speed without telling us.
    func refreshDeviceInfo(_ a: DeviceAddress? = nil) {
        if let a {
            link(of: a)?.refreshDeviceInfo(at: a.index)
        } else {
            orderedEntries.forEach { $0.link.refreshDeviceInfo(at: nil) }
        }
    }

    /// Shows the Input Monitoring prompt the first time (macOS only asks once) and reconnects
    /// when access is granted. Meant for an explicit button in the UI. Returns whether access
    /// is granted; when it isn't, the caller should point the user to System Settings.
    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        let granted = source.requestInputMonitoringAccess()
        if granted, needsInputMonitoring || entries.isEmpty {
            reconnect(nil)
        }
        return granted
    }

    /// After the Mac wakes (also called by Demo Mode): re-applies every mouse's configuration;
    /// receivers re-assert their notification flags.
    func systemDidWake() {
        guard !entries.isEmpty else { return }
        append(String(localized: "Mac woke up; reapplying button configuration"))
        orderedEntries.forEach { $0.link.refresh() }
    }

    // MARK: Source and interfaces

    private func startSource() {
        watchingDenied = false
        do {
            try source.start()
        } catch let error as LinkSourceError {
            append(error.message)
            if error.isPermissionDenied, entries.isEmpty { watchingDenied = true }
        } catch {
            append("\(error)")
        }
        refreshBlocked()
    }

    private func restartSource() {
        recoveryTasks.values.forEach { $0.cancel() }
        recoveryTasks.removeAll()
        for id in orderedEntries.map(\.interface.id) {
            detach(id, removed: false)
        }
        source.stop()
        blocked.removeAll()
        startSource()
        refreshPublished()
    }

    private func attach(_ interface: LinkInterface) {
        let id = interface.id
        guard entries[id] == nil else { return }
        guard let superseded = InterfaceClassifier.twinsToReplace(adding: interface.descriptor, open: entries.mapValues(\.interface.descriptor)) else { return }
        superseded.forEach { detach($0, removed: false) }

        append(String(localized: "Found \(interface.descriptor.summary)"))
        let transport: HIDPPTransport
        do {
            transport = try source.open(interface)
        } catch {
            let failure = error as? LinkSourceError ?? .failed("\(error)")
            append(failure.message)
            if failure.isPermissionDenied { blocked[id] = interface.name }
            refreshBlocked()
            refreshStatus()
            return
        }
        blocked[id] = nil
        // Something opened, so watching works after all; refusals stay per interface.
        watchingDenied = false
        refreshBlocked()

        let number = nextLink
        nextLink += 1
        let link = HIDPPLink(
            transport: transport,
            kind: interface.kind,
            link: number,
            tuning: tuning,
            productID: interface.productID,
            productName: interface.descriptor.productName.isEmpty ? nil : interface.descriptor.productName
        )
        entries[id] = Entry(interface: interface, transport: transport, link: link)
        linkIDs[number] = id
        wire(link)
        link.start()
        refreshPublished()
    }

    private func interfaceRemoved(_ id: AnyHashable) {
        let wasBlocked = blocked.removeValue(forKey: id) != nil
        detach(id, removed: true)
        if wasBlocked { refreshBlocked() }
    }

    /// `removed` is true when the source reported the interface gone; otherwise it is still
    /// present and is closed.
    private func detach(_ id: AnyHashable, removed: Bool) {
        guard let entry = entries[id] else { return }
        let link = entry.link
        let number = link.link
        append(removed ? String(localized: "\(entry.interface.name) was disconnected") : String(localized: "Closing \(entry.interface.name)"), link: number)
        entries[id] = nil
        linkIDs[number] = nil
        // A closing link must not drive status, configuration or recovery any more.
        link.configurationProvider = nil
        link.onEndpointChange = nil
        link.onEndpointRemoved = nil
        link.onDeviceDPIChange = nil
        link.onDiscoveryChange = nil
        link.client.onTraffic = nil
        // Releases held buttons (still delivered through onButtonEvent) and hands buttons back.
        link.shutdown()
        link.onButtonEvent = nil
        link.onPointerDelta = nil
        link.onLog = nil
        source.close(entry.interface, transport: entry.transport, removed: removed)

        let gone = registry.removeLink(number)
        endpointsRemoved(gone)
        refreshPublished()
    }

    private var orderedEntries: [Entry] {
        entries.values.sorted { $0.link.link < $1.link.link }
    }

    private func link(of a: DeviceAddress) -> HIDPPLink? {
        linkIDs[a.link].flatMap { entries[$0] }?.link
    }

    /// The link serving `a` (`.unassigned`: the primary mouse), or nil after logging why not.
    private func serving(_ a: DeviceAddress, for action: String) -> (HIDPPLink, DeviceAddress)? {
        let address = a == .unassigned ? primaryAddress : a
        guard let address, let link = link(of: address), link.endpoints[address.index] != nil else {
            append(String(localized: "\(action): no mouse is connected"), address: a == .unassigned ? nil : a)
            return nil
        }
        return (link, address)
    }

    // MARK: Hub callbacks

    private func wire(_ link: HIDPPLink) {
        let number = link.link
        link.configurationProvider = { [weak self] address, snapshot in
            self?.configuration(for: address, snapshot: snapshot) ?? .native
        }
        link.onEndpointChange = { [weak self, weak link] address, state in
            guard let self, let link else { return }
            self.endpoint(address, on: link, didChangeTo: state)
        }
        link.onEndpointRemoved = { [weak self] address, _ in
            guard let self else { return }
            self.registry.remove(address)
            self.endpointsRemoved([address])
        }
        link.onButtonEvent = { [weak self] event in self?.deliver(event) }
        link.onPointerDelta = { [weak self] delta in self?.deliver(delta) }
        link.onDeviceDPIChange = { [weak self] address, dpi in
            guard let self else { return }
            self.refreshDesiredDPI()
            self.onDeviceDPIChange?(address, dpi)
        }
        link.onLog = { [weak self] address, text in self?.append(text, link: number, address: address) }
        // Only a receiver without mice reports discovery in `status`.
        link.onDiscoveryChange = { [weak self] in self?.refreshStatus() }
        installTrafficLogging(on: link)
    }

    private func configuration(for address: DeviceAddress, snapshot: DeviceSnapshot) -> EndpointConfiguration {
        // A standby twin stays native; held buttons can't exist on a session that just started.
        guard registry.prospectiveRole(address, snapshot: snapshot) == .active else { return .native }
        return configurationProvider?(address, snapshot) ?? .native
    }

    private func endpoint(_ address: DeviceAddress, on link: HIDPPLink, didChangeTo state: EndpointController.State) {
        guard !link.isShutDown, linkIDs[link.link] != nil else { return }
        registry.update(address, connection: link.kind.connection, state: state)
        refreshStatus()
        guard !link.isClosed, let id = linkIDs[link.link], let entry = entries[id] else { return }
        switch state {
        case .connected:
            recoveryAttempts[entry.interface.identityKey] = nil
        case .failed:
            scheduleRecovery(of: entry)
        case .waitingForDevice:
            // A directly connected mouse that doesn't answer is often a dead pre-repair interface.
            if case .direct = link.kind { scheduleRecovery(of: entry) }
        case .probing, .asleep, .unsupported:
            break
        }
    }

    private func endpointsRemoved(_ addresses: [DeviceAddress]) {
        guard !addresses.isEmpty else { return }
        let gone = Set(addresses)
        deliveredPresses = deliveredPresses.filter { !gone.contains($0.source) }
        onEndpointsRemoved?(addresses)
    }

    private func deliver(_ event: ButtonEvent) {
        let key = ControlKey(source: event.source, cid: event.cid)
        switch event.phase {
        case .press:
            guard registry.isActive(event.source) else { return }
            deliveredPresses.insert(key)
        case .release:
            guard deliveredPresses.remove(key) != nil || registry.isActive(event.source) else { return }
        }
        onButtonEvent?(event)
    }

    private func deliver(_ delta: PointerDelta) {
        guard registry.isActive(delta.source) || deliveredPresses.contains(where: { $0.source == delta.source }) else { return }
        onPointerDelta?(delta)
    }

    private func installTrafficLogging(on link: HIDPPLink) {
        guard logsTraffic else {
            link.client.onTraffic = nil
            return
        }
        let number = link.link
        link.client.onTraffic = { [weak self] direction, bytes in
            MainActorDelivery.run {
                guard let self, self.logsTraffic else { return }
                let line = (direction == .outgoing ? "→ " : "← ") + bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                self.append(line, isTraffic: true, link: number)
            }
        }
    }

    // MARK: Recovery

    /// The open interface can be the pre-repair device; matching again picks up the live one.
    /// Endpoints keep retrying on their own; this only re-opens an interface a few times.
    private func scheduleRecovery(of entry: Entry) {
        let key = entry.interface.identityKey
        let attempts = recoveryAttempts[key, default: 0]
        guard recoveryTasks[key] == nil, attempts < Self.maxRecoveries else { return }
        recoveryAttempts[key] = attempts + 1
        let delay = UInt64(attempts + 1) * 700_000_000
        append(String(localized: "HID++ did not answer; looking for the device again"), link: entry.link.link)
        recoveryTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.recoveryTasks[key] = nil
            self.recover(key)
        }
    }

    private func recover(_ key: String) {
        // Gone: the source reports it again when it comes back.
        guard let entry = orderedEntries.first(where: { $0.interface.identityKey == key }) else { return }
        guard !entry.link.endpoints.values.contains(where: { Self.isConnected($0.state) }) else { return }
        let othersPresent = entries.values.contains { other in
            other.link !== entry.link && other.link.endpoints.values.contains { Self.isPresent($0.state) }
        }
        if othersPresent {
            // Other mice are working: re-open only this interface.
            let interface = entry.interface
            detach(interface.id, removed: false)
            attach(interface)
        } else {
            restartSource()
        }
    }

    // MARK: Published state

    private func refreshPublished() {
        let newRecords = registry.records
        if newRecords != records { records = newRecords }
        let newSummary = registry.summary
        if newSummary != summary { summary = newSummary }
        refreshStatus()
        refreshDesiredDPI()
    }

    private func refreshBlocked() {
        var names = blocked.values.sorted()
        if watchingDenied && names.isEmpty {
            names = [String(localized: "Logitech HID devices")]
        }
        if names != blockedInterfaces { blockedInterfaces = names }
        refreshStatus()
    }

    private func refreshStatus() {
        let new = computeStatus()
        if new != status { status = new }
    }

    private func computeStatus() -> Status {
        if let primary = records.first(where: { $0.role == .active && $0.isConnected }), let snapshot = primary.snapshot {
            return .connected(snapshot)
        }
        var best: (rank: Int, status: Status)?
        func consider(_ rank: Int, _ status: Status) {
            if rank > (best?.rank ?? 0) { best = (rank, status) }
        }
        for record in records where record.role != .unsupported {
            switch record.state {
            case .connected(let snapshot): consider(5, .connected(snapshot))
            case .asleep(let snapshot): consider(4, .asleep(snapshot))
            case .probing: consider(3, .probing(record.connection))
            case .waitingForDevice: consider(2, .waiting(record.connection))
            case .failed(let message): consider(1, .failed(message))
            case .unsupported: break
            }
        }
        // A receiver that serves no mouse (yet): still discovering, or waiting for one to wake.
        for entry in orderedEntries where !entry.link.isClosed {
            let served = entry.link.endpoints.values.contains { !$0.isUnsupported }
            let isReceiver = { if case .receiver = entry.link.kind { return true } else { return false } }()
            guard !served, isReceiver || entry.link.endpoints.isEmpty else { continue }
            let connection = entry.link.kind.connection
            if entry.link.isDiscovering {
                consider(3, .probing(connection))
            } else {
                consider(2, .waiting(connection))
            }
        }
        if let best { return best.status }
        return needsInputMonitoring ? .accessDenied : .searching
    }

    private static func isConnected(_ state: EndpointController.State) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private static func isPresent(_ state: EndpointController.State) -> Bool {
        switch state {
        case .connected, .asleep: return true
        default: return false
        }
    }

    // MARK: Log

    private func append(_ text: String, isTraffic: Bool = false, link: UInt32? = nil, address: DeviceAddress? = nil) {
        let number = link ?? address?.link
        let label: String?
        if let address, address != .unassigned {
            label = deviceLabel(address)
        } else if let number {
            label = linkLabel(number)
        } else {
            label = nil
        }
        activity.append(
            text: label.map { "\($0): \(text)" } ?? text,
            isTraffic: isTraffic,
            address: address == .unassigned ? nil : address,
            link: number
        )
    }

    private func entry(forLink number: UInt32) -> Entry? {
        linkIDs[number].flatMap { entries[$0] }
    }

    /// "MX Master 3S · Bolt slot 2", "MX Vertical · Bluetooth".
    private func deviceLabel(_ a: DeviceAddress) -> String {
        let entry = entry(forLink: a.link)
        let record = registry.record(a)
        let name: String
        if let record, record.deviceID != nil || record.model != nil {
            // Nickname or catalog name, numbered when two mice share it.
            name = record.displayName
        } else if let endpoint = entry?.link.endpoints[a.index] {
            // Not in the registry yet (identifying): what the device said, else its product ID.
            let identified = endpoint.snapshot.map { snapshot in
                snapshot.identity.flatMap { DeviceCatalog.model($0.model)?.name } ?? snapshot.name
            }
            let pid = endpoint.transportPID ?? (a.isDirect ? entry?.interface.productID : nil)
            name = identified
                ?? pid.flatMap { DeviceCatalog.model(forPID: $0)?.name }
                ?? (a.isDirect ? entry?.interface.name : nil)
                ?? String(localized: "Logitech device")
        } else {
            name = String(localized: "Logitech device")
        }
        guard let connection = entry?.interface.kind.connection ?? record?.connection else {
            return name
        }
        let place = a.isDirect
            ? connection.shortTitle
            : String(localized: "\(connection.shortTitle) slot \(Int(a.index))", comment: "Where a mouse is connected, e.g. Bolt slot 2")
        return "\(name) · \(place)"
    }

    /// "Bolt receiver" for a receiver; a direct link is labelled by its mouse.
    private func linkLabel(_ number: UInt32) -> String? {
        guard let entry = entry(forLink: number) else { return nil }
        switch entry.link.kind {
        case .receiver(let connection): return connection.title
        case .direct: return deviceLabel(DeviceAddress(link: number, index: DeviceAddress.direct))
        }
    }

    // MARK: Compatibility (single-mouse UI, until the Wave 5 views)

    /// The primary mouse's status, or what the interfaces are doing while none is connected.
    @Published private(set) var status: Status = .searching
    /// The primary mouse's kept pointer speed (nil: the mouse decides).
    @Published private(set) var desiredDPI: Int?

    var snapshot: DeviceSnapshot? {
        switch status {
        case .connected(let snapshot), .asleep(let snapshot): return snapshot
        default: return nil
        }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// The primary mouse's controls, or the MX Vertical's known buttons when none was seen yet.
    var controls: [ControlDescriptor] {
        let primary = primaryAddress.flatMap(registry.record)
        return controls(for: primary?.model ?? .mxVertical, address: primary?.address)
    }

    /// Sets the primary mouse's pointer speed. Reported through `onDeviceDPIChange` so the
    /// owner keeps it as that mouse's preference.
    func setDPI(_ value: Int) {
        setDesiredDPI(value)
    }

    /// Sets or clears the primary mouse's kept pointer speed (see `setDPI(_:)`).
    func setDesiredDPI(_ value: Int?) {
        guard let address = primaryAddress else {
            append(String(localized: "Pointer Speed: no mouse is connected"))
            return
        }
        setDPI(value, on: address)
        onDeviceDPIChange?(address, endpoint(at: address)?.desiredDPI ?? value)
    }

    /// Easy-Switch the primary mouse to a zero-based channel.
    func switchToHost(_ index: Int) {
        switchToHost(index, on: primaryAddress ?? .unassigned)
    }

    private func endpoint(at a: DeviceAddress) -> EndpointController? {
        link(of: a)?.endpoints[a.index]
    }

    private func refreshDesiredDPI() {
        let value = primaryAddress.flatMap { endpoint(at: $0)?.desiredDPI }
        if value != desiredDPI { desiredDPI = value }
    }
}

/// The fleet's activity log: the newest `maxEntries` lines (a few more between trims).
@MainActor
final class DeviceActivityLog: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        /// Prefixed with the label of the device or interface the line is about.
        let text: String
        let isTraffic: Bool
        /// The device the line is about; nil for a line about an interface or the app.
        var address: DeviceAddress?
        /// The interface the line is about; nil for a line about the app.
        var link: UInt32?
    }

    private(set) var entries: [Entry] = []

    private var nextID = 0
    private static let maxEntries = 600
    /// Trimming waits for this many extra lines, so the O(n) shift isn't paid on every append.
    private static let trimSlack = 60

    func append(text: String, isTraffic: Bool, address: DeviceAddress?, link: UInt32?) {
        objectWillChange.send()
        nextID += 1
        entries.append(Entry(id: nextID, date: Date(), text: text, isTraffic: isTraffic, address: address, link: link))
        if entries.count > Self.maxEntries + Self.trimSlack {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        objectWillChange.send()
        entries.removeAll()
    }
}

extension ConnectionKind {
    /// "Bolt", "USB": the link part of a device label.
    fileprivate var shortTitle: String {
        switch self {
        case .usb: return String(localized: "USB", comment: "Short connection name in a device label")
        case .bluetooth: return String(localized: "Bluetooth", comment: "Short connection name in a device label")
        case .unifying: return "Unifying"
        case .bolt: return "Bolt"
        case .nano: return "Nano"
        }
    }
}

extension DeviceManager.Status {
    var title: String {
        switch self {
        case .connected(let snapshot), .asleep(let snapshot): return snapshot.name
        default: return String(localized: "Logitech mouse")
        }
    }

    var subtitle: String {
        switch self {
        case .searching: return String(localized: "Not connected")
        case .accessDenied: return String(localized: "macOS is blocking access")
        case .probing(let kind): return String(localized: "Connecting via \(kind.title)…")
        case .waiting(let kind):
            switch kind {
            case .unifying, .bolt, .nano: return String(localized: "Receiver found — click a mouse button to wake it")
            case .usb, .bluetooth: return String(localized: "Mouse found — click a button to wake it")
            }
        case .connected(let snapshot): return String(localized: "Connected via \(snapshot.connection.title)")
        case .asleep: return String(localized: "Asleep — move the mouse to wake it")
        // The controller's terminal sentinel; other messages are already localized.
        case .failed(let message): return message == "Disconnected" ? String(localized: "Disconnected") : message
        }
    }

    var indicator: StatusIndicator {
        switch self {
        case .connected: return .good
        case .asleep, .probing, .waiting: return .pending
        case .searching: return .idle
        case .accessDenied, .failed: return .problem
        }
    }
}
