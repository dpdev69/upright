import Foundation

// Wave 0 scaffold: inert transports with the planned per-slot API. W1.6 owns `Simulation/`
// and implements them (HID++ answers, 0x40/0x41, register 0x00/0x02/0xB5, faults, counters),
// and may reshape the API. Until then they answer nothing, so requests time out.

/// A software Unifying, Nano or Bolt receiver with simulated devices in slots 1...6.
public final class SimulatedReceiver: HIDPPTransport {
    public var onReport: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    public let productID: UInt16
    public let layout: PairingLayout
    /// Paired devices by slot.
    public private(set) var slots: [UInt8: SimulatedDeviceProfile]

    public init(productID: UInt16 = 0xC52B, layout: PairingLayout = .unifying, slots: [UInt8: SimulatedDeviceProfile] = [:]) {
        self.productID = productID
        self.layout = layout
        self.slots = slots
    }

    public func send(_ bytes: [UInt8]) throws {}

    // MARK: Pairing

    public func pair(_ profile: SimulatedDeviceProfile, slot: UInt8) {
        slots[slot] = profile
    }

    public func unpair(slot: UInt8) {
        slots[slot] = nil
    }

    /// Moves a device to another slot, keeping its unit ID (a re-pair).
    public func repair(from: UInt8, to: UInt8) {
        guard let profile = slots.removeValue(forKey: from) else { return }
        slots[to] = profile
    }

    // MARK: Per-slot behavior

    public func hold(_ cids: [UInt16], slot: UInt8) {}
    public func release(slot: UInt8) {}
    public func move(dx: Int, dy: Int, slot: UInt8) {}
    public func goToSleep(slot: UInt8) {}
    public func wakeUp(slot: UInt8) {}
    public func setDPINatively(_ dpi: Int, slot: UInt8) {}

    // MARK: Per-slot state

    public func diverted(slot: UInt8) -> Set<UInt16> { [] }
    public func rawXY(slot: UInt8) -> Set<UInt16> { [] }
    public func dpi(slot: UInt8) -> Int? { nil }

    // MARK: Faults and counters

    public func setDropsRequests(_ drops: Bool, slot: UInt8) {}
    public func setLatency(_ latency: TimeInterval, slot: UInt8) {}
    public func setReportingCount(slot: UInt8) -> Int { 0 }
    public func pingCount(slot: UInt8) -> Int { 0 }
    /// The most requests that were ever unanswered at once (the request gate keeps it at 1).
    public var requestsInFlightMax: Int { 0 }

    /// The receiver is unplugged.
    public func disconnect() {
        onClose?()
    }
}

/// One simulated device connected directly (USB cable or Bluetooth), at device index 0xFF.
public final class SimulatedDirect: HIDPPTransport {
    public var onReport: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    public let profile: SimulatedDeviceProfile
    public let connection: ConnectionKind

    public init(profile: SimulatedDeviceProfile, connection: ConnectionKind = .usb) {
        self.profile = profile
        self.connection = connection
    }

    public func send(_ bytes: [UInt8]) throws {}

    public func disconnect() {
        onClose?()
    }
}
