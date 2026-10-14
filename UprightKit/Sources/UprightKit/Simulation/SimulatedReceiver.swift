import Foundation

/// A software HID++ interface hosting simulated devices (`SimulatedDeviceProfile`) by device
/// index: a receiver with slots 1...6 (`SimulatedReceiver`) or one device connected directly at
/// 0xFF (`SimulatedDirect`). Used by tests and by Demo Mode in place of an IOKit transport.
///
/// Devices answer HID++ 2.0 requests from their profile and keep per-unit state: diversion and
/// raw XY per control, pointer speed, Easy-Switch channel, battery, and whether they're awake.
/// Replies and reports arrive asynchronously on a private serial queue, like IOKit's, after the
/// transport's `latency` plus the device's own.
///
/// "Slot" is the device index throughout: 1...6 on a receiver, 0xFF on a direct link.
public class SimulatedHIDPPTransport: HIDPPTransport, @unchecked Sendable {
    public var onReport: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    /// One simulated device's live state.
    struct Unit {
        var profile: SimulatedDeviceProfile
        var awake = true
        var diverted: Set<UInt16> = []
        var rawXY: Set<UInt16> = []
        var dpi: Int
        var currentHost: UInt8 = 0
        var batteryLevel: Int
        var charging = false
        var dropsRequests = false
        var latency: TimeInterval = 0
        var diversionFaults: [UInt16: DiversionFault] = [:]
        var hostSwitches: [UInt8] = []

        init(profile: SimulatedDeviceProfile) {
            self.profile = profile
            dpi = profile.defaultDPI ?? 0
            batteryLevel = profile.batteryLevel
        }

        /// What a power cycle or reconnect clears: temporary diversion and the HID++ pointer speed.
        mutating func forgetVolatileState() {
            diverted.removeAll()
            rawXY.removeAll()
            dpi = profile.defaultDPI ?? 0
        }
    }

    struct DiversionFault {
        var code: UInt8
        var remaining: Int
    }

    /// What one request produces.
    struct Outcome {
        /// The answer to the request.
        var reply: HIDPPMessage?
        /// Sent after the reply (announcements, the link loss after an Easy-Switch).
        var notifications: [HIDPPMessage] = []
        var latency: TimeInterval = 0
        /// Nobody answers: the request times out on the host.
        var dropped = false

        static let ignored = Outcome(dropped: true)
    }

    private struct RequestKey: Hashable {
        var index: UInt8
        var feature: UInt16
        var function: UInt8
    }

    let lock = NSLock()
    private let queue = DispatchQueue(label: "upright.simulated-hidpp")

    /// Devices by index. Guarded by `lock`, like every other stored property here.
    var units: [UInt8: Unit] = [:]
    private var _dropsRequests = false
    private var _latency: TimeInterval = 0
    private var _unansweredRequestWindow: TimeInterval = 0
    private var _isDisconnected = false
    private var _sent: [[UInt8]] = []
    private var featureRequests: [RequestKey: Int] = [:]
    private var pings: [UInt8: Int] = [:]
    var registerWrites: [UInt8: Int] = [:]
    var registerReads: [UInt8: Int] = [:]
    private var inFlight = 0
    private var inFlightMax = 0

    /// What a hub should treat this interface as.
    public let transportKind: TransportKind

