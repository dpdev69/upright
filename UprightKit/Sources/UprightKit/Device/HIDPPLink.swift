import Foundation

/// Timing and concurrency knobs shared by a hub and its endpoint controllers.
public struct ControllerTuning: Hashable, Sendable {
    /// How long to wait for a receiver slot to answer during discovery.
    public var probeTimeout: TimeInterval = 1.0
    /// Pause before reconfiguring a mouse that just woke up; wake-ups inside it are coalesced.
    public var reconnectDelay: TimeInterval = 0.6
    /// First retry delay while a mouse doesn't answer; doubles per attempt up to `retryMaxDelay`.
    public var retryBaseDelay: TimeInterval = 1
    public var retryMaxDelay: TimeInterval = 30
    /// How often the battery level is re-read while connected (0 disables).
    public var batteryRefreshInterval: TimeInterval = 600
    /// How long to listen for slot announcements when a receiver can't list its pairings.
    public var announcementWait: TimeInterval = 0.3
    /// Requests in flight per transport (D10). 1 until hardware shows receivers tolerate more.
    public var maxInFlight: Int = 1

    public init() {}
}

/// One opened HID interface (a receiver or a directly connected mouse): owns the HID++
/// client, the receiver's pairing directory, and one `EndpointController` per mouse, and
/// routes messages to them by device index (D1).
///
/// A direct link has one endpoint at 0xFF. On a receiver the hub turns on notifications once
/// (read-modify-write of register 0x00, D11), reads the pairing table and starts an endpoint
/// for every occupied slot that isn't a keyboard or another non-pointer. When the table can't
/// be read it asks for announcements (0x41), and pings slots 1...6 once when none arrive.
/// Later 0x41 notifications start, wake, or replace endpoints; 0x40 un-pairing removes one;
/// a report from an unknown slot starts one (a missed link-up heals itself).
///
/// Each endpoint keeps its own retry, backoff and reconfiguration state, so a sleeping mouse
/// never holds up another one beyond the client's request gate (D10). Unsupported devices end
/// in `.unsupported`, stay listed, and are never written to. When an endpoint identifies a
/// unit that another slot of this receiver still holds (a re-pair), the old endpoint is
/// retired (D12).
@MainActor
public final class HIDPPLink {
    /// Why an endpoint went away.
    public enum RemovalReason: Hashable, Sendable {
        /// The receiver reported the slot as un-paired.
        case unpaired
        /// The same unit identified on another slot of this receiver (a re-pair).
        case retired(movedTo: DeviceAddress)
        /// A different device (another wireless PID) now occupies the slot.
        case replaced
        /// The HID interface went away or the hub shut down.
        case transportClosed
    }

    public let link: UInt32
    public let kind: TransportKind
    /// Changes apply to every endpoint, including those already running.
    public var tuning: ControllerTuning {
        didSet {
            client.maxInFlight = tuning.maxInFlight
            endpoints.values.forEach { $0.tuning = tuning }
        }
    }
    public let client: HIDPPClient
    /// The interface's product ID and name (direct links: the model fallback and the name shown
    /// when the mouse reports none).
    public let productID: UInt16?
    public let productName: String?

    /// Live endpoints by device index (1...6, or 0xFF on a direct link).
    public private(set) var endpoints: [UInt8: EndpointController] = [:]
    /// `endpoints` sorted by device index.
    public var orderedEndpoints: [EndpointController] {
        endpoints.keys.sorted().compactMap { endpoints[$0] }
    }

    /// For observers such as `upright-probe` without `--divert`: endpoints whose configuration
    /// diverts nothing leave button reporting untouched instead of forcing every control
    /// native. Upright leaves this false, so a mouse it serves natively still has a diversion
    /// left by a crashed earlier session cleared.
    public var leavesReportingAlone = false

    /// Asked synchronously, right after an endpoint is identified and before anything is
    /// diverted, for the configuration to apply. Nil means `.native`.
    public var configurationProvider: (@MainActor (DeviceAddress, DeviceSnapshot) -> EndpointConfiguration)?
    /// Every state change of every endpoint, starting with `.probing` when it is created.
    public var onEndpointChange: ((DeviceAddress, EndpointController.State) -> Void)?
    /// After the endpoint released its held buttons (and, when it may still be reachable,
    /// handed its buttons back). The address is never reused.
    public var onEndpointRemoved: ((DeviceAddress, RemovalReason) -> Void)?
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    public var onPointerDelta: ((PointerDelta) -> Void)?
    /// The pointer speed an endpoint keeps changed without being asked: adopted from a change
    /// made on that mouse, or stepped by `cycleDPI`. Only that mouse; nothing is broadcast.
    public var onDeviceDPIChange: ((DeviceAddress, Int?) -> Void)?
    public var onLog: ((DeviceAddress?, String) -> Void)?

