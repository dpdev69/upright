import Foundation

/// Owns one HID interface (receiver or directly connected mouse) and keeps an MX Vertical on it
/// configured: finds the mouse, applies button diversion, and re-applies it whenever the mouse
/// wakes up, reconnects, or the Mac resumes from sleep.
@MainActor
public final class MXVerticalController {
    public enum State: Hashable, Sendable {
        case probing
        /// A receiver is attached but no MX Vertical is answering (off, asleep, or paired elsewhere).
        case waitingForDevice
        case connected(DeviceSnapshot)
        /// The mouse dropped its wireless link; it will be reconfigured when it comes back.
        case asleep(DeviceSnapshot)
        case failed(String)
    }

    public let client: HIDPPClient
    public let kind: TransportKind

    public private(set) var state: State = .probing {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var desiredDiversion: Set<UInt16> = []

    public var onStateChange: ((State) -> Void)?
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    public var onLog: ((String) -> Void)?

    /// How long to wait for a receiver slot to answer during discovery.
    public var probeTimeout: TimeInterval = 1.0
    /// Pause before reconfiguring a mouse that just woke up, so it can finish reconnecting.
    public var reconnectDelay: TimeInterval = 0.6

    private var session: DeviceSession?
    private var lastOperation: Task<Void, Never>?

    public init(transport: HIDPPTransport, kind: TransportKind) {
        self.kind = kind
        self.client = HIDPPClient(transport: transport)
        client.onUnsolicited = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        client.onClose = { [weak self] in
            Task { @MainActor in self?.transportClosed() }
        }
    }

    public var snapshot: DeviceSnapshot? { session?.snapshot }

    // MARK: Public API

    public func start() {
        enqueue { await $0.probe() }
    }

    /// Re-applies configuration (after the Mac wakes, or on request). Falls back to a full
    /// re-probe when the mouse isn't answering.
    public func refresh() {
        enqueue { await $0.reconfigure() }
    }

    public func setDesiredDiversion(_ cids: Set<UInt16>) {
        guard cids != desiredDiversion else { return }
        desiredDiversion = cids
        enqueue { controller in
            guard let session = controller.session, case .connected = controller.state else { return }
            do {
                try await session.applyDiversion(cids)
                controller.log("Diverted controls: \(Self.describe(session.divertedControls))")
            } catch {
                controller.log("Could not update diversion: \(error)")
            }
        }
    }

    /// Hands every diverted button back to the mouse without waiting for replies, then closes.
    public func shutdown() {
        session?.releaseAll()
        session?.restoreMessages().forEach(client.sendWithoutReply)
        client.close()
    }

    /// Waits until every queued operation has finished. Mainly useful in tests.
    public func waitUntilIdle() async {
        while let operation = lastOperation {
            await operation.value
            if operation == lastOperation { break }
        }
    }

    // MARK: Operations

    private func enqueue(_ operation: @escaping @MainActor (MXVerticalController) async -> Void) {
        let previous = lastOperation
        lastOperation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    private func probe() async {
        state = .probing
        switch kind {
        case .direct(let connection):
            log("Probing MX Vertical over \(connection.title)")
            if !(await connect(index: 0xFF)) {
                state = .failed("The MX Vertical didn't answer HID++ requests. Try clicking a button to wake it, then choose Reconnect.")
            }
        case .receiver(let connection):
            log("Probing \(connection.title)")
            await enableReceiverNotifications()
            for slot in UInt8(1)...6 {
                let device = HIDPPDevice(client: client, index: slot)
                do {
                    let version = try await device.protocolVersion(timeout: probeTimeout)
                    guard version.major >= 2 else {
                        log("Slot \(slot): HID++ \(version.major).\(version.minor) device, skipping")
                        continue
                    }
                    let name = (try? await device.name()) ?? "unknown device"
                    guard MXVertical.matches(name: name) else {
                        log("Slot \(slot): \(name), skipping")
                        continue
                    }
                    log("Slot \(slot): \(name)")
                    if await connect(index: slot) { return }
                } catch let error as HIDPPError where error.meansDeviceUnreachable {
                    continue
                } catch {
                    log("Slot \(slot): \(error)")
                }
            }
            log("No MX Vertical is answering on the receiver yet")
            state = .waitingForDevice
        }
    }

    private func connect(index: UInt8) async -> Bool {
        let session = DeviceSession(device: HIDPPDevice(client: client, index: index), connection: kind.connection)
        session.onButtonEvent = { [weak self] event in self?.onButtonEvent?(event) }
        session.onReconfigurationNeeded = { [weak self] in
            self?.log("Mouse reported a reconnect")
            self?.refresh()
        }
        session.onBatteryChange = { [weak self] _ in self?.publishSnapshot() }
        do {
            let snapshot = try await session.start()
            if isReceiver, !MXVertical.matches(name: snapshot.name) {
                throw HIDPPError.notMXVertical(snapshot.name)
            }
            self.session = session
            log("Connected to \(snapshot.name) (HID++ \(snapshot.protocolVersion), \(snapshot.controls.count) controls)")
            try await session.applyDiversion(desiredDiversion, force: true)
            log("Diverted controls: \(Self.describe(session.divertedControls))")
            publishSnapshot()
            return true
        } catch {
            log("Setup failed: \(error)")
            return false
        }
    }

    private func reconfigure() async {
        guard let session else {
            await probe()
            return
        }
        await pauseForReconnect()
        do {
            try await session.applyDiversion(desiredDiversion, force: true)
            await session.refreshBattery()
            log("Reapplied configuration")
            publishSnapshot()
        } catch let error as HIDPPError where error.meansDeviceUnreachable && isReceiver {
            log("Mouse is not reachable yet: \(error)")
            if let snapshot = session.snapshot { state = .asleep(snapshot) }
        } catch {
            log("Reconfiguration failed (\(error)); probing again")
            self.session = nil
            await probe()
        }
    }

    private func enableReceiverNotifications() async {
        // HID++ 1.0 register 0x00: enable wireless (0x000100) and software-present (0x000800) notifications.
        let write = HIDPPMessage(reportID: .short, deviceIndex: 0xFF, subID: 0x80, address: 0x00, parameters: [0x00, 0x09, 0x00])
        do {
            _ = try await client.send(write, timeout: probeTimeout)
        } catch {
            log("Receiver notifications unavailable: \(error)")
        }
    }

    // MARK: Events

    private func handle(_ message: HIDPPMessage) {
        if isReceiver, message.subID == 0x41, (1...6).contains(message.deviceIndex) {
            handleConnectionNotification(message)
            return
        }
        _ = session?.handle(message)
    }

    /// HID++ 1.0 device-connection notification: params[0] bit 6 set = link lost,
    /// params[1...2] = wireless PID (little-endian).
    private func handleConnectionNotification(_ message: HIDPPMessage) {
        let slot = message.deviceIndex
        let linkUp = message.parameters[0] & 0x40 == 0
        let wirelessPID = UInt16(message.parameters[2]) << 8 | UInt16(message.parameters[1])

        if let session, session.device.index == slot {
            if linkUp {
                log("Slot \(slot) link restored")
                session.invalidateAppliedState()
                refresh()
            } else {
                log("Slot \(slot) link lost")
                session.releaseAll()
                if let snapshot = session.snapshot { state = .asleep(snapshot) }
            }
        } else if session == nil, linkUp, wirelessPID == MXVertical.wirelessProductID || wirelessPID == 0 {
            log(String(format: "Slot %d connected (wireless PID %04X)", slot, wirelessPID))
            enqueue { controller in
                guard controller.session == nil else { return }
                await controller.pauseForReconnect()
                if !(await controller.connect(index: slot)) { controller.state = .waitingForDevice }
            }
        }
    }

    private func pauseForReconnect() async {
        guard reconnectDelay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
    }

    private var isReceiver: Bool {
        if case .receiver = kind { return true }
        return false
    }

    private func transportClosed() {
        session?.releaseAll()
        session = nil
        state = .failed("Disconnected")
    }

    private func publishSnapshot() {
        guard let snapshot = session?.snapshot else { return }
        state = .connected(snapshot)
    }

    private func log(_ text: String) {
        onLog?(text)
    }

    static func describe(_ cids: Set<UInt16>) -> String {
        cids.isEmpty ? "none" : cids.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", ")
    }
}
