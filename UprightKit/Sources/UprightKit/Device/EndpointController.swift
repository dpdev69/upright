import Foundation

/// What an `EndpointController` needs from the hub (`HIDPPLink`) that owns it.
@MainActor
protocol EndpointHub: AnyObject {
    func endpoint(_ endpoint: EndpointController, didChangeState state: EndpointController.State)
    /// The endpoint identified its device and nothing is diverted yet: retire stale endpoints
    /// of the same unit and return the configuration to apply.
    func endpointDidIdentify(_ endpoint: EndpointController, snapshot: DeviceSnapshot) -> EndpointConfiguration
    func endpoint(_ endpoint: EndpointController, didEmit event: ButtonEvent)
    func endpoint(_ endpoint: EndpointController, didMove delta: PointerDelta)
    /// `chosenByDevice`: adopted from the mouse or stepped by `cycleDPI`, not set by the app.
    func endpoint(_ endpoint: EndpointController, didChangeDesiredDPI dpi: Int?, chosenByDevice: Bool)
    /// A receiver slot is coming back after losing its link: make sure the receiver still
    /// sends notifications (coalesced across slots).
    func endpointNeedsReceiverNotifications(_ endpoint: EndpointController) async
    /// True once the receiver has accepted the notification flags (0x41 link changes arrive).
    var receiverNotificationsEnabled: Bool { get }
    func endpoint(_ endpoint: EndpointController, log text: String)
    /// True for an observer (`upright-probe` without `--divert`): button reporting is only
    /// written once this process has asked for a diversion, never just to make it native.
    var leavesReportingAlone: Bool { get }
}

/// Keeps one mouse configured: a receiver slot (1...6) or a directly connected device (0xFF).
///
/// It identifies the device, applies the configuration its hub hands it, and re-applies it
/// whenever the mouse wakes up, reconnects, or the Mac resumes from sleep. Discovery and
/// message routing belong to the hub (`HIDPPLink`); everything here is scoped to one address.
///
/// Everything that talks to the device runs on one serial operation queue, so probes,
/// reconfigurations and mapping changes for this mouse never interleave (requests to other
/// mice interleave with them at the client's request gate). While the transport is open the
/// controller never gives up: a mouse that stops answering is retried with exponential
/// backoff, and any report it sends in the meantime triggers a reconfiguration right away.
/// A device that isn't a supported mouse ends in the terminal `.unsupported` state and is
/// never written to. Retiring the endpoint, closing the transport or `shutdown()` is terminal.
@MainActor
public final class EndpointController {
    public enum State: Hashable, Sendable {
        case probing
        /// The mouse isn't answering yet (off, asleep, or paired elsewhere). Retried automatically.
        case waitingForDevice
        case connected(DeviceSnapshot)
        /// The mouse stopped answering; it is reconfigured as soon as it answers again.
        case asleep(DeviceSnapshot)
        /// Not a mouse Upright can serve. Terminal: no retry, no writes, never diverted.
        case unsupported(UnsupportedReason, DeviceSnapshot?)
        /// The device can't be used right now. `.failed("Disconnected")` (transport closed) is terminal.
        case failed(String)
    }

    public let client: HIDPPClient
    public let kind: TransportKind
    public let address: DeviceAddress
    /// The receiver's wireless PID for the slot, or the interface's product ID on a direct link.
    public let transportPID: UInt16?
    /// The kind the receiver lists for the slot; the device's own answer wins.
    public let kindHint: DeviceKind?
    /// The name to show when the device reports none (the IOHID product string of a direct link).
    public let fallbackName: String?
    /// Whether an unanswered probe is retried with backoff. False only for a receiver slot that
    /// isn't known to be paired while the receiver sends link notifications (they announce it).
    public internal(set) var retriesWhileWaiting = true

    public private(set) var state: State = .probing {
        didSet {
            guard state != oldValue else { return }
            // Leaving `.connected`: whatever was held can't be released by the mouse any more.
            // A new snapshot while connected (battery, speed) must not release held buttons.
            if case .connected = oldValue, !Self.isConnected(state) {
                session?.releaseAll()
            }
            hub?.endpoint(self, didChangeState: state)
        }
    }
    public private(set) var desiredDiversion: Set<UInt16> = []
    /// Controls that report raw pointer movement while held (always diverted too).
    public private(set) var desiredRawXY: Set<UInt16> = []
    /// The pointer speed to keep. Many mice forget a speed set over HID++ when they reconnect,
    /// so it is re-applied when the mouse comes back at its default speed. A mouse that comes
    /// back at another speed had it changed with its own button, and that speed is adopted
    /// instead. Nil leaves the mouse's own setting alone.
    public private(set) var desiredDPI: Int?
    /// Set when the endpoint is retired, shut down, or its transport closes. No work runs afterwards.
    public private(set) var isShutDown = false

    var tuning: ControllerTuning

    private weak var hub: EndpointHub?
    private var session: DeviceSession?
    private var started = false
    /// The last pointer speed the hub's configuration asked for (edge-triggered: a speed the
    /// mouse chose isn't overridden until the configuration itself changes).
    private var configuredDPI: Int?
    /// The unit last identified here, kept when the session is dropped.
    private(set) var lastDeviceID: DeviceID?
    /// When the configuration was last applied (announcement echo detection).
    private(set) var configuredAt: Date?
    /// The slot lost its link (or stopped answering) since the last reconfiguration.
    private var linkWasLost = false