    /// Set by `shutdown()`. No further work runs afterwards.
    public private(set) var isShutDown = false
    /// True while a receiver reads its pairing table, waits for announcements or pings slots.
    public private(set) var isDiscovering = false {
        didSet { if isDiscovering != oldValue { onDiscoveryChange?() } }
    }
    public private(set) var isStarted = false
    /// The transport closed (or the hub shut down). Terminal.
    public var isClosed: Bool { closed || client.isClosed }

    /// For the legacy single-mouse facade.
    var onDiscoveryChange: (() -> Void)?
    /// Every change of an endpoint's kept pointer speed, whoever made it (legacy facade).
    var onAnyDesiredDPIChange: ((DeviceAddress, Int?) -> Void)?

    private var closed = false
    private var notificationsEnabled = false
    /// Wireless PIDs per slot, from the pairing table and 0x41 notifications.
    private var slotPIDs: [UInt8: UInt16] = [:]
    /// Slots the receiver lists as a keyboard or another non-pointer (slot → wireless PID).
    /// No endpoint is started for them until the slot is un-paired or another device appears.
    private var skippedSlots: [UInt8: UInt16] = [:]
    private var heardAnnouncement = false
    private var announcementsRequestedAt: Date?
    private var discoveryTask: Task<Void, Never>?
    private var notificationsTask: Task<Void, Never>?
    private var rediscoveryTimer: Task<Void, Never>?
    private var rediscoveryAttempt = 0

    public init(
        transport: HIDPPTransport,
        kind: TransportKind,
        link: UInt32,
        tuning: ControllerTuning = .init(),
        productID: UInt16? = nil,
        productName: String? = nil
    ) {
        self.kind = kind
        self.link = link
        self.tuning = tuning
        self.productID = productID
        self.productName = productName
        client = HIDPPClient(transport: transport)
        client.maxInFlight = tuning.maxInFlight
        client.onUnsolicited = { [weak self] message in
            MainActorDelivery.run { self?.route(message) }
        }
        client.onClose = { [weak self] in
            MainActorDelivery.run { self?.transportClosed() }
        }
    }

    public func address(of index: UInt8) -> DeviceAddress {
        DeviceAddress(link: link, index: index)
    }

    // MARK: Public API

    public func start() {
        guard !isStarted, canWork else { return }
        isStarted = true
        switch kind {
        case .direct:
            spawn(DeviceAddress.direct, transportPID: productID, kindHint: nil).start()
        case .receiver(let connection):
            log(nil, "Probing the \(connection.title)")
            startDiscovery(initial: true)
        }
    }

    /// Re-applies configuration: one slot, or every endpoint (after the Mac wakes; a receiver
    /// also re-asserts its notification flags, once).
    public func refresh(index: UInt8? = nil) {
        guard canWork, isStarted else { return }
        if let index {
            endpoints[index]?.refresh()
            return
        }
        if isReceiver {
            Task { await self.ensureNotifications() }
            if !hasPointerEndpoint { startDiscovery(initial: false) }
        }
        orderedEndpoints.forEach { $0.refresh() }
    }