    init(units: [UInt8: SimulatedDeviceProfile], transportKind: TransportKind) {
        self.units = units.mapValues(Unit.init(profile:))
        self.transportKind = transportKind
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Hooks for receivers (called with `lock` held)

    var isReceiver: Bool { false }

    /// Answers a request addressed to the receiver itself (device index 0xFF).
    func receiverOutcome(for request: HIDPPMessage) -> Outcome { .ignored }

    /// The receiver's notification that `slot`'s link went up or down, if it sends one.
    func linkNotification(slot: UInt8, up: Bool) -> HIDPPMessage? { nil }

    // MARK: HIDPPTransport

    public func send(_ bytes: [UInt8]) throws {
        let outcome: Outcome? = synchronized {
            guard !_isDisconnected else { return nil }
            _sent.append(bytes)
            guard let request = HIDPPMessage(bytes: bytes) else { return nil }
            count(request)
            let outcome = route(request)
            if outcome.reply != nil {
                inFlight += 1
                inFlightMax = max(inFlightMax, inFlight)
            } else if outcome.dropped, _unansweredRequestWindow > 0 {
                inFlight += 1
                inFlightMax = max(inFlightMax, inFlight)
                queue.asyncAfter(deadline: .now() + _unansweredRequestWindow) { [self] in
                    synchronized { inFlight -= 1 }
                }
            }
            return outcome
        }
        guard let outcome else { return }
        if let reply = outcome.reply {
            emit(reply, after: outcome.latency, answering: true)
        }
        for message in outcome.notifications {
            emit(message, after: outcome.latency)
        }
    }

    /// The interface goes away (receiver unplugged, Bluetooth link dropped for good).
    public func disconnect() {
        synchronized { _isDisconnected = true }
        queue.async { [self] in onClose?() }
    }

    public var isDisconnected: Bool { synchronized { _isDisconnected } }

    // MARK: Faults

    /// While true nothing behind the interface answers device requests, so they time out.
    /// Devices still send their own reports, and a receiver still answers register requests.
    public var dropsRequests: Bool {
        get { synchronized { _dropsRequests } }
        set { synchronized { _dropsRequests = newValue } }
    }

    /// Delay before every reply and report, added to each device's own latency.
    public var latency: TimeInterval {
        get { synchronized { _latency } }
        set { synchronized { _latency = newValue } }
    }

    /// While true the device in `slot` ignores requests (it still sends reports).
    public func setDropsRequests(_ drops: Bool, slot: UInt8) {
        synchronized { units[slot]?.dropsRequests = drops }
    }

    /// Extra delay before the replies and reports of the device in `slot`.
    public func setLatency(_ latency: TimeInterval, slot: UInt8) {
        synchronized { units[slot]?.latency = latency }
    }

    /// Makes setCidReporting for `cid` on the device in `slot` fail with HID++ 2.0 error
    /// `code`, `times` times.
    public func failDiversion(of cid: UInt16, code: UInt8, times: Int = .max, slot: UInt8) {
        synchronized { units[slot]?.diversionFaults[cid] = DiversionFault(code: code, remaining: times) }
    }

    /// How long a request nobody answers counts towards `requestsInFlightMax` (set it a little
    /// below the host's request timeout). 0, the default, doesn't count unanswered requests.
    public var unansweredRequestWindow: TimeInterval {
        get { synchronized { _unansweredRequestWindow } }
        set { synchronized { _unansweredRequestWindow = newValue } }
    }

    // MARK: Device state

    /// Indices with a device, ascending.
    public var occupiedSlots: [UInt8] { synchronized { units.keys.sorted() } }

    public func profile(slot: UInt8) -> SimulatedDeviceProfile? { synchronized { units[slot]?.profile } }
    public func isAwake(slot: UInt8) -> Bool { synchronized { units[slot]?.awake ?? false } }
    public func diverted(slot: UInt8) -> Set<UInt16> { synchronized { units[slot]?.diverted ?? [] } }
    public func rawXY(slot: UInt8) -> Set<UInt16> { synchronized { units[slot]?.rawXY ?? [] } }
    /// The sensor resolution the device is using.
    public func dpi(slot: UInt8) -> Int? { synchronized { units[slot]?.dpi } }
    /// The zero-based Easy-Switch channel.
    public func currentHost(slot: UInt8) -> Int? { synchronized { units[slot].map { Int($0.currentHost) } } }
    /// Every setCurrentHost the device received.
    public func hostSwitches(slot: UInt8) -> [UInt8] { synchronized { units[slot]?.hostSwitches ?? [] } }
    public func batteryLevel(slot: UInt8) -> Int? { synchronized { units[slot]?.batteryLevel } }

    // MARK: Device behavior

    /// Reports the currently held controls (divertedButtonsEvent). Like real mice, only the
    /// diverted ones are listed; the report is sent even when none are.
    public func hold(_ cids: [UInt16], slot: UInt8) {
        report(slot: slot) { unit in
            guard let reprog = unit.profile.featureIndex(of: 0x1B04) else { return nil }
            let reported = cids.filter(unit.diverted.contains).prefix(4)
            return HIDPPMessage(reportID: .long, deviceIndex: slot, subID: reprog, address: 0x00,
                                parameters: reported.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        }
    }

    /// Every control is released.
    public func release(slot: UInt8) {
        hold([], slot: slot)
    }

    /// Raw movement while a raw-XY control is held (divertedRawMouseXYEvent).
    public func move(dx: Int, dy: Int, slot: UInt8) {
        report(slot: slot) { unit in
            guard let reprog = unit.profile.featureIndex(of: 0x1B04) else { return nil }
            let x = UInt16(bitPattern: Int16(clamping: dx))
            let y = UInt16(bitPattern: Int16(clamping: dy))
            return HIDPPMessage(reportID: .long, deviceIndex: slot, subID: reprog, address: 0x10,
                                parameters: [UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF)])
        }
    }

    /// The device turns off or sleeps: requests fail, and a receiver reports the link loss.
    public func goToSleep(slot: UInt8) {
        let pending: (HIDPPMessage?, TimeInterval)? = synchronized {
            guard units[slot] != nil else { return nil }
            units[slot]?.awake = false
            return (linkNotification(slot: slot, up: false), latency(of: slot))
        }
        if case let (message?, delay)? = pending { emit(message, after: delay) }
    }

    /// The device powers back on. `clearingDiversion` drops its temporary diversion and pointer
    /// speed; `announce` makes a receiver report the link-up (0x41); `reportReconnect` also
    /// sends the device's own WIRELESS_DEVICE_STATUS (0x1D4B) "reconnection" report.
    public func wakeUp(slot: UInt8, clearingDiversion: Bool = true, announce: Bool = true, reportReconnect: Bool = false) {
        let pending: ([HIDPPMessage], TimeInterval)? = synchronized {
            guard units[slot] != nil else { return nil }
            units[slot]?.awake = true
            if clearingDiversion { units[slot]?.forgetVolatileState() }
            var messages: [HIDPPMessage] = []
            if announce, let notification = linkNotification(slot: slot, up: true) { messages.append(notification) }
            if reportReconnect, let status = wirelessStatusEvent(slot: slot) { messages.append(status) }
            return (messages, latency(of: slot))
        }
        if let pending { pending.0.forEach { emit($0, after: pending.1) } }
    }

    /// The device lost its configuration and says so with 0x1D4B "reconnection".
    public func reportReconnect(slot: UInt8) {
        report(slot: slot) { unit in
            unit.forgetVolatileState()
            return self.wirelessStatusEvent(slot: slot, profile: unit.profile)
        }
    }

    /// The device silently loses its diversion state and pointer speed (no report is sent).
    public func forgetDiversion(slot: UInt8) {
        synchronized { units[slot]?.forgetVolatileState() }
    }

    /// The pointer speed changes on the device itself (its DPI button while not diverted);
    /// nothing is reported.
    public func setDPINatively(_ dpi: Int, slot: UInt8) {
        synchronized { units[slot]?.dpi = dpi }
    }

    /// The battery level changes and the device broadcasts it through its battery feature.
    public func reportBattery(percentage: Int, charging: Bool = false, slot: UInt8) {
        report(slot: slot) { unit in
            unit.batteryLevel = percentage
            unit.charging = charging
            guard let featureID = unit.profile.battery.featureID,
                  let index = unit.profile.featureIndex(of: featureID),
                  let parameters = Self.batteryParameters(unit) else { return nil }
            return HIDPPMessage(reportID: .long, deviceIndex: slot, subID: index, address: 0x00, parameters: parameters)
        }
    }

    // MARK: Traffic

    /// Every report sent to the interface, in order.
    public var sentReports: [[UInt8]] { synchronized { _sent } }

    /// HID++ 2.0 requests for `feature` (by feature ID, looked up in the addressed device's own
    /// table when it was sent), optionally only `function` and one slot.
    public func requestCount(feature: UInt16, function: UInt8? = nil, slot: UInt8? = nil) -> Int {
        synchronized {
            featureRequests.filter { key, _ in
                key.feature == feature && (function.map { key.function == $0 } ?? true) && (slot.map { key.index == $0 } ?? true)
            }.values.reduce(0, +)
        }
    }

    /// setCidReporting requests sent to every device.
    public var setReportingCount: Int { requestCount(feature: 0x1B04, function: 3) }

    /// setCidReporting requests sent to the device in `slot`.
    public func setReportingCount(slot: UInt8) -> Int { requestCount(feature: 0x1B04, function: 3, slot: slot) }

    /// Root.getProtocolVersion (ping) requests sent to `slot`, whether or not a device is there.
    public func pingCount(slot: UInt8) -> Int { synchronized { pings[slot] ?? 0 } }

    /// The most requests ever waiting for their reply at once. A request counts from the moment
    /// it is sent until its reply is delivered (see `unansweredRequestWindow` for requests
    /// nobody answers); one request gate per transport keeps it at 1. With no latency set,
    /// replies may be delivered before the host gets to send another request: set `latency`
    /// to make overlapping requests observable.
    public var requestsInFlightMax: Int { synchronized { inFlightMax } }

    /// Clears the sent-report log and every counter.
    public func resetTraffic() {
        synchronized {
            _sent.removeAll()
            featureRequests.removeAll()
            pings.removeAll()
            registerWrites.removeAll()
            registerReads.removeAll()
            inFlightMax = inFlight
        }
    }

    // MARK: Delivery

    fileprivate func emit(_ message: HIDPPMessage, after delay: TimeInterval, answering: Bool = false) {
        let bytes = message.bytes
        let deliver: @Sendable () -> Void = { [self] in
            if answering { synchronized { inFlight -= 1 } }
            onReport?(bytes)
        }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            queue.async(execute: deliver)
        }
    }

