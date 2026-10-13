import Foundation
@testable import UprightKit

/// A software MX Vertical that answers HID++ requests the way the real mouse (and a
/// Unifying receiver in front of it) does. Replies arrive asynchronously, like IOKit's.
final class SimulatedMXVertical: HIDPPTransport, @unchecked Sendable {
    enum Mode {
        case direct
        case receiver(slot: UInt8)
    }

    var onReport: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let mode: Mode
    let name: String
    private let queue = DispatchQueue(label: "simulated-mx-vertical")
    private let lock = NSLock()

    private var _awake = true
    private var _diverted: Set<UInt16> = []
    private var _sent: [[UInt8]] = []

    static let features: [UInt16] = [0x0000, 0x0001, 0x0005, 0x1000, 0x1B04, 0x1D4B]
    static let reprogIndex: UInt8 = 4
    static let wirelessStatusIndex: UInt8 = 5

    /// (cid, flags): mirrors the MX Vertical's control table shape.
    static let controls: [(UInt16, UInt8)] = [
        (0x0050, 0x01),        // left click: mouse button, not divertable
        (0x0051, 0x01),        // right click
        (0x0052, 0x31),        // wheel click: mouse, reprogrammable, divertable
        (0x0053, 0x31),        // back
        (0x0056, 0x31),        // forward
        (0x00FD, 0x30),        // DPI switch: reprogrammable, divertable
        (0x00D7, 0xB4),        // virtual gesture button: virtual, divertable
    ]

    init(mode: Mode, name: String = "MX Vertical") {
        self.mode = mode
        self.name = name
    }

    var deviceIndex: UInt8 {
        switch mode {
        case .direct: return 0xFF
        case .receiver(let slot): return slot
        }
    }

    var diverted: Set<UInt16> { lock.locked { _diverted } }
    var sentReports: [[UInt8]] { lock.locked { _sent } }

    // MARK: Test controls

    /// The mouse turns off or sleeps: the receiver reports link loss, requests time out.
    func goToSleep() {
        lock.locked { _awake = false }
        emit(connectionNotification(linkUp: false))
    }

    /// The mouse powers back on with its temporary diversion state cleared.
    func wakeUp(clearingDiversion: Bool = true) {
        lock.locked {
            _awake = true
            if clearingDiversion { _diverted.removeAll() }
        }
        emit(connectionNotification(linkUp: true))
    }

    /// The mouse sends 0x1D4B "reconnection" after losing its configuration.
    func reportReconnect() {
        lock.locked { _diverted.removeAll() }
        emit(HIDPPMessage(reportID: .long, deviceIndex: deviceIndex, subID: Self.wirelessStatusIndex, address: 0x00, parameters: [1, 1, 0]).bytes)
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

    // MARK: HIDPPTransport

    func send(_ bytes: [UInt8]) throws {
        lock.locked { _sent.append(bytes) }
        guard let request = HIDPPMessage(bytes: bytes) else { return }
        if let reply = respond(to: request) {
            emit(reply.bytes)
        }
    }

    // MARK: Behavior

    private func emit(_ bytes: [UInt8]) {
        queue.async { self.onReport?(bytes) }
    }

    private func connectionNotification(linkUp: Bool) -> [UInt8] {
        HIDPPMessage(reportID: .short, deviceIndex: deviceIndex, subID: 0x41, address: 0x04, parameters: [linkUp ? 0x00 : 0x40, 0x7B, 0x40]).bytes
    }

    private func respond(to request: HIDPPMessage) -> HIDPPMessage? {
        let awake = lock.locked { _awake }

        if request.deviceIndex == 0xFF, case .receiver = mode {
            // Receiver register access (HID++ 1.0): acknowledge writes.
            return request.subID == 0x80 ? request : error10(request, code: 0x01)
        }
        guard request.deviceIndex == deviceIndex else {
            return error10(request, code: 0x09)
        }
        guard awake else {
            if case .receiver = mode { return error10(request, code: 0x09) }
            return nil
        }

        var reply = request
        let p = request.parameters
        switch (request.featureIndex, request.function) {
        case (0, 0):
            let id = p.uint16(at: 0)
            let index = Self.features.firstIndex(of: id).map(UInt8.init) ?? 0
            reply = with(request, [index, 0, 0])
        case (0, 1):
            reply = with(request, [4, 5, p[2]])
        case (1, 0):
            reply = with(request, [UInt8(Self.features.count - 1)])
        case (1, 1):
            let id = Self.features[Int(p[0])]
            reply = with(request, id.bigEndianBytes + [0, 0])
        case (2, 0):
            reply = with(request, [UInt8(name.utf8.count)])
        case (2, 1):
            reply = with(request, Array(name.utf8.dropFirst(Int(p[0])).prefix(16)))
        case (3, 0):
            reply = with(request, [80, 50, 0])
        case (Self.reprogIndex, 0):
            reply = with(request, [UInt8(Self.controls.count)])
        case (Self.reprogIndex, 1):
            let (cid, flags) = Self.controls[Int(p[0])]
            reply = with(request, cid.bigEndianBytes + [0, UInt8(p[0]), flags, p[0], 0, 0, 0])
        case (Self.reprogIndex, 2):
            let cid = p.uint16(at: 0)
            reply = with(request, cid.bigEndianBytes + [diverted.contains(cid) ? 0x01 : 0x00, 0, 0])
        case (Self.reprogIndex, 3):
            let cid = p.uint16(at: 0)
            guard let control = Self.controls.first(where: { $0.0 == cid }), control.1 & 0x20 != 0 else {
                return error20(request, code: 0x02)
            }
            if p[2] & 0x02 != 0 {
                lock.locked {
                    if p[2] & 0x01 != 0 { _diverted.insert(cid) } else { _diverted.remove(cid) }
                }
            }
            reply = with(request, Array(p.prefix(5)))
        default:
            return error20(request, code: 0x07)
        }
        return reply
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