    private enum OperationKey: Hashable {
        case probe, reconfigure, recover, diversion, battery, dpi, deviceInfo, connect
        /// Every cycle request runs; they aren't coalesced like the other keys.
        case cycleDPI(Int)

        var touchesLink: Bool {
            switch self {
            case .probe, .reconfigure, .recover, .connect: return true
            case .diversion, .battery, .dpi, .deviceInfo, .cycleDPI: return false
            }
        }
    }

    private struct Operation {
        let key: OperationKey
        let body: @MainActor (EndpointController) async -> Void
    }

    private var queue: [Operation] = []
    private var runner: Task<Void, Never>?
    private var currentKey: OperationKey?

    private var reconfigureTimer: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var retryAttempt = 0
    private var batteryTimer: Task<Void, Never>?
    private var cycleRequests = 0

    init(
        client: HIDPPClient,
        kind: TransportKind,
        address: DeviceAddress,
        hub: EndpointHub,
        tuning: ControllerTuning = .init(),
        transportPID: UInt16? = nil,
        kindHint: DeviceKind? = nil,
        fallbackName: String? = nil
    ) {
        self.client = client
        self.kind = kind
        self.address = address
        self.hub = hub
        self.tuning = tuning
        self.transportPID = transportPID
        self.kindHint = kindHint
        self.fallbackName = fallbackName
    }

    public var snapshot: DeviceSnapshot? { session?.snapshot }

    public var isUnsupported: Bool {
        if case .unsupported = state { return true }
        return false
    }

    /// True while an operation is queued or running.
    var isBusy: Bool { runner != nil }

    // MARK: Lifecycle (driven by the hub)

    /// Probes the device (a known receiver slot, or a direct link).
    func start() {
        guard !started else { return }
        started = true
        enqueue(.probe) { await $0.probe() }
    }

    /// Starts on a slot the receiver announced, or that sent a report: waits `reconnectDelay`
    /// for the mouse to finish connecting, then connects without a `.probing` flicker.
    func startAnnounced() {
        guard !started else { return }
        started = true
        scheduleConnect()
    }

    /// Delivers a message addressed to this endpoint (receiver-level 0x40/0x41 are the hub's).
    func receive(_ message: HIDPPMessage) {
        guard !isShutDown, !isUnsupported else { return }
        if let session, session.handle(message) {
            switch state {
            case .asleep, .failed: scheduleReconfigure("The mouse is sending reports again")
            default: break
            }
            return
        }
        noteActivity(from: message)
    }

    /// The receiver reported the slot's link going up or down (0x41). `announcementEcho`: the
    /// hub asked for announcements after this slot was configured, so a link-up is not news.
    func linkChanged(up: Bool, announcementEcho: Bool) {
        guard !isShutDown, !isUnsupported else { return }
        if let session {
            if up {
                if announcementEcho { return }
                session.invalidateAppliedState()
                scheduleReconfigure("Slot \(address.index) link restored")
            } else {
                log("Slot \(address.index) link lost")
                linkWasLost = true
                session.releaseAll()
                if let snapshot = session.snapshot { transition(.asleep(snapshot)) }
                // The link-up normally brings it back, but it can be missed (dropped while the
                // Mac wakes, or the receiver's notification flags were lost), so keep polling.
                scheduleRetry()
            }
            return
        }
        guard up else { return }
        log(String(format: "Slot %d connected", Int(address.index)))
        scheduleConnect()
    }

    /// Removes the endpoint: releases held buttons and, when the device may still be reachable,
    /// hands its diverted buttons back without waiting for replies. Terminal.
    func retire(sendingRestore: Bool) {
        guard !isShutDown else { return }
        stopAllWork()
        if let session {
            session.releaseAll()
            if sendingRestore { session.restoreMessages().forEach(client.sendWithoutReply) }
        }
        dropSession()
    }

    /// Stops all work and hands every diverted button back to the mouse without waiting for
    /// replies. Terminal. The hub closes the client afterwards.
    func shutdown() {
        retire(sendingRestore: true)
    }

    /// The transport closed: everything held is released. Terminal.
    func transportDidClose() {
        stopAllWork()
        dropSession()
        state = .failed("Disconnected")
    }

    /// Drops the session and identifies the device again. No effect on an unsupported device.
    func reconnect() {
        guard canWork, !isUnsupported else { return }
        retryAttempt = 0
        cancelRetry()
        reconfigureTimer?.cancel()
        reconfigureTimer = nil
        dropSession()
        started = true
        enqueue(.probe) { await $0.probe() }
    }

    // MARK: Configuration

    /// Applies what the hub's configuration provider decided for this mouse. The pointer speed
    /// is edge-triggered: it is applied when the configured value changes, so a speed chosen on
    /// the mouse itself isn't reverted by an unrelated resync.
    public func apply(_ configuration: EndpointConfiguration) {
        setDesiredDiversion(configuration.divert)
        setDesiredRawXY(configuration.rawXY)
        if configuration.dpi != configuredDPI {
            configuredDPI = configuration.dpi
            if configuration.dpi != desiredDPI { setDesiredDPI(configuration.dpi) }
        }
    }

