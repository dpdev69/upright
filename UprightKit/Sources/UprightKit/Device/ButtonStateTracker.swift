public struct ButtonEvent: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case press, release }

    public var cid: UInt16
    public var phase: Phase
    /// The endpoint that sent the event. Stamped by the endpoint controller; `.unassigned`
    /// from code paths that don't know their device.
    public var source: DeviceAddress = .unassigned

    public init(cid: UInt16, phase: Phase, source: DeviceAddress = .unassigned) {
        self.cid = cid
        self.phase = phase
        self.source = source
    }
}

/// Raw sensor movement (HID++ raw XY) from one endpoint while one of its raw-XY controls is held.
public struct PointerDelta: Hashable, Sendable {
    public var source: DeviceAddress
    public var dx: Int
    public var dy: Int

    public init(source: DeviceAddress = .unassigned, dx: Int, dy: Int) {
        self.source = source
        self.dx = dx
        self.dy = dy
    }
}

/// Turns divertedButtonsEvent snapshots ("these CIDs are down right now") into
/// individual press and release events, stamped with `source`.
public struct ButtonStateTracker: Sendable {
    public private(set) var pressed: [UInt16] = []
    public var source: DeviceAddress

    public init(source: DeviceAddress = .unassigned) {
        self.source = source
    }

    public mutating func update(pressedNow: [UInt16]) -> [ButtonEvent] {
        let releases = pressed.filter { !pressedNow.contains($0) }.map { ButtonEvent(cid: $0, phase: .release, source: source) }
        let presses = pressedNow.filter { !pressed.contains($0) }.map { ButtonEvent(cid: $0, phase: .press, source: source) }
        pressed = pressedNow
        return releases + presses
    }

    /// Releases everything still held, e.g. when the device disconnects mid-press.
    public mutating func reset() -> [ButtonEvent] {
        update(pressedNow: [])
    }
}
