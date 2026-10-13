import Foundation
@testable import UprightKit

/// A software MX Vertical that answers HID++ requests the way the real mouse (and a
/// Unifying receiver in front of it) does. Replies arrive asynchronously, like IOKit's.
///
/// In receiver mode other devices can share the receiver, the mouse can be re-paired to a
/// different slot or unpaired, and the receiver answers pairing-info reads (register 0xB5)
/// and device-arrival requests (register 0x02).
///
/// Besides button diversion the mouse answers firmware (0x0003), pointer speed (0x2201),
/// Easy-Switch (0x1814, 0x1815) and raw XY reporting requests.
final class SimulatedMXVertical: HIDPPTransport, @unchecked Sendable {
    enum Mode {
        case direct
        case receiver(slot: UInt8)
    }

    private struct Device {
        var name: String
        var wirelessPID: UInt16
        var awake = true
        var diverted: Set<UInt16> = []
        var rawXY: Set<UInt16> = []
        var dpi: Int = SimulatedMXVertical.defaultDPI
        var currentHost: UInt8 = 0

        /// What a power cycle or reconnect clears: temporary diversion and the HID++ pointer speed.
        mutating func forgetVolatileState() {
            diverted.removeAll()
            rawXY.removeAll()
            dpi = SimulatedMXVertical.defaultDPI
        }
    }

    var onReport: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let mode: Mode
    let name: String
    private let queue = DispatchQueue(label: "simulated-mx-vertical")
    private let lock = NSLock()

    /// Devices by device index (0xFF for a directly connected mouse).
    private var _devices: [UInt8: Device] = [:]
    private var _mouseIndex: UInt8?
    private var _sent: [[UInt8]] = []
    private var _dropsRequests = false
    private var _latency: TimeInterval = 0
    private var _supportsPairingInfo = true
    private var _cidErrors: [UInt16: (code: UInt8, remaining: Int)] = [:]
    private var _hostSwitches: [UInt8] = []

    /// The original six features keep their indices (reprog at 4, wireless status at 5).
    static let baseFeatures: [UInt16] = [0x0000, 0x0001, 0x0005, 0x1000, 0x1B04, 0x1D4B]
    static let extendedFeatures: [UInt16] = [0x0003, 0x2201, 0x1814, 0x1815]
    static let allFeatures = baseFeatures + extendedFeatures
    static let reprogIndex: UInt8 = 4
    static let wirelessStatusIndex: UInt8 = 5
    static let otherDevicePID: UInt16 = 0x408A
    /// Feature versions reported by the feature table (default 0).
    static let featureVersions: [UInt16: UInt8] = [0x0003: 4, 0x1B04: 4]

    /// 400 through 4000 in steps of 50, as getSensorDpiList encodes it.
    static let dpiList: [UInt16] = [400, 0xE000 | 50, 4000]
    static let defaultDPI = 1000
    static let serialNumber = "1234ABCD5678"
    static let hostNames: [String?] = ["Work MacBook Pro", nil, "Gaming PC with a very long host name"]

    /// (cid, flags, additional flags): mirrors the MX Vertical's control table shape.
    /// Additional flags bit 0 = raw XY capable.
    static let controls: [(UInt16, UInt8, UInt8)] = [
        (0x0050, 0x01, 0x00),        // left click: mouse button, not divertable
        (0x0051, 0x01, 0x00),        // right click
        (0x0052, 0x31, 0x00),        // wheel click: mouse, reprogrammable, divertable
        (0x0053, 0x31, 0x01),        // back
        (0x0056, 0x31, 0x01),        // forward
        (0x00FD, 0x30, 0x01),        // DPI switch: reprogrammable, divertable
        (0x00D7, 0xB4, 0x00),        // virtual gesture button: virtual, divertable
    ]

    /// The feature table this mouse reports.
    let features: [UInt16]

    /// The configurable controls (what the controller re-sends on every forced pass).
    static let configurableCount = 4

    init(mode: Mode, name: String = "MX Vertical", features: [UInt16] = SimulatedMXVertical.allFeatures) {
        self.mode = mode
        self.name = name
        self.features = features
        let pid = MXVertical.matches(name: name) ? MXVertical.wirelessProductID : Self.otherDevicePID
        let index: UInt8
        switch mode {
        case .direct: index = 0xFF
        case .receiver(let slot): index = slot
        }
        _devices[index] = Device(name: name, wirelessPID: pid)
        _mouseIndex = index
    }