    /// Hands every endpoint's buttons back to its mouse, then closes the client. Terminal.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        rediscoveryTimer?.cancel()
        rediscoveryTimer = nil
        discoveryTask?.cancel()
        orderedEndpoints.forEach { $0.shutdown() }
        client.close()
        transportClosed()
    }

    public func setConfiguration(_ c: EndpointConfiguration, at index: UInt8) {
        endpoints[index]?.apply(c)
    }

    public func cycleDPI(at index: UInt8, presets: [Int]) {
        guard let endpoint = endpoints[index] else {
            log(nil, "Cycle Pointer Speed: no mouse at \(address(of: index))")
            return
        }
        endpoint.cycleDPI(presets: presets)
    }

    /// Sets (or with nil, stops keeping) the pointer speed of the mouse at `index`.
    public func setDPI(_ dpi: Int?, at index: UInt8) {
        endpoints[index]?.setDPIFromApp(dpi)
    }

    /// Easy-Switch the mouse at `index` to a zero-based channel.
    public func switchToHost(_ host: Int, at index: UInt8) {
        guard let endpoint = endpoints[index] else {
            log(nil, "Easy-Switch: no mouse at \(address(of: index))")
            return
        }
        endpoint.switchToHost(host)
    }

    /// Re-reads battery, pointer speed and Easy-Switch channel: one slot, or every endpoint.
    public func refreshDeviceInfo(at index: UInt8?) {
        if let index {
            endpoints[index]?.refreshDeviceInfo()
        } else {
            orderedEndpoints.forEach { $0.refreshDeviceInfo() }
        }
    }

    /// Identifies one endpoint again, or every endpoint on this link (a receiver also re-reads
    /// its pairing table). Unsupported endpoints stay as they are.
    public func reconnect(index: UInt8?) {
        guard canWork, isStarted else { return }
        if let index {
            endpoints[index]?.reconnect()
            return
        }
        orderedEndpoints.forEach { $0.reconnect() }
        if isReceiver { startDiscovery(initial: false) }
    }

    /// Returns once discovery has finished and no endpoint has queued work (tests).
    public func waitUntilIdle() async {
        while true {
            if let task = discoveryTask {
                await task.value
                continue
            }
            if let task = notificationsTask {
                await task.value
                continue
            }
            if let busy = orderedEndpoints.first(where: \.isBusy) {
                await busy.waitUntilIdle()
                continue
            }
            return
        }
    }

    // MARK: Receiver discovery

    private var layout: PairingLayout {
        if case .receiver(.bolt) = kind { return .bolt }
        return .unifying
    }

    private var isReceiver: Bool {
        if case .receiver = kind { return true }
        return false
    }

    private var hasPointerEndpoint: Bool {
        endpoints.values.contains { !$0.isUnsupported }
    }

    private func startDiscovery(initial: Bool) {
        guard canWork, discoveryTask == nil else { return }
        rediscoveryTimer?.cancel()
        rediscoveryTimer = nil
        isDiscovering = true
        discoveryTask = Task {
            await self.discover(initial: initial)
            self.discoveryTask = nil
            self.isDiscovering = false
        }
    }

    private func discover(initial: Bool) async {
        await ensureNotifications()
        guard canWork else { return }

        let records: [UInt8: PairingRecord]?
        do {
            records = try await ReceiverDirectory.readPairings(using: client, layout: layout, timeout: tuning.probeTimeout)
        } catch {
            return
        }
        guard canWork else { return }

        if let records {
            for slot in ReceiverDirectory.slots {
                guard let record = records[slot] else { continue }
                slotPIDs[slot] = record.wirelessPID
                startPaired(record)
            }
        } else {
            heardAnnouncement = false
            announcementsRequestedAt = Date()
            do {
                try await ReceiverDirectory.requestAnnouncements(using: client, timeout: tuning.probeTimeout)
            } catch HIDPPError.transportClosed {
                return
            } catch {
                log(nil, "The receiver can't announce its devices: \(error)")
            }
            if tuning.announcementWait > 0 {
                try? await Task.sleep(nanoseconds: EndpointController.nanoseconds(tuning.announcementWait))
            }
            guard canWork else { return }
            if heardAnnouncement {
                log(nil, "Receiver announced its paired devices")
            } else {
                await pingSlots()
            }
        }
        guard canWork else { return }
        if hasPointerEndpoint {
            rediscoveryAttempt = 0
        } else {
            if initial { log(nil, "No mouse is answering on the receiver yet") }
            // Without notifications nothing announces a mouse that wakes later: poll.
            if !notificationsEnabled { scheduleRediscovery() }
        }
    }

    private func startPaired(_ record: PairingRecord) {
        let slot = record.slot
        guard endpoints[slot] == nil else { return }
        if record.kind.isDefinitelyNotPointer {
            if skippedSlots[slot] != record.wirelessPID {
                log(address(of: slot), String(format: "Slot %d: %@ (wireless PID %04X), not a mouse; leaving it alone", Int(slot), record.kind.name, record.wirelessPID))
            }
            skippedSlots[slot] = record.wirelessPID
            return
        }
        skippedSlots[slot] = nil
        let endpoint = spawn(slot, transportPID: record.wirelessPID, kindHint: Self.hint(record.kind))
        endpoint.retriesWhileWaiting = true
        endpoint.start()
    }

    /// Last resort when the receiver neither lists nor announces its devices.
    private func pingSlots() async {
        for slot in ReceiverDirectory.slots where endpoints[slot] == nil && skippedSlots[slot] == nil {
            guard canWork else { return }
            do {
                _ = try await HIDPPDevice(client: client, index: slot).protocolVersion(timeout: tuning.probeTimeout)
            } catch HIDPPError.transportClosed {
                return
            } catch {
                continue
            }
            guard canWork, endpoints[slot] == nil else { continue }
            let endpoint = spawn(slot, transportPID: slotPIDs[slot], kindHint: nil)
            endpoint.retriesWhileWaiting = true
            endpoint.start()
        }
    }

    private func scheduleRediscovery() {
        guard canWork, rediscoveryTimer == nil else { return }
        let delay = min(tuning.retryBaseDelay * pow(2, Double(min(rediscoveryAttempt, 16))), tuning.retryMaxDelay)
        rediscoveryAttempt += 1
        rediscoveryTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: EndpointController.nanoseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.rediscoveryTimer = nil
            self.startDiscovery(initial: false)
        }
    }

    /// Read-modify-write of the receiver's notification flags (wireless and software-present
    /// on, every other flag kept). Concurrent callers share one pass.
    private func ensureNotifications() async {
        guard isReceiver, canWork else { return }
        if let task = notificationsTask {
            await task.value
            return
        }
        let task = Task {
            await self.writeNotificationFlags()
            self.notificationsTask = nil
        }
        notificationsTask = task
        await task.value
    }

    private func writeNotificationFlags() async {
        guard canWork else { return }
        do {
            try await ReceiverDirectory.enableNotifications(using: client, timeout: tuning.probeTimeout)
            notificationsEnabled = true
        } catch HIDPPError.transportClosed {
            return
        } catch {
            log(nil, "Receiver notifications unavailable: \(error)")
        }
    }

    // MARK: Routing

    private func route(_ message: HIDPPMessage) {
        guard canWork else { return }
        guard isReceiver else {
            endpoints[DeviceAddress.direct]?.receive(message)
            return
        }
        if let slot = ReceiverDirectory.isUnpair(message) {
            handleUnpair(slot)
            return
        }
        // Other disconnection notifications carry nothing to act on.
        if message.subID == 0x40 { return }
        if let connection = ReceiverDirectory.parseConnection(message) {
            handleConnection(slot: connection.slot, wirelessPID: connection.wirelessPID, kind: connection.kind, linkUp: connection.linkUp)
            return
        }
        let slot = message.deviceIndex
        guard ReceiverDirectory.slots.contains(slot) else { return }
        if let endpoint = endpoints[slot] {
            endpoint.receive(message)
            return
        }
        // A device report (not a late reply, error or receiver notification) from a slot
        // nobody serves: the link-up was missed. Check what is there.
        guard isStarted, message.softwareID == 0, message.subID < 0x40, skippedSlots[slot] == nil else { return }
        log(address(of: slot), "Slot \(slot) sent a report; checking the device there")
        spawn(slot, transportPID: slotPIDs[slot], kindHint: nil).startAnnounced()
    }

    /// 0x41: a slot's link went up or down, or the receiver answered an announcement request.
    private func handleConnection(slot: UInt8, wirelessPID: UInt16, kind: DeviceKind, linkUp: Bool) {
        heardAnnouncement = true
        if wirelessPID != 0 {
            slotPIDs[slot] = wirelessPID
            if let skipped = skippedSlots[slot], skipped != wirelessPID { skippedSlots[slot] = nil }
        }
        if let endpoint = endpoints[slot] {
            let known = endpoint.transportPID ?? endpoint.snapshot?.identity?.transportPID
            // An unsupported endpoint whose wireless PID was never learned is checked again
            // once (reads only): it may be the same device, or a mouse paired in its place.
            let replaced = wirelessPID != 0 && (known.map { $0 != wirelessPID } ?? endpoint.isUnsupported)
            guard replaced else {
                endpoint.linkChanged(up: linkUp, announcementEcho: isAnnouncementEcho(for: endpoint))
                return
            }
            log(endpoint.address, String(format: "Slot %d now holds another device (wireless PID %04X)", Int(slot), wirelessPID))
            // No restore: the old device is gone, and the slot now addresses another one.
            remove(endpoint, reason: .replaced, restore: false)
        }
        guard linkUp, skippedSlots[slot] == nil else { return }
        if kind.isDefinitelyNotPointer {
            log(address(of: slot), String(format: "Slot %d: %@ (wireless PID %04X), not a mouse; leaving it alone", Int(slot), kind.name, wirelessPID))
            skippedSlots[slot] = wirelessPID
            return
        }
        log(address(of: slot), String(format: "Slot %d connected (wireless PID %04X)", Int(slot), wirelessPID))
        let endpoint = spawn(slot, transportPID: wirelessPID == 0 ? nil : wirelessPID, kindHint: Self.hint(kind))
        endpoint.retriesWhileWaiting = true
        endpoint.startAnnounced()
    }

    private func handleUnpair(_ slot: UInt8) {
        slotPIDs[slot] = nil
        skippedSlots[slot] = nil
        guard let endpoint = endpoints[slot] else { return }
        log(endpoint.address, "The device in slot \(slot) was unpaired")
        remove(endpoint, reason: .unpaired, restore: false)
    }

    /// Receivers answer an announcement request with a 0x41 for every paired device, including
    /// the ones already configured. Those aren't real reconnects (per slot).
    private func isAnnouncementEcho(for endpoint: EndpointController) -> Bool {
        guard case .connected = endpoint.state,
              let requested = announcementsRequestedAt,
              let configured = endpoint.configuredAt
        else { return false }
        return configured > requested && Date().timeIntervalSince(requested) < 2
    }

    // MARK: Endpoints

    @discardableResult
    private func spawn(_ index: UInt8, transportPID: UInt16?, kindHint: DeviceKind?) -> EndpointController {
        let endpoint = EndpointController(
            client: client,
            kind: kind,
            address: address(of: index),
            hub: self,
            tuning: tuning,
            transportPID: transportPID,
            kindHint: kindHint,
            fallbackName: isReceiver ? nil : productName
        )
        endpoints[index] = endpoint
        onEndpointChange?(endpoint.address, endpoint.state)
        return endpoint
    }

    /// Releases the endpoint's held buttons, optionally hands its buttons back, and forgets it.
    private func remove(_ endpoint: EndpointController, reason: RemovalReason, restore: Bool) {
        let index = endpoint.address.index
        guard endpoints[index] === endpoint else { return }
        endpoint.retire(sendingRestore: restore)
        endpoints[index] = nil
        onEndpointRemoved?(endpoint.address, reason)
    }

    private func transportClosed() {
        guard !closed else { return }
        closed = true
        rediscoveryTimer?.cancel()
        rediscoveryTimer = nil
        discoveryTask?.cancel()
        if !isShutDown { log(nil, "The HID connection closed") }
        let all = orderedEndpoints
        all.forEach { $0.transportDidClose() }
        endpoints.removeAll()
        all.forEach { onEndpointRemoved?($0.address, .transportClosed) }
        isDiscovering = false
        onDiscoveryChange?()
    }

    // MARK: Helpers

    private var canWork: Bool { !isShutDown && !closed && !client.isClosed }

    private static func hint(_ kind: DeviceKind) -> DeviceKind? {
        kind == .unknown ? nil : kind
    }

    private func log(_ address: DeviceAddress?, _ text: String) {
        onLog?(address, text)
    }
}