    /// A pointer speed chosen in the app for this mouse (nil: leave the mouse's own setting).
    /// It also becomes the configured speed, so an identical configuration doesn't re-apply it.
    func setDPIFromApp(_ dpi: Int?) {
        configuredDPI = dpi
        setDesiredDPI(dpi)
    }

    public func setDesiredDiversion(_ cids: Set<UInt16>) {
        guard cids != desiredDiversion else { return }
        desiredDiversion = cids
        scheduleDiversionUpdate()
    }

    /// Controls that should report raw movement (as pointer deltas) instead of moving the
    /// pointer while held. They are diverted as well, whatever `desiredDiversion` says.
    /// Controls without the raw XY capability are only diverted.
    public func setDesiredRawXY(_ cids: Set<UInt16>) {
        guard cids != desiredRawXY else { return }
        desiredRawXY = cids
        scheduleDiversionUpdate()
    }

    private func scheduleDiversionUpdate() {
        enqueue(.diversion) { controller in
            await controller.withConnectedSession("update diversion") { session in
                try await controller.applyDesiredDiversion(to: session, force: false)
            }
        }
    }

    // MARK: Pointer speed

    /// Sets the pointer speed (snapped to the nearest supported value) and keeps it across
    /// reconnects. Without a connected mouse it is applied when one connects.
    public func setDPI(_ value: Int) {
        setDesiredDPI(value)
    }

    /// Like `setDPI`; nil stops re-applying a speed and leaves the mouse's setting alone.
    public func setDesiredDPI(_ value: Int?) {
        updateDesiredDPI(value.map { snapshot?.dpi?.nearest(to: $0) ?? $0 }, chosenByDevice: false)
        guard desiredDPI != nil else { return }
        enqueue(.dpi) { controller in
            await controller.withConnectedSession("change the pointer speed") { session in
                try await controller.applyDesiredDPI(to: session)
            }
        }
    }

    /// Steps to the preset after the current speed, wrapping around. Empty `presets` uses four
    /// evenly spaced supported values. The result becomes `desiredDPI`.
    public func cycleDPI(presets: [Int] = []) {
        cycleRequests += 1
        enqueue(.cycleDPI(cycleRequests)) { controller in
            await controller.withConnectedSession("change the pointer speed") { session in
                // The mouse's own button may have changed the speed since we last looked.
                try await session.refreshDPI()
                guard let dpi = session.snapshot?.dpi else {
                    controller.log("This mouse can't change its pointer speed")
                    return
                }
                controller.updateDesiredDPI(dpi.nextPreset(after: dpi.current, presets: presets), chosenByDevice: true)
                try await controller.applyDesiredDPI(to: session)
            }
        }
    }

    /// Re-reads the pointer speed. A speed that differs from `desiredDPI` was changed on the
    /// mouse (its DPI button cycles speeds natively when not diverted) and becomes the new
    /// `desiredDPI`. Meant for when the UI is about to show it.
    public func refreshDPI() {
        enqueue(.dpi) { controller in
            await controller.withConnectedSession("read the pointer speed") { session in
                try await controller.refreshDPI(of: session, adopting: true)
            }
        }
    }

    private func updateDesiredDPI(_ value: Int?, chosenByDevice: Bool) {
        guard value != desiredDPI else { return }
        desiredDPI = value
        hub?.endpoint(self, didChangeDesiredDPI: value, chosenByDevice: chosenByDevice)
    }

    // MARK: Device information

    /// Re-reads battery, pointer speed and the active Easy-Switch channel.
    public func refreshDeviceInfo() {
        enqueue(.deviceInfo) { controller in
            await controller.withConnectedSession("refresh device information") { session in
                await session.refreshBattery()
                try await controller.refreshDPI(of: session, adopting: true)
                try await session.refreshHosts()
            }
        }
    }

    /// Easy-Switch to a zero-based channel. The mouse leaves right away without answering, so
    /// the request is sent without waiting; the usual link-lost handling takes over.
    public func switchToHost(_ index: Int) {
        guard let session, case .connected = state else {
            log("No connected mouse to switch")
            return
        }
        guard let hosts = session.snapshot?.hosts, let message = session.changeHostMessage(host: index) else {
            log("This mouse doesn't support Easy-Switch")
            return
        }
        guard (0..<hosts.count).contains(index) else {
            log("This mouse has no Easy-Switch channel \(index + 1)")
            return
        }
        guard index != hosts.current else { return }
        log("Switching the mouse to channel \(index + 1)")
        client.sendWithoutReply(message)
    }

    /// Re-applies configuration (after the Mac wakes, or on request). Falls back to a full
    /// re-probe when the mouse hasn't been identified yet.
    public func refresh() {
        retryAttempt = 0
        scheduleReconfigure(nil)
    }

    /// Waits until every queued operation has finished. Mainly useful in tests.
    public func waitUntilIdle() async {
        while let runner {
            await runner.value
        }
    }

    // MARK: Operation queue