    /// Where the simulated mouse currently answers (its receiver slot, or 0xFF).
    var deviceIndex: UInt8 { lock.locked { _mouseIndex ?? 0 } }
    var diverted: Set<UInt16> { lock.locked { _mouseIndex.flatMap { _devices[$0]?.diverted } ?? [] } }
    var rawXY: Set<UInt16> { lock.locked { _mouseIndex.flatMap { _devices[$0]?.rawXY } ?? [] } }
    /// The sensor resolution the mouse is using.
    var dpi: Int { lock.locked { _mouseIndex.flatMap { _devices[$0]?.dpi } ?? 0 } }
    /// Every setCurrentHost the mouse received.
    var hostSwitches: [UInt8] { lock.locked { _hostSwitches } }
    var sentReports: [[UInt8]] { lock.locked { _sent } }

    /// While true the mouse ignores requests, so they time out (it still sends its own reports).
    var dropsRequests: Bool {
        get { lock.locked { _dropsRequests } }
        set { lock.locked { _dropsRequests = newValue } }
    }

    /// Delay before every reply and report.
    var latency: TimeInterval {
        get { lock.locked { _latency } }
        set { lock.locked { _latency = newValue } }
    }

    /// Whether the receiver answers pairing-info reads (register 0xB5).
    var supportsPairingInfo: Bool {
        get { lock.locked { _supportsPairingInfo } }
        set { lock.locked { _supportsPairingInfo = newValue } }
    }

    // MARK: Test controls

    /// Pairs another device to the receiver.
    func addDevice(slot: UInt8, name: String, wirelessPID: UInt16 = SimulatedMXVertical.otherDevicePID) {
        lock.locked { _devices[slot] = Device(name: name, wirelessPID: wirelessPID) }
    }

    /// The mouse turns off or sleeps: the receiver reports link loss, requests fail.
    func goToSleep() {
        let index = lock.locked { () -> UInt8? in
            guard let index = _mouseIndex else { return nil }
            _devices[index]?.awake = false
            return index
        }
        if let index, isReceiver { emit(connectionNotification(slot: index, linkUp: false)) }
    }

    /// The mouse powers back on with its temporary diversion state cleared. `announce` sends
    /// the receiver's 0x41 link-up; `reportReconnect` also sends the mouse's own 0x1D4B.
    func wakeUp(clearingDiversion: Bool = true, announce: Bool = true, reportReconnect: Bool = false) {
        let index = lock.locked { () -> UInt8? in
            guard let index = _mouseIndex else { return nil }
            _devices[index]?.awake = true
            if clearingDiversion { _devices[index]?.forgetVolatileState() }
            return index
        }
        guard let index else { return }
        if announce, isReceiver { emit(connectionNotification(slot: index, linkUp: true)) }
        if reportReconnect { emit(wirelessStatusEvent(index: index)) }
    }

    /// The mouse sends 0x1D4B "reconnection" after losing its configuration.
    func reportReconnect() {
        forgetDiversion()
        emit(wirelessStatusEvent(index: deviceIndex))
    }

    /// The mouse silently loses its diversion state and pointer speed (no report is sent).
    func forgetDiversion() {
        lock.locked {
            if let index = _mouseIndex { _devices[index]?.forgetVolatileState() }
        }
    }

    /// The top button cycles the pointer speed in firmware (when not diverted); nothing is reported.
    func setDPINatively(_ dpi: Int) {
        lock.locked {
            if let index = _mouseIndex { _devices[index]?.dpi = dpi }
        }
    }

    /// Broadcasts a BATTERY_STATUS (0x1000) event, as the mouse does when its level changes.
    func reportBattery(percentage: UInt8, charging: Bool = false) {
        guard let index = features.firstIndex(of: 0x1000) else { return }
        emit(HIDPPMessage(reportID: .long, deviceIndex: deviceIndex, subID: UInt8(index), address: 0x00, parameters: [percentage, 50, charging ? 1 : 0]).bytes)
    }