    /// Lets the device in `slot` change its state and send one report.
    private func report(slot: UInt8, _ make: (inout Unit) -> HIDPPMessage?) {
        let pending: (HIDPPMessage, TimeInterval)? = synchronized {
            guard var unit = units[slot] else { return nil }
            let message = make(&unit)
            units[slot] = unit
            return message.map { ($0, latency(of: slot)) }
        }
        if let pending { emit(pending.0, after: pending.1) }
    }

    /// Requires `lock`.
    func latency(of slot: UInt8) -> TimeInterval {
        _latency + (units[slot]?.latency ?? 0)
    }

    /// 0x1D4B wirelessDeviceStatusBroadcastEvent: [status 1 = reconnection, request 1 =
    /// software reconfiguration needed, reason]. Requires `lock`.
    func wirelessStatusEvent(slot: UInt8) -> HIDPPMessage? {
        units[slot].flatMap { wirelessStatusEvent(slot: slot, profile: $0.profile) }
    }

    private func wirelessStatusEvent(slot: UInt8, profile: SimulatedDeviceProfile) -> HIDPPMessage? {
        guard let index = profile.featureIndex(of: 0x1D4B) else { return nil }
        return HIDPPMessage(reportID: .long, deviceIndex: slot, subID: index, address: 0x00, parameters: [1, 1, 0])
    }

    // MARK: Requests (called with `lock` held)

