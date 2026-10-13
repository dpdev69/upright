import AppKit
import IOKit.hid

/// Finds MX Vertical connections through IOKit and keeps one `MXVerticalController` per
/// HID++ interface. Publishes a single, user-facing status for the UI.
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

    struct LogEntry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let text: String
        let isTraffic: Bool
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var log: [LogEntry] = []
    /// Raw HID++ traffic is only formatted (and its handler installed) while this is on.
    @Published var logsTraffic = false {
        didSet {
            guard logsTraffic != oldValue else { return }
            entries.values.forEach { installTrafficLogging(on: $0.controller) }
        }
    }

    /// The pointer speed kept across reconnects (nil leaves the mouse's own setting alone).
    /// Changes when set here, by Cycle Pointer Speed, or when the mouse's top button changed it
    /// natively and `refreshDeviceInfo()` or a reconnect noticed. Persist it and restore it with
    /// `setDesiredDPI`.
    @Published private(set) var desiredDPI: Int?

    var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw movement (dx, dy) while a control set with `setDesiredRawXY` is held.
    var onPointerDelta: ((Int, Int) -> Void)?

    private struct Entry {
        let transport: IOKitHIDTransport
        let controller: MXVerticalController
        let kind: TransportKind
    }

    private let monitor = HIDDeviceMonitor()
    private var entries: [IOHIDDevice: Entry] = [:]
    private var desiredDiversion: Set<UInt16> = []
    private var desiredRawXY: Set<UInt16> = []
    /// Only set when macOS actually refused access: IOHIDManagerOpen or a device open returned
    /// "not permitted". An empty device list just means no mouse is connected.
    private var accessDenied = false
    private var failedRecoveries = 0
    private var recoveryTask: Task<Void, Never>?
    private var nextLogID = 0
    private var observers: [NSObjectProtocol] = []
    private static let maxLogEntries = 400
    private static let maxRecoveries = 3

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

    /// The controls to show in the UI: what the mouse reports, or the MX Vertical's known
    /// buttons when no mouse has been seen yet.
    var controls: [ControlDescriptor] {
        let cids = snapshot?.configurableControls.map(\.cid) ?? KnownControl.mxVerticalDefaults
        let order = KnownControl.mxVerticalDefaults
        return cids
            .sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs) ?? Int.max
                let r = order.firstIndex(of: rhs) ?? Int.max
                return l == r ? lhs < rhs : l < r
            }
            .map(ControlDescriptor.init(cid:))
    }

    func start() {
        monitor.onMatch = { [weak self] device in
            MainActorDelivery.run { self?.attach(device) }
        }
        monitor.onRemove = { [weak self] device in
            MainActorDelivery.run { self?.detach(device, removed: true) }
        }
        // No Input Monitoring prompt here: the vendor HID++ interfaces usually open without it.
        // The UI offers `requestInputMonitoringAccess()` when access is actually refused.
        openMonitor()
        append("Watching for MX Vertical over USB, Unifying receivers and Bluetooth")

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActorDelivery.run { self?.systemDidWake() }
            })
        }
        recomputeStatus()
    }

    func setDesiredDiversion(_ cids: Set<UInt16>) {
        desiredDiversion = cids
        entries.values.forEach { $0.controller.setDesiredDiversion(cids) }
    }

    /// Controls that report raw movement through `onPointerDelta` while held (diverted as well).
    func setDesiredRawXY(_ cids: Set<UInt16>) {
        desiredRawXY = cids
        entries.values.forEach { $0.controller.setDesiredRawXY(cids) }
    }

    // MARK: Device actions

    func perform(_ action: DeviceAction) {
        guard action.isValid else {
            append("Ignoring invalid device action: \(action.title)")
            return
        }
        switch action {
        case .cycleDPI: cycleDPI()
        case .setDPI(let dpi): setDPI(dpi)
        case .switchHost(let host): switchToHost(host - 1)
        }
    }

    /// Sets the pointer speed now (snapped to what the mouse supports) and keeps it across reconnects.
    func setDPI(_ value: Int) {
        setDesiredDPI(value)
    }

    /// Restores or clears the kept pointer speed. A value is applied as soon as a mouse is connected.
    func setDesiredDPI(_ value: Int?) {
        desiredDPI = value
        entries.values.forEach { $0.controller.setDesiredDPI(value) }
    }

    /// Steps to the next pointer-speed preset; empty `presets` uses four evenly spaced speeds.
    func cycleDPI(presets: [Int] = []) {
        guard let controller = connectedController else {
            append("Cycle Pointer Speed: no mouse is connected")
            return
        }
        controller.cycleDPI(presets: presets)
    }

    /// Easy-Switch to a zero-based channel. The mouse disconnects from this Mac right away.
    func switchToHost(_ index: Int) {
        guard let controller = connectedController else {
            append("Easy-Switch: no mouse is connected")
            return
        }
        controller.switchToHost(index)
    }

    /// Re-reads battery, pointer speed and Easy-Switch channel (e.g. when the menu opens). The top
    /// button changes the speed without telling us when it isn't diverted.
    func refreshDeviceInfo() {
        entries.values
            .filter { if case .connected = $0.controller.state { return true } else { return false } }
            .forEach { $0.controller.refreshDeviceInfo() }
    }

    private var connectedController: MXVerticalController? {
        entries.values.first { if case .connected = $0.controller.state { return true } else { return false } }?.controller
    }

    /// A controller changed its kept speed (cycle, or a change noticed on the mouse).
    private func controller(_ controller: MXVerticalController, didChangeDesiredDPI value: Int?) {
        guard value != desiredDPI, entries.values.contains(where: { $0.controller === controller }) else { return }
        desiredDPI = value
        entries.values.filter { $0.controller !== controller }.forEach { $0.controller.setDesiredDPI(value) }
    }

    /// Drops every open interface and matches the mouse again. A Bluetooth re-pair
    /// keeps the same serial but the old IOHIDDevice stops answering.
    func reconnect() {
        append("Reconnecting")
        failedRecoveries = 0
        restartMonitoring()
    }

    /// Shows the Input Monitoring prompt the first time (macOS only asks once) and reconnects
    /// when access is granted. Meant for an explicit button in the UI. Returns whether access
    /// is granted; when it isn't, the caller should point the user to System Settings.
    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        let granted = HIDDeviceMonitor.requestInputMonitoringAccess()
        if granted, accessDenied || entries.isEmpty {
            reconnect()
        }
        return granted
    }

    /// The open HID interface can be the pre-repair device. Matching again picks up the live one.
    /// Controllers keep retrying on their own; this only re-matches a few times.
    private func scheduleRecovery() {
        guard recoveryTask == nil, failedRecoveries < Self.maxRecoveries else { return }
        failedRecoveries += 1
        let delay = UInt64(failedRecoveries) * 700_000_000
        append("HID++ did not answer; looking for the mouse again")
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard !self.isConnected else { return }
            self.restartMonitoring()
        }
    }

    private func restartMonitoring() {
        recoveryTask?.cancel()
        recoveryTask = nil
        for device in Array(entries.keys) {
            detach(device, removed: false)
        }
        monitor.stop()
        accessDenied = false
        openMonitor()
        recomputeStatus()
    }

    private func openMonitor() {
        let result = monitor.start()
        guard result != kIOReturnSuccess else { return }
        append(String(format: "IOHIDManagerOpen returned 0x%08X", UInt32(bitPattern: result)))
        if (result == IOKitReturn.notPermitted || result == IOKitReturn.notPrivileged), entries.isEmpty {
            accessDenied = true
        }
    }

    /// Hands all buttons back to the mouse. Called when the app quits.
    func shutdown() {
        entries.values.forEach { $0.controller.shutdown() }
    }

    func clearLog() {
        log.removeAll()
    }

    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return log.map { "\(formatter.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Device lifecycle

    private func attach(_ device: IOHIDDevice) {
        guard entries[device] == nil else { return }
        let info = HIDDeviceMonitor.info(for: device)
        guard let kind = MXVertical.classify(vendorID: info.vendorID, productID: info.productID) else { return }
        guard let superseded = HIDInterfaceInfo.twinsToReplace(adding: info, open: entries.mapValues(\.transport.info)) else { return }
        superseded.forEach { detach($0, removed: false) }

        append("Found \(info.summary)")
        let transport = IOKitHIDTransport(device: device)
        do {
            try transport.open()
        } catch let error as IOKitHIDError {
            append(error.description)
            if error.isPermissionDenied { accessDenied = true }
            recomputeStatus()
            return
        } catch {
            append("\(error)")
            return
        }
        accessDenied = false

        let controller = MXVerticalController(transport: transport, kind: kind)
        controller.onLog = { [weak self] text in self?.append(text) }
        controller.onButtonEvent = { [weak self] event in self?.onButtonEvent?(event) }
        controller.onPointerDelta = { [weak self] dx, dy in self?.onPointerDelta?(dx, dy) }
        controller.onDesiredDPIChange = { [weak self, weak controller] value in
            guard let self, let controller else { return }
            self.controller(controller, didChangeDesiredDPI: value)
        }
        controller.onStateChange = { [weak self, weak controller] state in
            guard let self, let controller else { return }
            self.controller(controller, didChangeTo: state)
        }
        installTrafficLogging(on: controller)
        controller.setDesiredDiversion(desiredDiversion)
        controller.setDesiredRawXY(desiredRawXY)
        controller.setDesiredDPI(desiredDPI)
        entries[device] = Entry(transport: transport, controller: controller, kind: kind)
        controller.start()
        recomputeStatus()
    }

    /// `removed` is true when IOKit removed the device; otherwise it is still present and its
    /// handle must be closed.
    private func detach(_ device: IOHIDDevice, removed: Bool) {
        guard let entry = entries.removeValue(forKey: device) else { return }
        append(removed ? "\(entry.transport.info.product) was disconnected" : "Closing \(entry.transport.info.product)")
        let controller = entry.controller
        // A stale controller must not drive status or recovery for the entries that remain.
        controller.onStateChange = nil
        controller.onDesiredDPIChange = nil
        controller.client.onTraffic = nil
        // Releases held keys (still delivered through onButtonEvent) and hands buttons back.
        controller.shutdown()
        controller.onButtonEvent = nil
        controller.onPointerDelta = nil
        controller.onLog = nil
        if removed {
            entry.transport.deviceRemoved()
        } else {
            entry.transport.close()
        }
        recomputeStatus()
    }

    private func controller(_ controller: MXVerticalController, didChangeTo state: MXVerticalController.State) {
        guard !controller.isShutDown, entries.values.contains(where: { $0.controller === controller }) else { return }
        recomputeStatus()
        switch state {
        case .connected:
            failedRecoveries = 0
        case .failed:
            scheduleRecovery()
        case .waitingForDevice:
            // A directly connected mouse that doesn't answer is often a dead pre-repair interface.
            if case .direct = controller.kind { scheduleRecovery() }
        case .probing, .asleep:
            break
        }
    }

    private func installTrafficLogging(on controller: MXVerticalController) {
        guard logsTraffic else {
            controller.client.onTraffic = nil
            return
        }
        controller.client.onTraffic = { [weak self] direction, bytes in
            MainActorDelivery.run {
                guard let self, self.logsTraffic else { return }
                let line = (direction == .outgoing ? "→ " : "← ") + bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                self.append(line, isTraffic: true)
            }
        }
    }

    private func systemDidWake() {
        guard !entries.isEmpty else { return }
        append("Mac woke up; reapplying button configuration")
        entries.values.forEach { $0.controller.refresh() }
    }

    private func recomputeStatus() {
        func rank(_ state: MXVerticalController.State) -> Int {
            switch state {
            case .connected: return 5
            case .asleep: return 4
            case .probing: return 3
            case .waitingForDevice: return 2
            case .failed: return 1
            }
        }
        guard let best = entries.values.max(by: { rank($0.controller.state) < rank($1.controller.state) }) else {
            status = accessDenied ? .accessDenied : .searching
            return
        }
        switch best.controller.state {
        case .connected(let snapshot): status = .connected(snapshot)
        case .asleep(let snapshot): status = .asleep(snapshot)
        case .probing: status = .probing(best.kind.connection)
        case .waitingForDevice: status = .waiting(best.kind.connection)
        case .failed(let message): status = .failed(message)
        }
    }

    private func append(_ text: String, isTraffic: Bool = false) {
        nextLogID += 1
        log.append(LogEntry(id: nextLogID, date: Date(), text: text, isTraffic: isTraffic))
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }
}

extension DeviceManager.Status {
    var title: String {
        switch self {
        case .connected(let snapshot), .asleep(let snapshot): return snapshot.name
        default: return MXVertical.displayName
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