    /// Reports raw movement for a held raw-XY control, like divertedRawMouseXYEvent.
    func move(dx: Int, dy: Int) {
        let params = UInt16(bitPattern: Int16(dx)).bigEndianBytes + UInt16(bitPattern: Int16(dy)).bigEndianBytes
        emit(HIDPPMessage(reportID: .long, deviceIndex: deviceIndex, subID: Self.reprogIndex, address: 0x10, parameters: params).bytes)
    }

    /// Makes setCidReporting for `cid` fail with HID++ 2.0 error `code`, `times` times.
    func failDiversion(of cid: UInt16, code: UInt8, times: Int = .max) {
        lock.locked { _cidErrors[cid] = (code, times) }
    }

    /// Re-pairs the mouse to `slot`. `announceUnpair` first reports 0x40 for the old slot.
    func repair(toSlot slot: UInt8, announceUnpair: Bool) {
        let oldIndex = lock.locked { () -> UInt8? in
            guard let index = _mouseIndex, var device = _devices.removeValue(forKey: index) else { return nil }
            device.awake = true
            device.forgetVolatileState()
            _devices[slot] = device
            _mouseIndex = slot
            return index
        }
        if announceUnpair, let oldIndex { emit(unpairNotification(slot: oldIndex)) }
        emit(connectionNotification(slot: slot, linkUp: true))
    }

    /// Removes the mouse's pairing; the receiver reports 0x40.
    func unpair() {
        let index = lock.locked { () -> UInt8? in
            guard let index = _mouseIndex else { return nil }
            _devices[index] = nil
            _mouseIndex = nil
            return index
        }
        if let index { emit(unpairNotification(slot: index)) }
    }

    /// Reports the currently held buttons. Like the real mouse, only diverted ones are reported.
    func hold(_ cids: [UInt16]) {
        let reported = cids.filter { diverted.contains($0) }
        let params = reported.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        emit(HIDPPMessage(reportID: .long, deviceIndex: deviceIndex, subID: Self.reprogIndex, address: 0x00, parameters: params).bytes)
    }

    func disconnect() {
        queue.async { self.onClose?() }
    }

    // MARK: Request counters

    /// Requests sent to `feature` (by feature ID), optionally only for one function.
    func requestCount(feature: UInt16, function: UInt8? = nil) -> Int {
        guard let index = features.firstIndex(of: feature) else { return 0 }
        return sentReports.filter { $0[0] == HIDPPReportID.long.rawValue && Int($0[2]) == index && (function == nil || $0[3] >> 4 == function!) }.count
    }

    /// setCidReporting requests sent to the mouse.
    var setReportingCount: Int {
        sentReports.filter { $0[0] == HIDPPReportID.long.rawValue && $0[2] == Self.reprogIndex && $0[3] >> 4 == 3 }.count
    }

    /// Root.getProtocolVersion (ping) requests sent to `index`.
    func pingCount(to index: UInt8) -> Int {
        sentReports.filter { $0[1] == index && $0[2] == 0 && $0[3] >> 4 == 1 }.count
    }

    /// Receiver register writes to `address`.
    func registerWriteCount(_ address: UInt8) -> Int {
        sentReports.filter { $0[0] == 0x10 && $0[1] == 0xFF && $0[2] == 0x80 && $0[3] == address }.count
    }

    // MARK: HIDPPTransport

    func send(_ bytes: [UInt8]) throws {
        lock.locked { _sent.append(bytes) }
        guard let request = HIDPPMessage(bytes: bytes) else { return }
        for reply in respond(to: request) {
            emit(reply.bytes)
        }
    }

    // MARK: Behavior

    private var isReceiver: Bool {
        if case .receiver = mode { return true }
        return false
    }

    private func emit(_ bytes: [UInt8]) {
        let latency = self.latency
        if latency > 0 {
            queue.asyncAfter(deadline: .now() + latency) { self.onReport?(bytes) }
        } else {
            queue.async { self.onReport?(bytes) }
        }
    }

    private func connectionNotification(slot: UInt8, linkUp: Bool) -> [UInt8] {
        let pid = lock.locked { _devices[slot]?.wirelessPID ?? MXVertical.wirelessProductID }
        return HIDPPMessage(reportID: .short, deviceIndex: slot, subID: 0x41, address: 0x04, parameters: [linkUp ? 0x00 : 0x40, UInt8(pid & 0xFF), UInt8(pid >> 8)]).bytes
    }