    private func count(_ request: HIDPPMessage) {
        if isReceiver, request.deviceIndex == 0xFF {
            switch request.subID {
            case 0x80, 0x82: registerWrites[request.address, default: 0] += 1
            case 0x81, 0x83: registerReads[request.address, default: 0] += 1
            default: break
            }
            return
        }
        if request.featureIndex == 0, request.function == 1 {
            pings[request.deviceIndex, default: 0] += 1
        }
        guard let profile = units[request.deviceIndex]?.profile, profile.speaksHIDPP20,
              Int(request.featureIndex) < profile.features.count else { return }
        let key = RequestKey(index: request.deviceIndex, feature: profile.features[Int(request.featureIndex)].id, function: request.function)
        featureRequests[key, default: 0] += 1
    }

    private func route(_ request: HIDPPMessage) -> Outcome {
        let index = request.deviceIndex
        if isReceiver {
            if index == 0xFF {
                var outcome = receiverOutcome(for: request)
                outcome.latency = _latency
                return outcome
            }
        } else if index != 0xFF {
            return .ignored
        }
        if _dropsRequests { return .ignored }
        guard var unit = units[index] else {
            return isReceiver ? Outcome(reply: Self.error10(request, code: 0x08), latency: _latency) : .ignored
        }
        guard unit.awake else {
            return isReceiver ? Outcome(reply: Self.error10(request, code: 0x09), latency: _latency) : .ignored
        }
        if unit.dropsRequests { return .ignored }

        var outcome = Outcome(latency: latency(of: index))
        if !unit.profile.speaksHIDPP20 {
            // HID++ 1.0 devices reject HID++ 2.0 feature requests, the ping included.
            outcome.reply = Self.error10(request, code: 0x01)
            return outcome
        }
        switch respond(to: request, unit: &unit) {
        case .reply(let reply):
            outcome.reply = reply
        case .leaveForHost(let host):
            // setCurrentHost: the device leaves for the other computer without answering.
            unit.hostSwitches.append(host)
            unit.currentHost = host
            unit.awake = false
            units[index] = unit
            if let notification = linkNotification(slot: index, up: false) { outcome.notifications.append(notification) }
            return outcome
        }
        units[index] = unit
        return outcome
    }

    private enum Response {
        case reply(HIDPPMessage)
        case leaveForHost(UInt8)
    }

