import Foundation
@testable import UprightKit

/// The single-mouse simulator the controller tests were written against, kept as a facade over
/// the Kit's multi-device simulator (`SimulatedReceiver`, `SimulatedDirect`).
///
/// "The mouse" is one MX Vertical: directly connected, or in a Unifying receiver slot. In
/// receiver mode other devices can share the receiver (`addDevice`), and the mouse can be
/// re-paired to another slot or unpaired; every member below acts on the mouse wherever it is.
/// Its control table, features, firmware, serial, pointer speed and Easy-Switch hosts are the
/// values these tests have always used; its identity (unit ID, model IDs) is
/// `DeviceProfiles.mxVertical`'s.
///
/// New tests should use `SimulatedReceiver` / `SimulatedDirect` and `DeviceProfiles` directly.
final class SimulatedMXVertical: HIDPPTransport, @unchecked Sendable {
    enum Mode {
        case direct
        case receiver(slot: UInt8)
    }

    var onReport: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let mode: Mode
    let name: String
    /// The feature table this mouse reports.
    let features: [UInt16]
    /// The simulator behind the facade.
    let simulator: SimulatedHIDPPTransport
    var receiver: SimulatedReceiver? { simulator as? SimulatedReceiver }

    private let lock = NSLock()
    /// Where the mouse answers (receiver slot or 0xFF); nil once unpaired.
    private var _mouseIndex: UInt8?

    /// The original six features keep their indices (reprog at 4, wireless status at 5).
    static let baseFeatures: [UInt16] = [0x0000, 0x0001, 0x0005, 0x1000, 0x1B04, 0x1D4B]
    static let extendedFeatures: [UInt16] = [0x0003, 0x2201, 0x1814, 0x1815]
    static let allFeatures = baseFeatures + extendedFeatures
    static let reprogIndex: UInt8 = 4
    static let wirelessStatusIndex: UInt8 = 5
    /// The wireless PID `addDevice` reports by default (an MX Keys).
    static let otherDevicePID: UInt16 = 0x408A
    /// Feature versions reported by the feature table (default 0).
    static let featureVersions: [UInt16: UInt8] = [0x0003: 4, 0x1B04: 4]

    /// 400 through 4000 in steps of 50, as getSensorDpiList encodes it.
    static let dpiList: [UInt16] = [400, UInt16(0xE000) | 50, 4000]
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

    /// The configurable controls (what the controller re-sends on every forced pass).
    static let configurableCount = 4

    init(mode: Mode, name: String = "MX Vertical", features: [UInt16] = SimulatedMXVertical.allFeatures) {
        self.mode = mode
        self.name = name
        self.features = features
        let profile = Self.isMXVertical(name)
            ? Self.mxVerticalProfile(name: name, features: features, unit: DeviceProfiles.mxVertical)
            : DeviceProfiles.mxKeys.named(name)
        switch mode {
        case .direct:
            simulator = SimulatedDirect(profile: profile)
            _mouseIndex = SimulatedDirect.index
        case .receiver(let slot):
            simulator = SimulatedReceiver.unifying([slot: profile])
            _mouseIndex = slot
        }
        simulator.onReport = { [weak self] bytes in self?.onReport?(bytes) }
        simulator.onClose = { [weak self] in self?.onClose?() }
    }

    /// The test MX Vertical: `unit`'s identity with the control table, features and device
    /// information above.
    static func mxVerticalProfile(name: String, features: [UInt16], unit: SimulatedDeviceProfile) -> SimulatedDeviceProfile {
        var profile = unit
        profile.name = name
        profile.features = features.map { SimulatedDeviceProfile.Feature($0, version: featureVersions[$0] ?? 0) }
        profile.controls = controls.enumerated().map { index, control in
            ControlInfo(cid: control.0, taskID: UInt16(index), flags: ControlFlags(rawValue: control.1),
                        position: UInt8(index), additionalFlags: control.2)
        }
        profile.firmware = [.firmware("RBM", 0x14, 0x00, build: 0x0015), .bootloader("BOT", 0x12, 0x03, build: 0), .hardware(0x48)]
        profile.serialNumber = serialNumber
        profile.dpiList = dpiList
        profile.defaultDPI = defaultDPI
        profile.battery = .status
        profile.batteryLevel = 80
        profile.hostCount = hostNames.count
        profile.hostNames = hostNames
        return profile
    }

    private static func isMXVertical(_ name: String) -> Bool {
        name.lowercased().contains("mx vertical")
    }

    private var mouseIndex: UInt8? { lock.locked { _mouseIndex } }

    /// Where the simulated mouse currently answers (its receiver slot, or 0xFF).
    var deviceIndex: UInt8 { mouseIndex ?? 0 }
    var diverted: Set<UInt16> { mouseIndex.map { simulator.diverted(slot: $0) } ?? [] }
    var rawXY: Set<UInt16> { mouseIndex.map { simulator.rawXY(slot: $0) } ?? [] }
    /// The sensor resolution the mouse is using.
    var dpi: Int { mouseIndex.flatMap { simulator.dpi(slot: $0) } ?? 0 }
    /// Every setCurrentHost the mouse received.
    var hostSwitches: [UInt8] { mouseIndex.map { simulator.hostSwitches(slot: $0) } ?? [] }
    var sentReports: [[UInt8]] { simulator.sentReports }