    private func unpairNotification(slot: UInt8) -> [UInt8] {
        HIDPPMessage(reportID: .short, deviceIndex: slot, subID: 0x40, address: 0x02, parameters: []).bytes
    }

    private func wirelessStatusEvent(index: UInt8) -> [UInt8] {
        HIDPPMessage(reportID: .long, deviceIndex: index, subID: Self.wirelessStatusIndex, address: 0x00, parameters: [1, 1, 0]).bytes
    }

    private func respond(to request: HIDPPMessage) -> [HIDPPMessage] {
        if request.deviceIndex == 0xFF, isReceiver {
            return respondAsReceiver(to: request)
        }
        if lock.locked({ _dropsRequests }) { return [] }
        guard let device = lock.locked({ _devices[request.deviceIndex] }) else {
            return isReceiver ? [error10(request, code: 0x08)] : []
        }
        guard device.awake else {
            return isReceiver ? [error10(request, code: 0x09)] : []
        }
        return respond(to: request, device: device).map { [$0] } ?? []
    }

    private func respondAsReceiver(to request: HIDPPMessage) -> [HIDPPMessage] {
        let p = request.parameters
        switch (request.subID, request.address) {
        case (0x80, 0x02) where p[0] == 0x02:
            // Fake device arrival: announce every paired device.
            let slots = lock.locked { _devices.filter { $0.key != 0xFF }.map { ($0.key, $0.value.awake) } }
            return [request] + slots.sorted { $0.0 < $1.0 }.map {
                HIDPPMessage(bytes: connectionNotification(slot: $0.0, linkUp: $0.1))!
            }
        case (0x80, _):
            return [request]
        case (0x83, 0xB5):
            guard lock.locked({ _supportsPairingInfo }) else { return [error10(request, code: 0x02)] }
            let slot = p[0] &- 0x1F
            guard (0x20...0x25).contains(p[0]), let device = lock.locked({ _devices[slot] }) else {
                return [error10(request, code: 0x03)]
            }
            return [HIDPPMessage(reportID: .long, deviceIndex: 0xFF, subID: 0x83, address: 0xB5,
                                 parameters: [p[0], 0x00, 0x08, UInt8(device.wirelessPID >> 8), UInt8(device.wirelessPID & 0xFF), 0, 0, 0x02])]
        default:
            return [error10(request, code: 0x01)]
        }
    }