    private func enqueue(_ key: OperationKey, _ body: @escaping @MainActor (EndpointController) async -> Void) {
        guard !isShutDown else { return }
        // Anything already waiting with the same key will do the same work.
        if queue.contains(where: { $0.key == key }) { return }
        queue.append(Operation(key: key, body: body))
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let operation = self?.nextOperation() {
                guard let self else { return }
                self.currentKey = operation.key
                await operation.body(self)
                self.currentKey = nil
            }
        }
    }

    private func nextOperation() -> Operation? {
        guard !isShutDown, !queue.isEmpty else {
            runner = nil
            return nil
        }
        return queue.removeFirst()
    }

    /// True while discovery or reconfiguration is running or about to run.
    private var isWorkingOnLink: Bool {
        reconfigureTimer != nil
            || currentKey?.touchesLink == true
            || queue.contains { $0.key.touchesLink }
    }

    private func stopAllWork() {
        isShutDown = true
        queue.removeAll()
        runner?.cancel()
        for timer in [reconfigureTimer, retryTimer, batteryTimer] { timer?.cancel() }
        reconfigureTimer = nil
        retryTimer = nil
        batteryTimer = nil
    }

    /// Debounces wake-up signals (0x41 link-up, 0x1D4B, Mac wake, a report from a sleeping
    /// mouse) so a burst of them results in a single reconfiguration.
    private func scheduleReconfigure(_ reason: String?) {
        guard !isShutDown, !isUnsupported else { return }
        cancelRetry()
        guard reconfigureTimer == nil else { return }
        if let reason { log(reason) }
        let delay = tuning.reconnectDelay
        reconfigureTimer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: Self.nanoseconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.reconfigureTimer = nil
            self.enqueue(.reconfigure) { await $0.reconfigure() }
        }
    }

    /// Exponential backoff, capped at `retryMaxDelay`. Never gives up while the transport is open.
    /// An absent receiver slot (no session) backs off up to `retryMaxDelayWithNotifications`
    /// once the receiver sends link notifications, since a 0x41 link-up or a report from the
    /// slot reconnects it without polling.
    private func scheduleRetry() {
        guard !isShutDown, !isUnsupported, retryTimer == nil else { return }
        let cap = isReceiver && session == nil && hub?.receiverNotificationsEnabled == true
            ? tuning.retryMaxDelayWithNotifications
            : tuning.retryMaxDelay
        let delay = min(tuning.retryBaseDelay * pow(2, Double(min(retryAttempt, 16))), cap)
        retryAttempt += 1
        if delay < cap || retryAttempt <= 1 || retryAttempt % 10 == 0 {
            log(String(format: "Trying again in %.1f s", delay))
        }
        retryTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTimer = nil
            self.enqueue(.recover) { await $0.recover() }
        }
    }

    private func cancelRetry() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    private func startBatteryRefresh() {
        guard batteryTimer == nil, tuning.batteryRefreshInterval > 0, !isShutDown else { return }
        let interval = tuning.batteryRefreshInterval
        batteryTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard case .connected = self.state else { continue }
                self.enqueue(.battery) { controller in
                    guard let session = controller.session, case .connected = controller.state else { return }
                    await session.refreshBattery()
                    guard controller.session === session else { return }
                    controller.publishSnapshot()
                }
            }
        }
    }

    // MARK: Operations

    private func recover() async {
        if session != nil {
            await reconfigure()
        } else {
            await probe(retrying: true)
        }
    }

    private func probe(retrying: Bool = false) async {
        guard canWork, session == nil, !isUnsupported else { return }
        cancelRetry()
        // Retries stay in the waiting state so the UI doesn't flicker on every attempt.
        if !retrying {
            transition(.probing)
            switch kind {
            case .direct(let connection): log("Probing the mouse over \(connection.title)")
            case .receiver(let connection): log("Probing slot \(address.index) of the \(connection.title)")
            }
        }
        switch await connect() {
        case .configured, .asleep, .closed, .unsupported:
            return
        case .unreachable(let error):
            if !retrying || !isReceiver { log("The mouse isn't answering yet (\(error))") }
            transition(.waitingForDevice)
        case .failed(let error):
            log("Setup failed: \(error)")
            transition(isReceiver ? .waitingForDevice : .failed(Self.setupFailedMessage))
        }
        if retriesWhileWaiting { scheduleRetry() }
    }

    private static var setupFailedMessage: String {
        NSLocalizedString("The mouse didn't answer HID++ requests. Try clicking a button to wake it, then choose Reconnect.", comment: "Connection status shown when setup fails")
    }

    private enum ConnectOutcome {
        /// Connected and configured.
        case configured
        /// Found and kept, but it stopped answering before it was configured. Retried.
        case asleep
        /// Nothing answered; no session was created.
        case unreachable(Error)
        case failed(Error)
        /// Not a supported mouse (terminal).
        case unsupported
        case closed
    }

    private func connect() async -> ConnectOutcome {
        let candidate = DeviceSession(
            device: HIDPPDevice(client: client, index: address.index),
            connection: kind.connection,
            address: address,
            transportPID: transportPID,
            fallbackName: fallbackName,
            kindHint: kindHint
        )
        let snapshot: DeviceSnapshot
        do {
            snapshot = try await candidate.start(pingTimeout: isReceiver ? tuning.probeTimeout : nil)
        } catch HIDPPError.transportClosed {
            return .closed
        } catch HIDPPError.unsupportedDevice(let reason, let partial) {
            guard canWork else { return .closed }
            becomeUnsupported(reason, partial: partial)
            return .unsupported
        } catch let error as HIDPPError where error.meansDeviceUnreachable {
            return .unreachable(error)
        } catch {
            return canWork ? .failed(error) : .closed
        }
        guard canWork else { return .closed }
        adopt(candidate)
        lastDeviceID = snapshot.identity?.deviceID(at: address)
        log("Connected to \(snapshot.name) (HID++ \(snapshot.protocolVersion), \(snapshot.controls.count) controls)")

        // Pulled before anything is diverted, so no event is ever anonymous.
        let configuration = hub?.endpointDidIdentify(self, snapshot: snapshot) ?? .native
        guard session === candidate, canWork else { return .closed }
        desiredDiversion = configuration.divert
        desiredRawXY = configuration.rawXY
        configuredDPI = configuration.dpi
        updateDesiredDPI(configuration.dpi.map { snapshot.dpi?.nearest(to: $0) ?? $0 }, chosenByDevice: false)

        do {
            try await applyDesiredDiversion(to: candidate, force: true)
            guard session === candidate, canWork else { return .closed }
            // `start()` just read the speed, so there's nothing earlier to compare it with.
            if desiredDPI != nil { try await reconcileDPI(of: candidate, lastKnown: nil, reading: false) }
            guard session === candidate, canWork else { return .closed }
            markConfigured()
            return .configured
        } catch HIDPPError.transportClosed {
            return .closed
        } catch let error as HIDPPError where error.meansDeviceUnreachable {
            guard session === candidate else { return .closed }
            becameUnreachable(candidate, error)
            return .asleep
        } catch {
            if session === candidate { dropSession() }
            return canWork ? .failed(error) : .closed
        }
    }

    private func becomeUnsupported(_ reason: UnsupportedReason, partial: DeviceSnapshot?) {
        let name = partial?.name ?? "The device"
        log("\(name): not supported (\(reason.message)); leaving it alone")
        cancelRetry()
        transition(.unsupported(reason, partial))
    }

    private func reconfigure() async {
        guard canWork, !isUnsupported else { return }
        guard let session else {
            await probe(retrying: state == .waitingForDevice)
            return
        }
        if isReceiver, linkWasLost {
            linkWasLost = false
            await hub?.endpointNeedsReceiverNotifications(self)
            guard self.session === session, canWork else { return }
        }
        do {
            try await applyDesiredDiversion(to: session, force: true)
            guard self.session === session, canWork else { return }
            try await reconcileDPI(of: session, lastKnown: session.snapshot?.dpi?.current, reading: true)
            guard self.session === session, canWork else { return }
            try await session.refreshHosts()
            guard self.session === session, canWork else { return }
            await session.refreshBattery()
            guard self.session === session, canWork else { return }
            log("Reapplied configuration")
            markConfigured()
        } catch HIDPPError.transportClosed {
            return
        } catch let error as HIDPPError where error.meansDeviceUnreachable {
            guard self.session === session else { return }
            becameUnreachable(session, error)
        } catch {
            guard self.session === session, canWork else { return }
            log("Reconfiguration failed (\(error)); probing again")
            dropSession()
            await probe()
        }
    }

    /// Connects to a slot the receiver announced (link-up) or that sent a report.
    private func connectAnnounced() async {
        guard canWork, !isUnsupported else { return }
        if tuning.reconnectDelay > 0 {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(tuning.reconnectDelay))
            guard canWork else { return }
        }
        guard session == nil else { return }
        switch await connect() {
        case .configured, .asleep, .closed, .unsupported:
            return
        case .unreachable(let error):
            log("Slot \(address.index) isn't answering yet: \(error)")
            transition(.waitingForDevice)
            scheduleRetry()
        case .failed(let error):
            log("Slot \(address.index): \(error)")
            if session == nil { transition(.waitingForDevice) }
        }
    }

    private func applyDesiredDiversion(to session: DeviceSession, force: Bool) async throws {
        let wanted = desiredDiversion
        let rawXY = desiredRawXY
        // An observer that diverts nothing (and never did through this session) writes nothing:
        // forcing every control native would undo another process's diversion (Upright running
        // next to upright-probe). The app never sets this, so it still clears a diversion left
        // behind by a crashed earlier session.
        if hub?.leavesReportingAlone == true, wanted.isEmpty, rawXY.isEmpty,
           session.divertedControls.isEmpty, session.rawXYControls.isEmpty {
            return
        }
        let failures = try await HIDPPClient.$lane.withValue(.interactive) {
            try await session.applyDiversion(wanted, rawXY: rawXY, force: force)
        }
        log("Diverted controls: \(Self.describe(session.divertedControls))")
        if !rawXY.isEmpty || !session.rawXYControls.isEmpty {
            log("Raw XY controls: \(Self.describe(session.rawXYControls))")
        }
        let configurable = Set(session.snapshot?.configurableControls.map(\.cid) ?? [])
        let unsupported = rawXY.intersection(configurable).subtracting(session.rawXYControls).subtracting(failures.keys)
        if !unsupported.isEmpty {
            log("Controls without raw XY support (diverted only): \(Self.describe(unsupported))")
        }
        for (cid, error) in failures.sorted(by: { $0.key < $1.key }) {
            log(String(format: "Control 0x%04X refused the change: %@", cid, "\(error)"))
        }
    }

    /// Re-applies `desiredDPI` (mice often forget it when they reconnect), or re-reads the
    /// current speed when there is none. Refusals are logged; an unreachable mouse throws.
    private func applyDesiredDPI(to session: DeviceSession) async throws {
        guard let desired = desiredDPI else {
            try await session.refreshDPI()
            return
        }
        do {
            let applied = try await HIDPPClient.$lane.withValue(.interactive) {
                try await session.setDPI(desired)
            }
            if let applied {
                log("Pointer speed: \(applied) DPI")
            }
        } catch let error as HIDPPError where error.meansDeviceUnreachable || error == .transportClosed {
            throw error
        } catch {
            log("The mouse refused pointer speed \(desired) DPI: \(error)")
        }
    }

    /// After a (re)connect: keeps a speed chosen with the mouse's own button, or re-applies
    /// `desiredDPI` when the mouse forgot it.
    ///
    /// A speed that is neither `desiredDPI`, the mouse's default, nor `lastKnown` (what this
    /// session last set or read) was changed on the mouse and becomes `desiredDPI`. A mouse back
    /// at its default lost the speed set over HID++, so `desiredDPI` is applied again; so is a
    /// speed the app changed since `lastKnown`. `reading` re-reads the speed first.
    private func reconcileDPI(of session: DeviceSession, lastKnown: Int?, reading: Bool) async throws {
        guard let desired = desiredDPI else {
            if reading { try await session.refreshDPI() }
            return
        }
        if reading {
            try await session.refreshDPI()
            guard self.session === session, canWork else { return }
        }
        // Changed through the API while the read was in flight: apply the new value.
        guard desiredDPI == desired, let dpi = session.snapshot?.dpi else {
            try await applyDesiredDPI(to: session)
            return
        }
        if dpi.current == desired { return }
        if dpi.current != dpi.defaultValue, dpi.current != lastKnown {
            log("Keeping pointer speed \(dpi.current) DPI chosen on the mouse")
            updateDesiredDPI(dpi.current, chosenByDevice: true)
            return
        }
        try await applyDesiredDPI(to: session)
    }

    private func refreshDPI(of session: DeviceSession, adopting: Bool) async throws {
        let desiredBeforeRead = desiredDPI
        try await session.refreshDPI()
        // A speed set through the API while the read was in flight wins over what was read.
        guard adopting, let desired = desiredDPI, desired == desiredBeforeRead,
              let current = session.snapshot?.dpi?.current, current != desired else { return }
        log("Pointer speed changed on the mouse to \(current) DPI")
        updateDesiredDPI(current, chosenByDevice: true)
    }

    /// Runs a non-link operation against the connected session and publishes the result.
    /// An unreachable mouse is handed to the usual retry logic; other errors are logged.
    private func withConnectedSession(_ action: String, _ body: (DeviceSession) async throws -> Void) async {
        guard let session, case .connected = state else { return }
        do {
            try await body(session)
            guard self.session === session else { return }
            publishSnapshot()
        } catch HIDPPError.transportClosed {
            return
        } catch let error as HIDPPError where error.meansDeviceUnreachable {
            guard self.session === session else { return }
            becameUnreachable(session, error)
        } catch {
            guard canWork else { return }
            log("Could not \(action): \(error)")
        }
    }

    // MARK: Session lifecycle

    private func adopt(_ new: DeviceSession) {
        replaceSession(with: new)
        new.onButtonEvent = { [weak self] event in
            guard let self else { return }
            self.hub?.endpoint(self, didEmit: event)
        }
        new.onSourcedPointerDelta = { [weak self] delta in
            guard let self else { return }
            self.hub?.endpoint(self, didMove: delta)
        }
        new.onReconfigurationNeeded = { [weak self] in
            self?.scheduleReconfigure("Mouse reported a reconnect")
        }
        new.onBatteryChange = { [weak self] _ in self?.publishSnapshot() }
    }

    /// Every path that drops or replaces a session goes through here, so held buttons are
    /// always released first.
    private func replaceSession(with new: DeviceSession?) {
        if let old = session, old !== new {
            old.releaseAll()
            old.onButtonEvent = nil
            old.onPointerDelta = nil
            old.onSourcedPointerDelta = nil
            old.onReconfigurationNeeded = nil
            old.onBatteryChange = nil
        }
        session = new
        configuredAt = nil
    }

    private func dropSession() {
        replaceSession(with: nil)
    }

    private func markConfigured() {
        retryAttempt = 0
        cancelRetry()
        configuredAt = Date()
        if let snapshot = session?.snapshot { transition(.connected(snapshot)) }
        startBatteryRefresh()
    }

    /// The mouse stopped answering. Keep the session (its buttons stay diverted on the device
    /// until it powers off), release anything held, and retry with backoff.
    private func becameUnreachable(_ session: DeviceSession, _ error: Error) {
        // Once per absence: the retries that follow are logged by `scheduleRetry`.
        switch state {
        case .asleep, .failed: break
        default: log("The mouse isn't answering (\(error)); will retry")
        }
        linkWasLost = true
        session.releaseAll()
        session.invalidateAppliedState()
        if isRefusedByTransport(error) {
            // Retrying on this interface won't help: macOS refuses reports on a handle that went
            // stale (a Bluetooth mouse after the Mac slept). `.failed` lets the owner reopen it.
            transition(.failed(Self.reportsRefusedMessage))
        } else if let snapshot = session.snapshot {
            transition(.asleep(snapshot))
        }
        scheduleRetry()
    }

    /// macOS refused to send a report to a directly connected mouse. A receiver's slot can be
    /// asleep behind a working interface, so this only counts on a direct link.
    private func isRefusedByTransport(_ error: Error) -> Bool {
        guard !isReceiver, case HIDPPError.sendFailed = error else { return false }
        return true
    }

    private static var reportsRefusedMessage: String {
        NSLocalizedString("macOS isn't accepting reports for the mouse; opening it again", comment: "Connection status shown when macOS refuses HID reports for a Bluetooth or USB mouse")
    }

    // MARK: Events

    /// A report from the mouse while it isn't configured means it's awake: act on it now
    /// instead of waiting for the next retry.
    private func noteActivity(from message: HIDPPMessage) {
        // Late replies and errors for our own requests carry our software ID or an error sub-ID.
        guard message.softwareID == 0, message.subID != 0x8F, message.subID != 0xFF else { return }
        guard message.deviceIndex == address.index else { return }
        switch state {
        case .waitingForDevice, .asleep, .failed: break
        case .probing, .connected, .unsupported: return
        }
        guard !isWorkingOnLink else { return }
        if isReceiver, session == nil {
            log("Slot \(address.index) sent a report; checking the device there")
            scheduleConnect()
            return
        }
        scheduleReconfigure("The mouse sent a report; reconfiguring")
    }

    private func scheduleConnect() {
        cancelRetry()
        enqueue(.connect) { await $0.connectAnnounced() }
    }

    // MARK: Helpers

    private var canWork: Bool { !isShutDown && !client.isClosed }

    private var isReceiver: Bool {
        if case .receiver = kind { return true }
        return false
    }

    private static func isConnected(_ state: State) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private func transition(_ new: State) {
        guard !isShutDown else { return }
        state = new
    }

    private func publishSnapshot() {
        guard let snapshot = session?.snapshot else { return }
        switch state {
        case .connected: transition(.connected(snapshot))
        case .asleep: transition(.asleep(snapshot))
        default: break
        }
    }

    private func log(_ text: String) {
        hub?.endpoint(self, log: text)
    }

    static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    static func describe(_ cids: Set<UInt16>) -> String {
        cids.isEmpty ? "none" : cids.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", ")
    }
}