    /// One HID++ 2.0 device answering from its profile.
    private func respond(to request: HIDPPMessage, unit: inout Unit) -> Response {
        let p = request.parameters
        let profile = unit.profile
        guard Int(request.featureIndex) < profile.features.count else { return .reply(Self.error20(request, code: 0x06)) }
        let feature = profile.features[Int(request.featureIndex)]

        func with(_ parameters: [UInt8]) -> Response {
            .reply(HIDPPMessage(reportID: request.reportID, deviceIndex: request.deviceIndex, subID: request.subID,
                                address: request.address, parameters: parameters))
        }
        func error(_ code: UInt8) -> Response { .reply(Self.error20(request, code: code)) }

        switch (feature.id, request.function) {
        // ROOT
        case (0x0000, 0):
            let id = p.uint16(at: 0)
            guard let index = profile.featureIndex(of: id), let entry = profile.feature(id) else { return with([0, 0, 0]) }
            return with([index, entry.flags, entry.version])
        case (0x0000, 1):
            return with([profile.protocolMajor, profile.protocolMinor, p[2]])

        // FEATURE_SET
        case (0x0001, 0):
            return with([UInt8(clamping: profile.features.count - 1)])
        case (0x0001, 1):
            guard Int(p[0]) < profile.features.count else { return error(0x02) }
            let entry = profile.features[Int(p[0])]
            return with(entry.id.bigEndianBytes + [entry.flags, entry.version])

        // DEVICE_FW_VERSION
        case (0x0003, 0):
            return with(profile.firmwareIDsReply)
        case (0x0003, 1):
            guard Int(p[0]) < profile.firmware.count else { return error(0x02) }
            return with(profile.firmware[Int(p[0])].parameters)
        case (0x0003, 2):
            guard feature.version >= 4, let serial = profile.serialNumber else { return error(0x07) }
            return with(Array(serial.utf8.prefix(12)))

        // DEVICE_NAME, DEVICE_FRIENDLY_NAME
        case (0x0005, 0):
            return with([UInt8(clamping: profile.name.utf8.count)])
        case (0x0005, 1):
            return with(Array(profile.name.utf8.dropFirst(Int(p[0])).prefix(16)))
        case (0x0005, 2):
            guard let type = profile.deviceTypeCode else { return error(0x07) }
            return with([type])
        case (0x0007, 0):
            let length = UInt8(clamping: profile.codename.utf8.count)
            return with([length, 32, length])
        case (0x0007, 1), (0x0007, 2):
            return with([p[0]] + Array(profile.codename.utf8.dropFirst(Int(p[0])).prefix(15)))

        // Battery
        case (0x1000, 0), (0x1004, 1), (0x1001, 0):
            guard feature.id == profile.battery.featureID else { return error(0x07) }
            return Self.batteryParameters(unit).map(with) ?? error(0x07)
        case (0x1004, 0):
            // getCapabilities: every level flag; flags bit 1 = state of charge in percent.
            return with([0x0F, 0x02])

        // ADJUSTABLE_DPI
        case (0x2201, 0):
            return with([1])
        case (0x2201, 1):
            return with([p[0]] + profile.dpiList.flatMap(\.bigEndianBytes))
        case (0x2201, 2):
            return with([p[0]] + UInt16(clamping: unit.dpi).bigEndianBytes + UInt16(clamping: profile.defaultDPI ?? 0).bigEndianBytes)
        case (0x2201, 3):
            let dpi = Int(p.uint16(at: 1))
            guard profile.supportedDPI.contains(dpi) else { return error(0x02) }
            unit.dpi = dpi
            return with(Array(p.prefix(3)))

        // CHANGE_HOST, HOSTS_INFO
        case (0x1814, 0):
            return with([UInt8(clamping: profile.hostCount), unit.currentHost, 0])
        case (0x1814, 1):
            return .leaveForHost(p[0])
        case (0x1815, 0):
            return with([0x01, 0, UInt8(clamping: profile.hostCount), unit.currentHost])
        case (0x1815, 1):
            guard Int(p[0]) < profile.hostCount else { return error(0x02) }
            let name = Self.hostName(profile, Int(p[0]))
            return with([p[0], name == nil ? 0 : 1, 0x01, 1, UInt8(clamping: name?.utf8.count ?? 0), 32])
        case (0x1815, 3):
            guard Int(p[0]) < profile.hostCount, let name = Self.hostName(profile, Int(p[0])) else { return error(0x02) }
            return with([p[0], p[1]] + Array(name.utf8.dropFirst(Int(p[1])).prefix(14)))

        // REPROG_CONTROLS_V4
        case (0x1B04, 0):
            return with([UInt8(clamping: profile.controls.count)])
        case (0x1B04, 1):
            guard Int(p[0]) < profile.controls.count else { return error(0x02) }
            let c = profile.controls[Int(p[0])]
            return with(c.cid.bigEndianBytes + c.taskID.bigEndianBytes + [c.flags.rawValue, c.position, c.group, c.groupMask, c.additionalFlags])
        case (0x1B04, 2):
            let cid = p.uint16(at: 0)
            guard profile.control(cid) != nil else { return error(0x02) }
            let flags: UInt8 = (unit.diverted.contains(cid) ? 0x01 : 0) | (unit.rawXY.contains(cid) ? 0x10 : 0)
            return with(cid.bigEndianBytes + [flags, 0, 0])
        case (0x1B04, 3):
            let cid = p.uint16(at: 0)
            guard let control = profile.control(cid), control.flags.contains(.divertable) else { return error(0x02) }
            if p[2] & 0x30 == 0x30, !control.supportsRawXY { return error(0x02) }
            if let fault = unit.diversionFaults[cid], fault.remaining > 0 {
                unit.diversionFaults[cid]?.remaining -= 1
                return error(fault.code)
            }
            if p[2] & 0x02 != 0 {
                if p[2] & 0x01 != 0 { unit.diverted.insert(cid) } else { unit.diverted.remove(cid) }
            }
            if p[2] & 0x20 != 0 {
                if p[2] & 0x10 != 0 { unit.rawXY.insert(cid) } else { unit.rawXY.remove(cid) }
            }
            return with(Array(p.prefix(5)))

        default:
            return error(0x07)
        }
    }

    private static func hostName(_ profile: SimulatedDeviceProfile, _ index: Int) -> String? {
        profile.hostNames.indices.contains(index) ? profile.hostNames[index] : nil
    }

    /// The battery report of the device's battery feature (also its broadcast event).
    private static func batteryParameters(_ unit: Unit) -> [UInt8]? {
        let level = UInt8(clamping: max(0, min(100, unit.batteryLevel)))
        switch unit.profile.battery {
        case .status:
            // [level %, next level %, status: 0 discharging, 1 recharging].
            let next: UInt8 = level > 50 ? 50 : level > 20 ? 20 : 5
            return [level, next, unit.charging ? 1 : 0]
        case .unified:
            // [state of charge %, level flags (8 full, 4 good, 2 low, 1 critical), charging, external power].
            let flags: UInt8 = level >= 80 ? 0x08 : level >= 30 ? 0x04 : level > 5 ? 0x02 : 0x01
            return [level, flags, unit.charging ? 1 : 0, unit.charging ? 1 : 0]
        case .voltage:
            // [millivolts (2, BE), flags: bit 7 charging].
            let millivolts = millivolts(forPercentage: Int(level))
            return [UInt8(millivolts >> 8), UInt8(millivolts & 0xFF), unit.charging ? 0x80 : 0x00]
        case .none:
            return nil
        }
    }

    /// Inverts the voltage table Solaar uses to estimate a 0x1001 level.
    private static func millivolts(forPercentage percentage: Int) -> UInt16 {
        let table: [(millivolts: Int, percent: Int)] = [
            (4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60), (3811, 50), (3778, 40),
            (3751, 30), (3717, 20), (3671, 10), (3646, 5), (3579, 2), (3500, 0),
        ]
        for (upper, lower) in zip(table, table.dropFirst()) where percentage >= lower.percent {
            let span = upper.percent - lower.percent
            let fraction = span == 0 ? 0 : Double(percentage - lower.percent) / Double(span)
            return UInt16(Double(lower.millivolts) + fraction * Double(upper.millivolts - lower.millivolts))
        }
        return 3500
    }