extension HIDPPLink: EndpointHub {
    func endpoint(_ endpoint: EndpointController, didChangeState state: EndpointController.State) {
        guard endpoints[endpoint.address.index] === endpoint else { return }
        onEndpointChange?(endpoint.address, state)
    }

    func endpointDidIdentify(_ endpoint: EndpointController, snapshot: DeviceSnapshot) -> EndpointConfiguration {
        // A re-pair: the same unit is still listed on another slot of this receiver.
        if let id = endpoint.lastDeviceID, id.isStable {
            for other in orderedEndpoints where other !== endpoint && other.lastDeviceID == id {
                log(endpoint.address, "\(snapshot.name) moved from slot \(other.address.index) to slot \(endpoint.address.index)")
                remove(other, reason: .retired(movedTo: endpoint.address), restore: true)
            }
        }
        return configurationProvider?(endpoint.address, snapshot) ?? .native
    }

    func endpoint(_ endpoint: EndpointController, didEmit event: ButtonEvent) {
        onButtonEvent?(event)
    }

    func endpoint(_ endpoint: EndpointController, didMove delta: PointerDelta) {
        onPointerDelta?(delta)
    }

    func endpoint(_ endpoint: EndpointController, didChangeDesiredDPI dpi: Int?, chosenByDevice: Bool) {
        if chosenByDevice { onDeviceDPIChange?(endpoint.address, dpi) }
        onAnyDesiredDPIChange?(endpoint.address, dpi)
    }

    func endpointNeedsReceiverNotifications(_ endpoint: EndpointController) async {
        await ensureNotifications()
    }

    func endpoint(_ endpoint: EndpointController, log text: String) {
        log(endpoint.address, text)
    }
}
