import Foundation

/// Owns one HID interface (receiver or directly connected mouse) and keeps an MX Vertical on it
/// configured: finds the mouse, applies button diversion, and re-applies it whenever the mouse
/// wakes up, reconnects, or the Mac resumes from sleep.
///
/// Everything that talks to the device runs on one serial operation queue, so probes,
/// reconfigurations and mapping changes never interleave. While the transport is open the
/// controller never gives up: a mouse that stops answering is retried with exponential backoff,
/// and any report it sends in the meantime triggers a reconfiguration right away. Closing the
/// transport or calling `shutdown()` is terminal.
@MainActor
public final class MXVerticalController {
    public enum State: Hashable, Sendable {
        case probing
        /// No MX Vertical is answering yet (off, asleep, or paired elsewhere). Retried automatically.
        case waitingForDevice
        case connected(DeviceSnapshot)
        /// The mouse stopped answering; it is reconfigured as soon as it answers again.
        case asleep(DeviceSnapshot)
        /// The device can't be used right now. `.failed("Disconnected")` (transport closed) is terminal.
        case failed(String)
    }

    public let client: HIDPPClient
    public let kind: TransportKind

    public private(set) var state: State = .probing {
        didSet {
            guard state != oldValue else { return }
            // Leaving `.connected`: whatever was held can't be released by the mouse any more.
            // A new snapshot while connected (battery, speed) must not release held buttons.
            if case .connected = oldValue, !Self.isConnected(state) {
                session?.releaseAll()
            }
            onStateChange?(state)
        }
    }
    public private(set) var desiredDiversion: Set<UInt16> = []
    /// Controls that report raw pointer movement while held (always diverted too).
    public private(set) var desiredRawXY: Set<UInt16> = []
    /// The pointer speed to keep. Many mice forget a speed set over HID++ when they reconnect,
    /// so it is re-applied when the mouse comes back at its default speed. A mouse that comes
    /// back at another speed had it changed with its top button, and that speed is adopted
    /// instead. Nil leaves the mouse's own setting alone.
    public private(set) var desiredDPI: Int? {
        didSet { if desiredDPI != oldValue { onDesiredDPIChange?(desiredDPI) } }
    }
    /// Set by `shutdown()` or when the transport closes. No further work runs afterwards.
    public private(set) var isShutDown = false

    public var onStateChange: ((State) -> Void)?
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw movement (dx, dy) while a raw-XY control is held.
    public var onPointerDelta: ((Int, Int) -> Void)?
    /// `desiredDPI` changed: set through the API, by `cycleDPI`, or adopted from the mouse (by
    /// `refreshDPI()` or a reconnect) after the top button changed the speed natively.
    public var onDesiredDPIChange: ((Int?) -> Void)?
    public var onLog: ((String) -> Void)?

    /// How long to wait for a receiver slot to answer during discovery.
    public var probeTimeout: TimeInterval = 1.0
    /// Pause before reconfiguring a mouse that just woke up, so it can finish reconnecting.
    /// Wake-up signals that arrive within this window are coalesced into one pass.
    public var reconnectDelay: TimeInterval = 0.6
    /// First retry delay while the mouse doesn't answer; doubles per attempt up to `retryMaxDelay`.
    public var retryBaseDelay: TimeInterval = 1
    public var retryMaxDelay: TimeInterval = 30
    /// How often the battery level is re-read while connected (0 disables).
    public var batteryRefreshInterval: TimeInterval = 600
    /// How long to listen for slot announcements when a receiver can't list its pairings.
    public var announcementWait: TimeInterval = 0.3

    private var session: DeviceSession?
    private var started = false

    private enum OperationKey: Hashable {
        case probe, reconfigure, recover, diversion, battery, dpi, deviceInfo
        case connect(UInt8)
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
        let body: @MainActor (MXVerticalController) async -> Void
    }

    private var queue: [Operation] = []
    private var runner: Task<Void, Never>?
    private var currentKey: OperationKey?

    private var reconfigureTimer: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var retryAttempt = 0
    private var batteryTimer: Task<Void, Never>?
    private var cycleRequests = 0

    // Receiver bookkeeping.
    /// Wireless PIDs per slot, from the pairing register and 0x41 notifications.
    private var slotPIDs: [UInt8: UInt16] = [:]
    /// Slots that answered with another device's name.
    private var otherDeviceSlots: Set<UInt8> = []
    private var notificationsEnabled = false
    private var heardAnnouncement = false
    private var announcementsRequestedAt: Date?
    private var configuredAt: Date?