    static func error10(_ request: HIDPPMessage, code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: request.deviceIndex, subID: 0x8F, address: request.subID, parameters: [request.address, code, 0])
    }

    static func error20(_ request: HIDPPMessage, code: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .long, deviceIndex: request.deviceIndex, subID: 0xFF, address: request.subID, parameters: [request.address, code])
    }
}

// MARK: - Receiver

/// A software Unifying, Nano or Bolt receiver with simulated devices in slots 1...6.
///
/// Besides relaying device requests it answers the HID++ 1.0 registers Upright and Solaar
/// use: notification flags (0x00, read and write), connection state and device announcements
/// (0x02), pairing information (long register 0xB5: Unifying/Nano sub-registers 0x20+n−1,
/// 0x30+n−1 and 0x40+n−1, Bolt 0x50+n and 0x60+n, receiver info 0x03) and the Bolt unique ID
/// (0xFB). It reports link changes (0x41) and un-pairing (0x40).
public final class SimulatedReceiver: SimulatedHIDPPTransport, @unchecked Sendable {
    public let productID: UInt16
    public let layout: PairingLayout
    public let connection: ConnectionKind

    private var _supportsPairingInfo = true
    private var _notificationFlags: [UInt8] = [0, 0, 0]
    private var _linkNotificationsNeedFlag = false
    private var _supportsNotificationFlags = true
    private var _maxSlots: UInt8 = 6

    /// `connection` is Bolt for the Bolt layout, Unifying for C52B and C532, Nano otherwise.
    public init(productID: UInt16 = 0xC52B, layout: PairingLayout = .unifying, slots: [UInt8: SimulatedDeviceProfile] = [:]) {
        self.productID = productID
        self.layout = layout
        switch layout {
        case .bolt: connection = .bolt
        case .unifying: connection = [0xC52B, 0xC532].contains(productID) ? .unifying : .nano
        }
        super.init(units: slots, transportKind: .receiver(connection))
    }

    /// A Unifying receiver (C52B).
    public static func unifying(_ slots: [UInt8: SimulatedDeviceProfile] = [:]) -> SimulatedReceiver {
        SimulatedReceiver(productID: 0xC52B, layout: .unifying, slots: slots)
    }

    /// A Bolt receiver (C548).
    public static func bolt(_ slots: [UInt8: SimulatedDeviceProfile] = [:]) -> SimulatedReceiver {
        SimulatedReceiver(productID: 0xC548, layout: .bolt, slots: slots)
    }

    /// A Nano receiver (C534 by default), which uses the Unifying register layout.
    public static func nano(_ slots: [UInt8: SimulatedDeviceProfile] = [:], productID: UInt16 = 0xC534) -> SimulatedReceiver {
        SimulatedReceiver(productID: productID, layout: .unifying, slots: slots)
    }

    /// Paired devices by slot.
    public var slots: [UInt8: SimulatedDeviceProfile] { synchronized { units.mapValues(\.profile) } }

    override var isReceiver: Bool { true }

    // MARK: Receiver behavior

    /// Whether the receiver answers pairing-information reads (register 0xB5). Some Nano
    /// receivers don't; hosts then fall back to announcements.
    public var supportsPairingInfo: Bool {
        get { synchronized { _supportsPairingInfo } }
        set { synchronized { _supportsPairingInfo = newValue } }
    }

    /// Register 0x00 as last written (three bytes; byte 1 bit 0x01 = wireless notifications,
    /// 0x08 = software present). Preset it to model flags another program set.
    public var notificationFlags: [UInt8] {
        get { synchronized { _notificationFlags } }
        set { synchronized { _notificationFlags = Array((newValue + [0, 0, 0]).prefix(3)) } }
    }

    /// When true, link notifications (0x40, 0x41) are only sent while register 0x00 has wireless
    /// notifications enabled. Off by default: they are always sent.
    public var linkNotificationsNeedFlag: Bool {
        get { synchronized { _linkNotificationsNeedFlag } }
        set { synchronized { _linkNotificationsNeedFlag = newValue } }
    }

    /// Whether the receiver accepts register 0x00 (notification flags). When false, reads and
    /// writes of it fail with "invalid address", as on receivers that don't have it.
    public var supportsNotificationFlags: Bool {
        get { synchronized { _supportsNotificationFlags } }
        set { synchronized { _supportsNotificationFlags = newValue } }
    }

    /// What receiver information (0xB5 sub-register 0x03) reports. Slots 1...6 work regardless.
    public var maxSlots: UInt8 {
        get { synchronized { _maxSlots } }
        set { synchronized { _maxSlots = newValue } }
    }

    /// Short or long register writes to `address` (sub-ID 0x80 or 0x82).
    public func registerWriteCount(_ address: UInt8) -> Int { synchronized { registerWrites[address] ?? 0 } }

    /// Short or long register reads of `address` (sub-ID 0x81 or 0x83).
    public func registerReadCount(_ address: UInt8) -> Int { synchronized { registerReads[address] ?? 0 } }

    // MARK: Pairing