    /// While true the mouse ignores requests, so they time out (it still sends its own reports).
    var dropsRequests: Bool {
        get { simulator.dropsRequests }
        set { simulator.dropsRequests = newValue }
    }

    /// Delay before every reply and report.
    var latency: TimeInterval {
        get { simulator.latency }
        set { simulator.latency = newValue }
    }

    /// Whether the receiver answers pairing-info reads (register 0xB5).
    var supportsPairingInfo: Bool {
        get { receiver?.supportsPairingInfo ?? false }
        set { receiver?.supportsPairingInfo = newValue }
    }

    // MARK: Test controls

    /// Pairs another device to the receiver (without announcing it). An "MX Vertical" is a
    /// second unit of the test mouse; any other name is an MX Keys keyboard with that name.
    func addDevice(slot: UInt8, name: String, wirelessPID: UInt16 = SimulatedMXVertical.otherDevicePID) {
        var profile = Self.isMXVertical(name)
            ? Self.mxVerticalProfile(name: name, features: features, unit: DeviceProfiles.mxVerticalSecondUnit)
            : DeviceProfiles.mxKeys.named(name)
        profile.wirelessPID = wirelessPID
        receiver?.pair(profile, slot: slot, announce: false)
    }

    /// The mouse turns off or sleeps: the receiver reports link loss, requests fail.
    func goToSleep() {
        guard let index = mouseIndex else { return }
        simulator.goToSleep(slot: index)
    }

    /// The mouse powers back on with its temporary diversion state cleared. `announce` sends
    /// the receiver's 0x41 link-up; `reportReconnect` also sends the mouse's own 0x1D4B.
    func wakeUp(clearingDiversion: Bool = true, announce: Bool = true, reportReconnect: Bool = false) {
        guard let index = mouseIndex else { return }
        simulator.wakeUp(slot: index, clearingDiversion: clearingDiversion, announce: announce, reportReconnect: reportReconnect)
    }

    /// The mouse sends 0x1D4B "reconnection" after losing its configuration.
    func reportReconnect() {
        guard let index = mouseIndex else { return }
        simulator.reportReconnect(slot: index)
    }

    /// The mouse silently loses its diversion state and pointer speed (no report is sent).
    func forgetDiversion() {
        guard let index = mouseIndex else { return }
        simulator.forgetDiversion(slot: index)
    }

    /// The top button cycles the pointer speed in firmware (when not diverted); nothing is reported.
    func setDPINatively(_ dpi: Int) {
        guard let index = mouseIndex else { return }
        simulator.setDPINatively(dpi, slot: index)
    }

    /// Broadcasts a BATTERY_STATUS (0x1000) event, as the mouse does when its level changes.
    func reportBattery(percentage: UInt8, charging: Bool = false) {
        guard let index = mouseIndex else { return }
        simulator.reportBattery(percentage: Int(percentage), charging: charging, slot: index)
    }

    /// Reports raw movement for a held raw-XY control, like divertedRawMouseXYEvent.
    func move(dx: Int, dy: Int) {
        guard let index = mouseIndex else { return }
        simulator.move(dx: dx, dy: dy, slot: index)
    }

    /// Makes setCidReporting for `cid` fail with HID++ 2.0 error `code`, `times` times.
    func failDiversion(of cid: UInt16, code: UInt8, times: Int = .max) {
        guard let index = mouseIndex else { return }
        simulator.failDiversion(of: cid, code: code, times: times, slot: index)
    }

    /// Re-pairs the mouse to `slot`. `announceUnpair` first reports 0x40 for the old slot.
    func repair(toSlot slot: UInt8, announceUnpair: Bool) {
        guard let receiver, let index = mouseIndex else { return }
        lock.locked { _mouseIndex = slot }
        receiver.repair(from: index, to: slot, announceUnpair: announceUnpair)
    }

    /// Removes the mouse's pairing; the receiver reports 0x40.
    func unpair() {
        guard let receiver, let index = mouseIndex else { return }
        lock.locked { _mouseIndex = nil }
        receiver.unpair(slot: index)
    }

    /// Reports the currently held buttons. Like the real mouse, only diverted ones are reported.
    func hold(_ cids: [UInt16]) {
        guard let index = mouseIndex else { return }
        simulator.hold(cids, slot: index)
    }

    func disconnect() {
        simulator.disconnect()
    }

    // MARK: Request counters

    /// Requests sent to `feature` (by feature ID), optionally only for one function.
    func requestCount(feature: UInt16, function: UInt8? = nil) -> Int {
        simulator.requestCount(feature: feature, function: function)
    }

    /// setCidReporting requests sent to the mouse (and anything sharing its receiver).
    var setReportingCount: Int { simulator.setReportingCount }

    /// Root.getProtocolVersion (ping) requests sent to `index`.
    func pingCount(to index: UInt8) -> Int {
        simulator.pingCount(slot: index)
    }

    /// Receiver register writes to `address`.
    func registerWriteCount(_ address: UInt8) -> Int {
        receiver?.registerWriteCount(address) ?? 0
    }

    // MARK: HIDPPTransport

    func send(_ bytes: [UInt8]) throws {
        try simulator.send(bytes)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