    public init(transport: HIDPPTransport, kind: TransportKind) {
        self.kind = kind
        self.client = HIDPPClient(transport: transport)
        client.onUnsolicited = { [weak self] message in
            MainActorDelivery.run { self?.handle(message) }
        }
        client.onClose = { [weak self] in
            MainActorDelivery.run { self?.transportClosed() }
        }
    }

    public var snapshot: DeviceSnapshot? { session?.snapshot }

    // MARK: Public API

    public func start() {
        guard !started else { return }
        started = true
        enqueue(.probe) { await $0.probe() }
    }

    /// Re-applies configuration (after the Mac wakes, or on request). Falls back to a full
    /// re-probe when no mouse has been found yet.
    public func refresh() {
        retryAttempt = 0
        scheduleReconfigure(nil)
    }

    public func setDesiredDiversion(_ cids: Set<UInt16>) {
        guard cids != desiredDiversion else { return }
        desiredDiversion = cids
        scheduleDiversionUpdate()
    }

    /// Controls that should report raw movement (dx, dy through `onPointerDelta`) instead of
    /// moving the pointer while held. They are diverted as well, whatever `desiredDiversion` says.
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
        desiredDPI = value.map { snapshot?.dpi?.nearest(to: $0) ?? $0 }
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
                // The top button may have changed the speed natively since we last looked.
                try await session.refreshDPI()
                guard let dpi = session.snapshot?.dpi else {
                    controller.log("This mouse can't change its pointer speed")
                    return
                }
                controller.desiredDPI = dpi.nextPreset(after: dpi.current, presets: presets)
                try await controller.applyDesiredDPI(to: session)
            }
        }
    }

    /// Re-reads the pointer speed. A speed that differs from `desiredDPI` was changed on the
    /// mouse (its top button cycles speeds natively when not diverted) and becomes the new
    /// `desiredDPI`. Meant for when the UI is about to show it.
    public func refreshDPI() {
        enqueue(.dpi) { controller in
            await controller.withConnectedSession("read the pointer speed") { session in
                try await controller.refreshDPI(of: session, adopting: true)
            }
        }
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

    /// Stops all work, hands every diverted button back to the mouse without waiting for
    /// replies, then closes the client. Terminal.
    public func shutdown() {
        guard !isShutDown else { return }
        stopAllWork()
        if let session {
            session.releaseAll()
            session.restoreMessages().forEach(client.sendWithoutReply)
        }
        client.close()
    }

    /// Waits until every queued operation has finished. Mainly useful in tests.
    public func waitUntilIdle() async {
        while let runner {
            await runner.value
        }
    }

    // MARK: Operation queue

    private func enqueue(_ key: OperationKey, _ body: @escaping @MainActor (MXVerticalController) async -> Void) {
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
        guard !isShutDown else { return }
        cancelRetry()
        guard reconfigureTimer == nil else { return }
        if let reason { log(reason) }
        let delay = reconnectDelay
        reconfigureTimer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: Self.nanoseconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.reconfigureTimer = nil
            self.enqueue(.reconfigure) { await $0.reconfigure() }
        }
    }

    /// Exponential backoff, capped at `retryMaxDelay`. Never gives up while the transport is open.
    private func scheduleRetry() {
        guard !isShutDown, retryTimer == nil else { return }
        let delay = min(retryBaseDelay * pow(2, Double(min(retryAttempt, 16))), retryMaxDelay)
        retryAttempt += 1
        if delay < retryMaxDelay || retryAttempt <= 1 || retryAttempt % 10 == 0 {
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
        guard batteryTimer == nil, batteryRefreshInterval > 0, !isShutDown else { return }
        let interval = batteryRefreshInterval
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
        guard canWork, session == nil else { return }
        cancelRetry()
        // Retries stay in the waiting state so the UI doesn't flicker on every attempt.
        if !retrying { transition(.probing) }
        switch kind {
        case .direct(let connection):
            if !retrying { log("Probing MX Vertical over \(connection.title)") }
            switch await connect(index: 0xFF) {
            case .configured, .asleep, .closed:
                return
            case .unreachable(let error):
                log("The MX Vertical isn't answering yet (\(error))")
                transition(.waitingForDevice)
            case .failed(let error):
                log("Setup failed: \(error)")
                transition(.failed(NSLocalizedString("The MX Vertical didn't answer HID++ requests. Try clicking a button to wake it, then choose Reconnect.", comment: "Connection status shown when setup fails")))
            }
            scheduleRetry()
        case .receiver(let connection):
            if !retrying { log("Probing \(connection.title)") }
            await probeReceiver(retrying: retrying)
        }
    }

    private func probeReceiver(retrying: Bool) async {
        await enableReceiverNotifications()
        if !retrying || slotPIDs.isEmpty {
            if !(await readPairedDevices()), await requestSlotAnnouncements() {
                log("Receiver announced its paired devices")
            }
        }
        guard canWork, session == nil else { return }

        let knownSlots = mxSlots
        let slots = knownSlots.isEmpty ? (UInt8(1)...6).filter { !otherDeviceSlots.contains($0) } : knownSlots
        for slot in slots {
            guard canWork else { return }
            guard session == nil else { return }
            let device = HIDPPDevice(client: client, index: slot)
            do {
                let version = try await device.protocolVersion(timeout: probeTimeout)
                guard version.major >= 2 else {
                    log("Slot \(slot): HID++ \(version.major).\(version.minor) device, skipping")
                    otherDeviceSlots.insert(slot)
                    continue
                }
                guard let name = try? await device.name() else {
                    log("Slot \(slot): could not read the device name")
                    continue
                }
                guard MXVertical.matches(name: name) else {
                    log("Slot \(slot): \(name), skipping")
                    otherDeviceSlots.insert(slot)
                    continue
                }
                log("Slot \(slot): \(name)")
                switch await connect(index: slot) {
                case .configured, .asleep, .closed:
                    return
                case .unreachable(let error):
                    log("Slot \(slot) stopped answering: \(error)")
                case .failed(let error):
                    log("Slot \(slot): setup failed: \(error)")
                }
            } catch HIDPPError.transportClosed {
                return
            } catch let error as HIDPPError where error.meansDeviceUnreachable {
                continue
            } catch {
                log("Slot \(slot): \(error)")
            }
        }
        guard canWork, session == nil else { return }
        if !retrying { log("No MX Vertical is answering on the receiver yet") }
        transition(.waitingForDevice)
        // The receiver announces the mouse when it wakes (0x41). Poll only when we know which
        // slot to ask, or when the receiver can't send notifications.
        if !mxSlots.isEmpty || !notificationsEnabled {
            scheduleRetry()
        }
    }

    private enum ConnectOutcome {
        /// Connected and configured.
        case configured
        /// Found and kept, but it stopped answering before it was configured. Retried.
        case asleep
        /// Nothing answered; no session was created.
        case unreachable(Error)
        case failed(Error)
        case closed
    }

    private func connect(index: UInt8) async -> ConnectOutcome {
        let candidate = DeviceSession(device: HIDPPDevice(client: client, index: index), connection: kind.connection)
        do {
            let snapshot = try await candidate.start()
            if isReceiver, !MXVertical.matches(name: snapshot.name) {
                otherDeviceSlots.insert(index)
                throw HIDPPError.notMXVertical(snapshot.name)
            }
            guard canWork else { return .closed }
            adopt(candidate)
            log("Connected to \(snapshot.name) (HID++ \(snapshot.protocolVersion), \(snapshot.controls.count) controls)")
        } catch HIDPPError.transportClosed {
            return .closed
        } catch let error as HIDPPError where error.meansDeviceUnreachable {
            return .unreachable(error)
        } catch {
            return .failed(error)
        }

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
            return .failed(error)
        }
    }

    private func reconfigure() async {
        guard canWork else { return }
        guard let session else {
            await probe(retrying: state == .waitingForDevice)
            return
        }
        if isReceiver { await enableReceiverNotifications() }
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

    /// Connects to a slot the receiver announced (link-up) or that sent a report. Moves the
    /// session when the MX Vertical was re-paired to another slot.
    private func connectAnnounced(_ slot: UInt8) async {
        guard canWork else { return }
        if reconnectDelay > 0 {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(reconnectDelay))
            guard canWork else { return }
        }
        if let current = session {
            if current.device.index == slot { return }
            if case .connected = state, (try? await current.device.protocolVersion(timeout: probeTimeout)) != nil {
                log("Another MX Vertical came up on slot \(slot); staying on slot \(current.device.index)")
                return
            }
            guard canWork, session === current else { return }
            log("The MX Vertical moved from slot \(current.device.index) to slot \(slot)")
            dropSession()
        }
        switch await connect(index: slot) {
        case .configured, .asleep, .closed:
            return
        case .unreachable(let error):
            log("Slot \(slot) isn't answering yet: \(error)")
            transition(.waitingForDevice)
            scheduleRetry()
        case .failed(let error):
            log("Slot \(slot): \(error)")
            if session == nil { transition(.waitingForDevice) }
        }
    }

    private func applyDesiredDiversion(to session: DeviceSession, force: Bool) async throws {
        let failures = try await session.applyDiversion(desiredDiversion, rawXY: desiredRawXY, force: force)
        log("Diverted controls: \(Self.describe(session.divertedControls))")
        if !desiredRawXY.isEmpty || !session.rawXYControls.isEmpty {
            log("Raw XY controls: \(Self.describe(session.rawXYControls))")
        }
        let configurable = Set(session.snapshot?.configurableControls.map(\.cid) ?? [])
        let unsupported = desiredRawXY.intersection(configurable).subtracting(session.rawXYControls).subtracting(failures.keys)
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
            if let applied = try await session.setDPI(desired) {
                log("Pointer speed: \(applied) DPI")
            }
        } catch let error as HIDPPError where error.meansDeviceUnreachable || error == .transportClosed {
            throw error
        } catch {
            log("The mouse refused pointer speed \(desired) DPI: \(error)")
        }
    }

    /// After a (re)connect: keeps a speed chosen with the mouse's top button, or re-applies
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
            desiredDPI = dpi.current
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
        desiredDPI = current
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
            log("Could not \(action): \(error)")
        }
    }

    /// HID++ 1.0 register 0x00: enable wireless (0x000100) and software-present (0x000800) notifications.
    private func enableReceiverNotifications() async {
        let write = HIDPPMessage.receiverRegisterWrite(0x00, parameters: [0x00, 0x09, 0x00])
        do {
            _ = try await client.send(write, timeout: probeTimeout)
            notificationsEnabled = true
        } catch {
            log("Receiver notifications unavailable: \(error)")
        }
    }

    /// Unifying receivers list their pairings in register 0xB5, sub-registers 0x20...0x25:
    /// [sub-register, destination ID, report interval, wireless PID (big-endian), ...].
    /// Reading them doesn't wake any device. Returns false when no slot could be read
    /// (Bolt receivers use a different layout; the MX Vertical pairs over Unifying only).
    private func readPairedDevices() async -> Bool {
        guard case .receiver(.unifying) = kind else { return false }
        var listed = false
        for slot in UInt8(1)...6 {
            let subRegister = 0x20 + slot - 1
            do {
                let reply = try await client.send(.receiverLongRegisterRead(0xB5, parameters: [subRegister]), timeout: probeTimeout)
                guard reply.parameters[0] == subRegister else { continue }
                listed = true
                let pid = UInt16(reply.parameters[3]) << 8 | UInt16(reply.parameters[4])
                if pid != 0 { slotPIDs[slot] = pid }
            } catch HIDPPError.hidpp10(let code) where code == 0x01 || code == 0x02 {
                return false // Register not supported.
            } catch HIDPPError.hidpp10 {
                continue // Empty slot.
            } catch {
                return listed
            }
        }
        return listed
    }

    /// Register 0x02 = 0x02 makes the receiver send a 0x41 notification for every paired device.
    private func requestSlotAnnouncements() async -> Bool {
        heardAnnouncement = false
        do {
            _ = try await client.send(.receiverRegisterWrite(0x02, parameters: [0x02, 0x00, 0x00]), timeout: probeTimeout)
        } catch {
            return false
        }
        announcementsRequestedAt = Date()
        if announcementWait > 0 {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(announcementWait))
        }
        return heardAnnouncement
    }

    // MARK: Session lifecycle

    private func adopt(_ new: DeviceSession) {
        replaceSession(with: new)
        new.onButtonEvent = { [weak self] event in self?.onButtonEvent?(event) }
        new.onPointerDelta = { [weak self] dx, dy in self?.onPointerDelta?(dx, dy) }
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
        log("The mouse isn't answering (\(error)); will retry")
        session.releaseAll()
        session.invalidateAppliedState()
        if let snapshot = session.snapshot { transition(.asleep(snapshot)) }
        scheduleRetry()
    }

    private func transportClosed() {
        let wasShutDown = isShutDown
        stopAllWork()
        dropSession()
        if !wasShutDown { log("The HID connection closed") }
        state = .failed("Disconnected")
    }

    // MARK: Events

    private func handle(_ message: HIDPPMessage) {
        guard !isShutDown else { return }
        if isReceiver {
            let slot = message.deviceIndex
            guard (1...6).contains(slot) else { return }
            switch message.subID {
            case 0x41:
                handleConnectionNotification(message)
                return
            case 0x40:
                handleDisconnectionNotification(message)
                return
            default:
                break
            }
        }
        if let session, session.handle(message) {
            if case .asleep = state { scheduleReconfigure("The mouse is sending reports again") }
            return
        }
        noteActivity(from: message)
    }

    /// A report from the mouse while it isn't configured means it's awake: act on it now
    /// instead of waiting for the next retry.
    private func noteActivity(from message: HIDPPMessage) {
        // Late replies and errors for our own requests carry our software ID or an error sub-ID.
        guard message.softwareID == 0, message.subID != 0x8F, message.subID != 0xFF else { return }
        switch state {
        case .waitingForDevice, .asleep, .failed: break
        case .probing, .connected: return
        }
        guard !isWorkingOnLink else { return }
        if isReceiver {
            let slot = message.deviceIndex
            guard !otherDeviceSlots.contains(slot) else { return }
            if let session {
                guard session.device.index == slot else { return }
            } else {
                log("Slot \(slot) sent a report; checking for an MX Vertical there")
                scheduleConnect(slot)
                return
            }
        } else if message.deviceIndex != 0xFF {
            return
        }
        scheduleReconfigure("The mouse sent a report; reconfiguring")
    }

    /// HID++ 1.0 device-connection notification: params[0] bit 6 set = link lost,
    /// params[1...2] = wireless PID (little-endian).
    private func handleConnectionNotification(_ message: HIDPPMessage) {
        let slot = message.deviceIndex
        let linkUp = message.parameters[0] & 0x40 == 0
        let wirelessPID = UInt16(message.parameters[2]) << 8 | UInt16(message.parameters[1])
        heardAnnouncement = true
        if wirelessPID != 0 {
            slotPIDs[slot] = wirelessPID
            if wirelessPID == MXVertical.wirelessProductID { otherDeviceSlots.remove(slot) }
        }

        if let session, session.device.index == slot {
            if linkUp {
                if isEchoOfAnnouncementRequest { return }
                session.invalidateAppliedState()
                scheduleReconfigure("Slot \(slot) link restored")
            } else {
                log("Slot \(slot) link lost")
                session.releaseAll()
                if let snapshot = session.snapshot { transition(.asleep(snapshot)) }
            }
            return
        }

        let mightBeMX = wirelessPID == MXVertical.wirelessProductID || (wirelessPID == 0 && !otherDeviceSlots.contains(slot))
        guard linkUp, mightBeMX else { return }
        log(String(format: "Slot %d connected (wireless PID %04X)", slot, wirelessPID))
        scheduleConnect(slot)
    }

    /// HID++ 1.0 device-disconnection notification; address bit 1 = un-paired.
    private func handleDisconnectionNotification(_ message: HIDPPMessage) {
        let slot = message.deviceIndex
        guard message.address & 0x02 != 0 else { return }
        slotPIDs[slot] = nil
        otherDeviceSlots.remove(slot)
        guard let session, session.device.index == slot else { return }
        log("The MX Vertical in slot \(slot) was unpaired")
        dropSession()
        transition(.waitingForDevice)
    }

    private func scheduleConnect(_ slot: UInt8) {
        cancelRetry()
        enqueue(.connect(slot)) { await $0.connectAnnounced(slot) }
    }

    /// Receivers answer an announcement request with a 0x41 for every paired device, including
    /// the one we just configured. Those aren't real reconnects.
    private var isEchoOfAnnouncementRequest: Bool {
        guard case .connected = state, let requested = announcementsRequestedAt, let configuredAt else { return false }
        return configuredAt > requested && Date().timeIntervalSince(requested) < 2
    }

    // MARK: Helpers

    private var canWork: Bool { !isShutDown && !client.isClosed }

    private var mxSlots: [UInt8] {
        slotPIDs.filter { $0.value == MXVertical.wirelessProductID }.keys.sorted()
    }

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
        onLog?(text)
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    static func describe(_ cids: Set<UInt16>) -> String {
        cids.isEmpty ? "none" : cids.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", ")
    }
}
