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
    @Published var logsTraffic = false

    var onButtonEvent: ((ButtonEvent) -> Void)?

    private struct Entry {
        let transport: IOKitHIDTransport
        let controller: MXVerticalController
        let kind: TransportKind
    }

    private let monitor = HIDDeviceMonitor()
    private var entries: [IOHIDDevice: Entry] = [:]
    private var desiredDiversion: Set<UInt16> = []
    private var accessDenied = false
    private var failedRecoveries = 0
    private var nextLogID = 0
    private var observers: [NSObjectProtocol] = []
    private static let maxLogEntries = 400

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
            Task { @MainActor in self?.attach(device) }
        }
        monitor.onRemove = { [weak self] device in
            Task { @MainActor in self?.detach(device) }
        }
        let result = monitor.start()
        if result != kIOReturnSuccess {
            append(String(format: "IOHIDManagerOpen returned 0x%08X", UInt32(bitPattern: result)))
            if result == IOKitReturn.notPermitted || result == IOKitReturn.notPrivileged {
                accessDenied = true
            }
        }
        // When Input Monitoring is off, IOHIDManagerOpen still succeeds and then
        // reports no devices. Treat that as a permission block, not a missing mouse.
        noteInputMonitoring()
        append("Watching for MX Vertical over USB, Unifying/Bolt receivers and Bluetooth")

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemDidWake() }
            })
        }
        recomputeStatus()
    }

    func setDesiredDiversion(_ cids: Set<UInt16>) {
        desiredDiversion = cids
        entries.values.forEach { $0.controller.setDesiredDiversion(cids) }
    }

    /// Drops every open interface and matches the mouse again. A Bluetooth re-pair
    /// keeps the same serial but the old IOHIDDevice stops answering.
    func reconnect() {
        append("Reconnecting")
        if HIDDeviceMonitor.inputMonitoringAccess == kIOHIDAccessTypeGranted {
            accessDenied = false
        }
        failedRecoveries = 0
        restartMonitoring()
    }

    /// The open HID interface can be the pre-repair device. Matching again picks up the live one.
    private func scheduleRecovery() {
        guard failedRecoveries < 3 else { return }
        failedRecoveries += 1
        append("HID++ did not answer; looking for the mouse again")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.isConnected else { return }
            self.restartMonitoring()
        }
    }

    private func restartMonitoring() {
        for device in Array(entries.keys) {
            detach(device)
        }
        monitor.stop()
        let result = monitor.start()
        if result != kIOReturnSuccess {
            append(String(format: "IOHIDManagerOpen returned 0x%08X", UInt32(bitPattern: result)))
            if result == IOKitReturn.notPermitted || result == IOKitReturn.notPrivileged {
                accessDenied = true
            }
        }
        noteInputMonitoring()
        recomputeStatus()
    }

    /// macOS hides Logitech interfaces until Input Monitoring is allowed.
    private func noteInputMonitoring() {
        let access = HIDDeviceMonitor.inputMonitoringAccess
        guard access != kIOHIDAccessTypeGranted, monitor.currentDevices().isEmpty else { return }
        accessDenied = true
        if access == kIOHIDAccessTypeUnknown {
            HIDDeviceMonitor.requestInputMonitoringAccess()
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

    private func isVendorHIDPP(_ info: HIDInterfaceInfo) -> Bool {
        info.primaryUsagePage == 0xFF00 || info.primaryUsagePage == 0xFF43
    }

    private func samePhysicalDevice(_ lhs: HIDInterfaceInfo, _ rhs: HIDInterfaceInfo) -> Bool {
        lhs.vendorID == rhs.vendorID && lhs.productID == rhs.productID && lhs.locationID == rhs.locationID
    }

    private func attach(_ device: IOHIDDevice) {
        guard entries[device] == nil else { return }
        let info = HIDDeviceMonitor.info(for: device)
        guard let kind = MXVertical.classify(vendorID: info.vendorID, productID: info.productID) else { return }
        // Bluetooth publishes the mouse and its HID++ collection as one interface. USB and
        // receivers also publish a dedicated vendor-page interface, which is the one to use
        // when both show up for the same device.
        if info.locationID != 0 {
            let twins = entries.filter { samePhysicalDevice($0.value.transport.info, info) }
            if isVendorHIDPP(info) {
                if twins.values.contains(where: { isVendorHIDPP($0.transport.info) }) { return }
                for device in twins.keys where !isVendorHIDPP(twins[device]!.transport.info) {
                    detach(device)
                }
            } else if !twins.isEmpty {
                return
            }
        }

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
        controller.onStateChange = { [weak self] state in
            self?.recomputeStatus()
            if case .connected = state {
                self?.failedRecoveries = 0
            } else if case .failed(let message) = state, message != "Disconnected" {
                self?.scheduleRecovery()
            }
        }
        controller.client.onTraffic = { [weak self] direction, bytes in
            let line = (direction == .outgoing ? "→ " : "← ") + bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
            Task { @MainActor in
                guard let self, self.logsTraffic else { return }
                self.append(line, isTraffic: true)
            }
        }
        controller.setDesiredDiversion(desiredDiversion)
        entries[device] = Entry(transport: transport, controller: controller, kind: kind)
        controller.start()
        recomputeStatus()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let entry = entries.removeValue(forKey: device) else { return }
        append("\(entry.transport.info.product) was disconnected")
        // Release held keys now; the controller may be deallocated before its close callback runs.
        entry.controller.shutdown()
        entry.transport.deviceRemoved()
        recomputeStatus()
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
        case .searching: return "Not connected"
        case .accessDenied: return "macOS is blocking access"
        case .probing(let kind): return "Connecting via \(kind.title)…"
        case .waiting: return "Receiver found — click a mouse button to wake it"
        case .connected(let snapshot): return "Connected via \(snapshot.connection.title)"
        case .asleep: return "Asleep — move the mouse to wake it"
        case .failed(let message): return message
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
