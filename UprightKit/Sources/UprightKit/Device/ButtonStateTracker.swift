public struct ButtonEvent: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case press, release }

    public var cid: UInt16
    public var phase: Phase

    public init(cid: UInt16, phase: Phase) {
        self.cid = cid
        self.phase = phase
    }
}

/// Turns divertedButtonsEvent snapshots ("these CIDs are down right now") into
/// individual press and release events.
public struct ButtonStateTracker: Sendable {
    public private(set) var pressed: [UInt16] = []

    public init() {}

    public mutating func update(pressedNow: [UInt16]) -> [ButtonEvent] {
        let releases = pressed.filter { !pressedNow.contains($0) }.map { ButtonEvent(cid: $0, phase: .release) }
        let presses = pressedNow.filter { !pressed.contains($0) }.map { ButtonEvent(cid: $0, phase: .press) }
        pressed = pressedNow
        return releases + presses
    }

    /// Releases everything still held, e.g. when the device disconnects mid-press.
    public mutating func reset() -> [ButtonEvent] {
        update(pressedNow: [])
    }
}