    /// Pairs a device to `slot` (replacing whatever was there). `announce` reports the link-up.
    public func pair(_ profile: SimulatedDeviceProfile, slot: UInt8, announce: Bool = true) {
        let pending: (HIDPPMessage?, TimeInterval) = synchronized {
            units[slot] = Unit(profile: profile)
            return (announce ? linkNotification(slot: slot, up: true) : nil, latency(of: slot))
        }
        if let message = pending.0 { emit(message, after: pending.1) }
    }

    /// Removes the pairing in `slot`; the receiver reports 0x40.
    public func unpair(slot: UInt8) {
        let pending: (HIDPPMessage?, TimeInterval)? = synchronized {
            guard units.removeValue(forKey: slot) != nil else { return nil }
            return (gatedLinkMessage(Self.unpairNotification(slot: slot)), latency(of: slot))
        }
        if case let (message?, delay)? = pending { emit(message, after: delay) }
    }

    /// Re-pairs the device in `from` to `to`, keeping its unit (and unit ID). It comes back
    /// awake with its temporary state cleared. `announceUnpair` first reports 0x40 for `from`.
    public func repair(from: UInt8, to: UInt8, announceUnpair: Bool = true) {
        let pending: ([HIDPPMessage], TimeInterval)? = synchronized {
            guard var unit = units.removeValue(forKey: from) else { return nil }
            unit.awake = true
            unit.forgetVolatileState()
            units[to] = unit
            var messages: [HIDPPMessage] = []
            if announceUnpair, let unpaired = gatedLinkMessage(Self.unpairNotification(slot: from)) { messages.append(unpaired) }
            if let linkUp = linkNotification(slot: to, up: true) { messages.append(linkUp) }
            return (messages, latency(of: to))
        }
        if let pending { pending.0.forEach { emit($0, after: pending.1) } }
    }

    /// Sends a 0x41 for `slot` now, whatever the device is doing (a spurious or repeated
    /// announcement).
    public func announceLink(slot: UInt8, up: Bool) {
        let pending: (HIDPPMessage, TimeInterval)? = synchronized {
            units[slot].map { (connectionNotification(slot: slot, up: up, profile: $0.profile), latency(of: slot)) }
        }
        if let pending { emit(pending.0, after: pending.1) }
    }

    // MARK: Messages (called with `lock` held)

    override func linkNotification(slot: UInt8, up: Bool) -> HIDPPMessage? {
        guard let profile = units[slot]?.profile else { return nil }
        return gatedLinkMessage(connectionNotification(slot: slot, up: up, profile: profile))
    }

    private func gatedLinkMessage(_ message: HIDPPMessage) -> HIDPPMessage? {
        guard _linkNotificationsNeedFlag else { return message }
        return _notificationFlags[1] & 0x01 != 0 ? message : nil
    }

    /// 0x41: address = protocol (Unifying 0x04, Bolt 0x10); params [flags | kind, wpid lo, wpid hi],
    /// flags bit 6 = link not established.
    private func connectionNotification(slot: UInt8, up: Bool, profile: SimulatedDeviceProfile) -> HIDPPMessage {
        let pid = profile.wirelessPID ?? 0
        let flags: UInt8 = (up ? 0x00 : 0x40) | profile.pairingKindNibble
        return HIDPPMessage(reportID: .short, deviceIndex: slot, subID: 0x41, address: layout == .bolt ? 0x10 : 0x04,
                            parameters: [flags, UInt8(pid & 0xFF), UInt8(pid >> 8)])
    }

    private static func unpairNotification(slot: UInt8) -> HIDPPMessage {
        HIDPPMessage(reportID: .short, deviceIndex: slot, subID: 0x40, address: 0x02, parameters: [])
    }

    /// A made-up receiver serial number.
    private var serialBytes: [UInt8] { [0xDE, 0x30, UInt8(productID >> 8), UInt8(productID & 0xFF)] }

    override func receiverOutcome(for request: HIDPPMessage) -> Outcome {
        let p = request.parameters
        func reply(_ parameters: [UInt8]) -> Outcome {
            // Long-register reads (0x83) are answered with long reports, whatever the request's length.
            Outcome(reply: HIDPPMessage(reportID: request.subID == 0x83 ? .long : request.reportID, deviceIndex: 0xFF,
                                        subID: request.subID, address: request.address, parameters: parameters))
        }
        func error(_ code: UInt8) -> Outcome { Outcome(reply: Self.error10(request, code: code)) }

        switch (request.subID, request.address) {
        case (0x80, 0x00) where !_supportsNotificationFlags, (0x81, 0x00) where !_supportsNotificationFlags:
            return error(0x02)
        case (0x80, 0x00):
            _notificationFlags = Array(p.prefix(3))
            return Outcome(reply: request)
        case (0x81, 0x00):
            return reply(_notificationFlags)
        case (0x80, 0x02) where p[0] == 0x02:
            // Fake device arrival: a 0x41 for every paired device.
            var outcome = Outcome(reply: request)
            outcome.notifications = units.keys.sorted().compactMap { slot in
                units[slot].map { connectionNotification(slot: slot, up: $0.awake, profile: $0.profile) }
            }
            return outcome
        case (0x80, _), (0x82, _):
            return Outcome(reply: request)
        case (0x81, 0x02):
            return reply([0x00, UInt8(units.count), 0x00])
        case (0x83, 0xB5):
            return pairingRegister(p).map(reply) ?? error(_supportsPairingInfo ? 0x03 : 0x02)
        case (0x83, 0xFB) where layout == .bolt:
            return reply(serialBytes)
        case (0x81, _), (0x83, _):
            return error(0x02)
        default:
            return error(0x01)
        }
    }