// MARK: - Legacy facade

/// The single-mouse controller of Upright 2.x, kept so `DeviceManager` and `upright-probe`
/// build unchanged until they move to `HIDPPLink` (Wave 4). A facade over a private hub:
///
/// - Every mouse on the interface is served (there is no name gate any more); each gets the
///   one desired diversion, raw XY set and pointer speed set here.
/// - `state` and `snapshot` follow the primary endpoint (connected, else asleep, else probing,
///   else waiting, lowest slot first). Unsupported devices are never primary; with no other
///   endpoint the state is `.probing` during discovery and `.waitingForDevice` afterwards.
/// - Events from every endpoint are delivered stamped `.unassigned`, as before.
/// - `cycleDPI` and `switchToHost` act on the primary endpoint.
///
/// Its `State` has no `.unsupported` case, so code switching over it exhaustively keeps
/// compiling; `EndpointController.State` is the multi-device state.
@MainActor
public final class MXVerticalController {
    public enum State: Hashable, Sendable {
        case probing
        /// No mouse is answering yet (off, asleep, or paired elsewhere). Retried automatically.
        case waitingForDevice
        case connected(DeviceSnapshot)
        /// The mouse stopped answering; it is reconfigured as soon as it answers again.
        case asleep(DeviceSnapshot)
        /// The device can't be used right now. `.failed("Disconnected")` (transport closed) is terminal.
        case failed(String)
    }