    private func respond(to request: HIDPPMessage, device: Device) -> HIDPPMessage? {
        let p = request.parameters
        guard Int(request.featureIndex) < features.count else { return error20(request, code: 0x06) }
        let feature = features[Int(request.featureIndex)]
        switch (feature, request.function) {
        case (0x0000, 0):
            let id = p.uint16(at: 0)
            let index = features.firstIndex(of: id).map(UInt8.init) ?? 0
            return with(request, [index, 0, Self.featureVersions[id] ?? 0])
        case (0x0000, 1):
            return with(request, [4, 5, p[2]])
        case (0x0001, 0):
            return with(request, [UInt8(features.count - 1)])
        case (0x0001, 1):
            let id = features[Int(p[0])]
            return with(request, id.bigEndianBytes + [0, Self.featureVersions[id] ?? 0])
        case (0x0005, 0):
            return with(request, [UInt8(device.name.utf8.count)])
        case (0x0005, 1):
            return with(request, Array(device.name.utf8.dropFirst(Int(p[0])).prefix(16)))
        case (0x1000, 0):
            return with(request, [80, 50, 0])

        case (0x0003, 0):
            // [entity count, unit ID (4), transport (2), model ID (6), extended model, capabilities]
            return with(request, [3, 0xAB, 0xCD, 0x12, 0x34, 0x00, 0x0F, 0xB0, 0x20, 0x40, 0x7B, 0xC0, 0x8A, 0x00, 0x01])
        case (0x0003, 1):
            switch p[0] {
            case 0: return with(request, [0x00] + Array("RBM".utf8) + [0x14, 0x00, 0x00, 0x15])
            case 1: return with(request, [0x01] + Array("BOT".utf8) + [0x12, 0x03, 0x00, 0x00])
            case 2: return with(request, [0x02, 0x48])
            default: return error20(request, code: 0x02)
            }
        case (0x0003, 2):
            return with(request, Array(Self.serialNumber.utf8))

        case (0x2201, 0):
            return with(request, [1])
        case (0x2201, 1):
            return with(request, [p[0]] + Self.dpiList.flatMap(\.bigEndianBytes))
        case (0x2201, 2):
            return with(request, [p[0]] + UInt16(device.dpi).bigEndianBytes + UInt16(Self.defaultDPI).bigEndianBytes)
        case (0x2201, 3):
            let dpi = Int(p.uint16(at: 1))
            guard (400...4000).contains(dpi), dpi % 50 == 0 else { return error20(request, code: 0x02) }
            lock.locked { _devices[request.deviceIndex]?.dpi = dpi }
            return with(request, Array(p.prefix(3)))

        case (0x1814, 0):
            return with(request, [UInt8(Self.hostNames.count), device.currentHost, 0])
        case (0x1814, 1):
            // The mouse leaves for the other host without answering.
            lock.locked {
                _hostSwitches.append(p[0])
                _devices[request.deviceIndex]?.currentHost = p[0]
            }
            goToSleep()
            return nil
        case (0x1815, 0):
            return with(request, [0x01, 0, UInt8(Self.hostNames.count), device.currentHost])
        case (0x1815, 1):
            guard Int(p[0]) < Self.hostNames.count else { return error20(request, code: 0x02) }
            let name = Self.hostNames[Int(p[0])]
            let length = UInt8(name?.utf8.count ?? 0)
            return with(request, [p[0], name == nil ? 0 : 1, 0x01, 1, length, 32])
        case (0x1815, 3):
            guard Int(p[0]) < Self.hostNames.count, let name = Self.hostNames[Int(p[0])] else { return error20(request, code: 0x02) }
            return with(request, [p[0], p[1]] + Array(name.utf8.dropFirst(Int(p[1])).prefix(14)))

        case (0x1B04, 0):
            return with(request, [UInt8(Self.controls.count)])
        case (0x1B04, 1):
            let (cid, flags, additional) = Self.controls[Int(p[0])]
            return with(request, cid.bigEndianBytes + [0, UInt8(p[0]), flags, p[0], 0, 0, additional])
        case (0x1B04, 2):
            let cid = p.uint16(at: 0)
            let flags: UInt8 = (device.diverted.contains(cid) ? 0x01 : 0) | (device.rawXY.contains(cid) ? 0x10 : 0)
            return with(request, cid.bigEndianBytes + [flags, 0, 0])
        case (0x1B04, 3):
            let cid = p.uint16(at: 0)
            guard let control = Self.controls.first(where: { $0.0 == cid }), control.1 & 0x20 != 0 else {
                return error20(request, code: 0x02)
            }
            if p[2] & 0x30 == 0x30, control.2 & 0x01 == 0 {
                return error20(request, code: 0x02)
            }
            let injected = lock.locked { () -> UInt8? in
                guard let entry = _cidErrors[cid], entry.remaining > 0 else { return nil }
                _cidErrors[cid] = (entry.code, entry.remaining - 1)
                return entry.code
            }
            if let injected { return error20(request, code: injected) }
            lock.locked {
                if p[2] & 0x02 != 0 {
                    if p[2] & 0x01 != 0 {
                        _devices[request.deviceIndex]?.diverted.insert(cid)
                    } else {
                        _devices[request.deviceIndex]?.diverted.remove(cid)
                    }
                }
                if p[2] & 0x20 != 0 {
                    if p[2] & 0x10 != 0 {
                        _devices[request.deviceIndex]?.rawXY.insert(cid)
                    } else {
                        _devices[request.deviceIndex]?.rawXY.remove(cid)
                    }
                }
            }
            return with(request, Array(p.prefix(5)))
        default:
            return error20(request, code: 0x07)
        }
    }

    private func with(_ request: HIDPPMessage, _ params: [UInt8]) -> HIDPPMessage {
        HIDPPMessage(reportID: request.reportID, deviceIndex: request.deviceIndex, subID: request.subID, address: request.address, parameters: params)
    }

    private func error10(_ request: HIDPPMessage, code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: request.deviceIndex, subID: 0x8F, address: request.subID, parameters: [request.address, code, 0])
    }

    private func error20(_ request: HIDPPMessage, code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .long, deviceIndex: request.deviceIndex, subID: 0xFF, address: request.subID, parameters: [request.address, code])
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