    /// Long register 0xB5 sub-registers; nil answers "invalid value" (empty slot, unknown
    /// sub-register) or "invalid address" when pairing information isn't supported.
    private func pairingRegister(_ p: [UInt8]) -> [UInt8]? {
        guard _supportsPairingInfo else { return nil }
        let sub = p[0]
        if sub == 0x03 {
            return [0x03] + serialBytes + [0x00, _maxSlots]
        }
        switch layout {
        case .unifying:
            switch sub {
            case 0x20...0x25:
                // [sub, destination ID, report interval (ms), wpid (BE), 0, 0, kind].
                guard let profile = units[sub - 0x1F]?.profile else { return nil }
                let pid = profile.wirelessPID ?? 0
                return [sub, 0x00, 0x08, UInt8(pid >> 8), UInt8(pid & 0xFF), 0, 0, profile.pairingKindNibble]
            case 0x30...0x35:
                // Extended: [sub, serial (4) = unit ID, report types (4), power switch location].
                guard let profile = units[sub - 0x2F]?.profile else { return nil }
                return [sub] + Self.bytes(profile.unitID ?? 0) + [0, 0, 0, 0, 0]
            case 0x40...0x45:
                // [sub, length, codename].
                guard let profile = units[sub - 0x3F]?.profile else { return nil }
                let name = Array(profile.codename.utf8.prefix(14))
                return [sub, UInt8(name.count)] + name
            default:
                return nil
            }
        case .bolt:
            switch sub {
            case 0x51...0x56:
                // [sub, kind, wpid lo, wpid hi, serial (4) = unit ID].
                guard let profile = units[sub - 0x50]?.profile else { return nil }
                let pid = profile.wirelessPID ?? 0
                return [sub, profile.pairingKindNibble, UInt8(pid & 0xFF), UInt8(pid >> 8)] + Self.bytes(profile.unitID ?? 0)
            case 0x61...0x66:
                // [sub, page, length, codename].
                guard let profile = units[sub - 0x60]?.profile else { return nil }
                let name = Array(profile.codename.utf8.prefix(13))
                return [sub, 0x01, UInt8(name.count)] + name
            default:
                return nil
            }
        }
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

// MARK: - Direct

/// One simulated device connected directly (USB cable or Bluetooth), at device index 0xFF.
/// The per-device API of `SimulatedHIDPPTransport` works with `slot: 0xFF`; the members
/// below are shorthands for it.
public final class SimulatedDirect: SimulatedHIDPPTransport, @unchecked Sendable {
    public static let index: UInt8 = 0xFF

    public let profile: SimulatedDeviceProfile
    public let connection: ConnectionKind

    public init(profile: SimulatedDeviceProfile, connection: ConnectionKind = .usb) {
        self.profile = profile
        self.connection = connection
        super.init(units: [Self.index: profile], transportKind: .direct(connection))
    }

    /// The product ID macOS would report for the interface: the USB or Bluetooth PID.
    public var productID: UInt16? {
        connection == .usb ? profile.usbPID : profile.bluetoothPID
    }

    public var isAwake: Bool { isAwake(slot: Self.index) }
    public var diverted: Set<UInt16> { diverted(slot: Self.index) }
    public var rawXY: Set<UInt16> { rawXY(slot: Self.index) }
    public var dpi: Int? { dpi(slot: Self.index) }
    public var currentHost: Int? { currentHost(slot: Self.index) }
    public var hostSwitches: [UInt8] { hostSwitches(slot: Self.index) }
    public var batteryLevel: Int? { batteryLevel(slot: Self.index) }
    public var pingCount: Int { pingCount(slot: Self.index) }

    public func hold(_ cids: [UInt16]) { hold(cids, slot: Self.index) }
    public func release() { release(slot: Self.index) }
    public func move(dx: Int, dy: Int) { move(dx: dx, dy: dy, slot: Self.index) }
    /// The device stops answering (asleep, out of range); nothing is reported.
    public func goToSleep() { goToSleep(slot: Self.index) }
    public func wakeUp(clearingDiversion: Bool = true, reportReconnect: Bool = false) {
        wakeUp(slot: Self.index, clearingDiversion: clearingDiversion, announce: false, reportReconnect: reportReconnect)
    }
    public func reportReconnect() { reportReconnect(slot: Self.index) }
    public func forgetDiversion() { forgetDiversion(slot: Self.index) }
    public func setDPINatively(_ dpi: Int) { setDPINatively(dpi, slot: Self.index) }
    public func reportBattery(percentage: Int, charging: Bool = false) {
        reportBattery(percentage: percentage, charging: charging, slot: Self.index)
    }
    public func failDiversion(of cid: UInt16, code: UInt8, times: Int = .max) {
        failDiversion(of: cid, code: code, times: times, slot: Self.index)
    }
}