    /// The hub behind the facade (link number 0).
    public let link: HIDPPLink
    public var client: HIDPPClient { link.client }
    public var kind: TransportKind { link.kind }

    public private(set) var state: State = .probing {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    public private(set) var desiredDiversion: Set<UInt16> = []
    public private(set) var desiredRawXY: Set<UInt16> = []
    /// The pointer speed kept across reconnects; see `EndpointController.desiredDPI`.
    public private(set) var desiredDPI: Int? {
        didSet { if desiredDPI != oldValue { onDesiredDPIChange?(desiredDPI) } }
    }
    /// Set by `shutdown()` or when the transport closes. No further work runs afterwards.
    public var isShutDown: Bool { link.isShutDown || link.isClosed }

    public var onStateChange: ((State) -> Void)?
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw movement (dx, dy) while a raw-XY control is held.
    public var onPointerDelta: ((Int, Int) -> Void)?
    /// `desiredDPI` changed: set through the API, by `cycleDPI`, or adopted from the mouse.
    public var onDesiredDPIChange: ((Int?) -> Void)?
    public var onLog: ((String) -> Void)?

    public var probeTimeout: TimeInterval {
        get { link.tuning.probeTimeout }
        set { link.tuning.probeTimeout = newValue }
    }
    public var reconnectDelay: TimeInterval {
        get { link.tuning.reconnectDelay }
        set { link.tuning.reconnectDelay = newValue }
    }
    public var retryBaseDelay: TimeInterval {
        get { link.tuning.retryBaseDelay }
        set { link.tuning.retryBaseDelay = newValue }
    }
    public var retryMaxDelay: TimeInterval {
        get { link.tuning.retryMaxDelay }
        set { link.tuning.retryMaxDelay = newValue }
    }
    public var retryMaxDelayWithNotifications: TimeInterval {
        get { link.tuning.retryMaxDelayWithNotifications }
        set { link.tuning.retryMaxDelayWithNotifications = newValue }
    }
    public var batteryRefreshInterval: TimeInterval {
        get { link.tuning.batteryRefreshInterval }
        set { link.tuning.batteryRefreshInterval = newValue }
    }
    public var announcementWait: TimeInterval {
        get { link.tuning.announcementWait }
        set { link.tuning.announcementWait = newValue }
    }

    public init(transport: HIDPPTransport, kind: TransportKind) {
        link = HIDPPLink(transport: transport, kind: kind, link: 0)
        link.configurationProvider = { [weak self] _, _ in
            guard let self else { return .native }
            return EndpointConfiguration(divert: self.desiredDiversion, rawXY: self.desiredRawXY, dpi: self.desiredDPI)
        }
        link.onEndpointChange = { [weak self] _, _ in self?.recomputeState() }
        link.onEndpointRemoved = { [weak self] _, _ in self?.recomputeState() }
        link.onDiscoveryChange = { [weak self] in self?.recomputeState() }
        link.onButtonEvent = { [weak self] event in
            var event = event
            event.source = .unassigned
            self?.onButtonEvent?(event)
        }
        link.onPointerDelta = { [weak self] delta in self?.onPointerDelta?(delta.dx, delta.dy) }
        link.onAnyDesiredDPIChange = { [weak self] _, dpi in self?.desiredDPI = dpi }
        link.onLog = { [weak self] _, text in self?.onLog?(text) }
    }

    public var snapshot: DeviceSnapshot? { primary?.snapshot }

    public func start() {
        link.start()
        recomputeState()
    }

    /// Re-applies configuration (after the Mac wakes, or on request).
    public func refresh() {
        link.refresh()
    }

    public func setDesiredDiversion(_ cids: Set<UInt16>) {
        guard cids != desiredDiversion else { return }
        desiredDiversion = cids
        link.orderedEndpoints.forEach { $0.setDesiredDiversion(cids) }
    }

    /// Controls that should report raw movement (through `onPointerDelta`) while held; they
    /// are diverted as well.
    public func setDesiredRawXY(_ cids: Set<UInt16>) {
        guard cids != desiredRawXY else { return }
        desiredRawXY = cids
        link.orderedEndpoints.forEach { $0.setDesiredRawXY(cids) }
    }

    public func setDPI(_ value: Int) {
        setDesiredDPI(value)
    }

    public func setDesiredDPI(_ value: Int?) {
        desiredDPI = value.map { snapshot?.dpi?.nearest(to: $0) ?? $0 }
        link.orderedEndpoints.forEach { $0.setDesiredDPI(value) }
    }

    public func cycleDPI(presets: [Int] = []) {
        primary?.cycleDPI(presets: presets)
    }

    public func refreshDPI() {
        link.orderedEndpoints.forEach { $0.refreshDPI() }
    }

    public func refreshDeviceInfo() {
        link.refreshDeviceInfo(at: nil)
    }

    public func switchToHost(_ index: Int) {
        guard let primary else {
            onLog?("No connected mouse to switch")
            return
        }
        primary.switchToHost(index)
    }

    /// Hands every diverted button back to its mouse without waiting for replies. Terminal.
    public func shutdown() {
        link.shutdown()
        recomputeState()
    }

    public func waitUntilIdle() async {
        await link.waitUntilIdle()
    }

    // MARK: Primary endpoint

    private var primary: EndpointController? {
        var best: (endpoint: EndpointController, rank: Int)?
        for endpoint in link.orderedEndpoints {
            guard let rank = Self.rank(endpoint.state) else { continue }
            if best == nil || rank > best!.rank { best = (endpoint, rank) }
        }
        return best?.endpoint
    }

    private static func rank(_ state: EndpointController.State) -> Int? {
        switch state {
        case .connected: return 5
        case .asleep: return 4
        case .probing: return 3
        case .waitingForDevice: return 2
        case .failed: return 1
        case .unsupported: return nil
        }
    }

    private func recomputeState() {
        if link.isClosed {
            state = .failed("Disconnected")
            return
        }
        guard let primary else {
            state = !link.isStarted || link.isDiscovering ? .probing : .waitingForDevice
            return
        }
        switch primary.state {
        case .probing: state = .probing
        case .waitingForDevice: state = .waitingForDevice
        case .connected(let snapshot): state = .connected(snapshot)
        case .asleep(let snapshot): state = .asleep(snapshot)
        case .failed(let message): state = .failed(message)
        case .unsupported: state = .waitingForDevice
        }
    }
}
