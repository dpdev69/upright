import Foundation

// Wave 0 scaffold: final signatures only. W3.1 owns this file and implements the hub
// (D1, D10, D11, D12; §C steps 3–5 and 11). Until then nothing creates an HIDPPLink, and an
// instance stays inert: it never touches its transport and serves no endpoint.

/// The per-endpoint controller. Until W3.1 renames the class (and keeps
/// `MXVerticalController` as a typealias of it), this alias points the other way.
public typealias EndpointController = MXVerticalController

/// Timing and concurrency knobs shared by a hub and its endpoint controllers.
public struct ControllerTuning: Hashable, Sendable {
    /// How long to wait for a receiver slot to answer during discovery.
    public var probeTimeout: TimeInterval = 1.0
    /// Pause before reconfiguring a mouse that just woke up; wake-ups inside it are coalesced.
    public var reconnectDelay: TimeInterval = 0.6
    /// First retry delay while a mouse doesn't answer; doubles per attempt up to `retryMaxDelay`.
    public var retryBaseDelay: TimeInterval = 1
    public var retryMaxDelay: TimeInterval = 30
    /// How often the battery level is re-read while connected (0 disables).
    public var batteryRefreshInterval: TimeInterval = 600
    /// How long to listen for slot announcements when a receiver can't list its pairings.
    public var announcementWait: TimeInterval = 0.3
    /// Requests in flight per transport (D10). 1 until hardware shows receivers tolerate more.
    public var maxInFlight: Int = 1

    public init() {}
}

/// One opened HID interface (a receiver or a directly connected mouse): owns the HID++
/// client, the receiver's pairing directory, and one `EndpointController` per served mouse,
/// and routes messages to them by device index.
@MainActor
public final class HIDPPLink {
    /// Why an endpoint went away.
    public enum RemovalReason: Hashable, Sendable {
        /// The receiver reported the slot as un-paired.
        case unpaired
        /// The same unit identified on another slot of this receiver (a re-pair).
        case retired(movedTo: DeviceAddress)
        /// A different device (another wireless PID) now occupies the slot.
        case replaced
        /// The HID interface went away or the hub shut down.
        case transportClosed
    }

    public let link: UInt32
    public let kind: TransportKind
    public let tuning: ControllerTuning

    /// Live endpoints by device index (1...6, or 0xFF on a direct link).
    public private(set) var endpoints: [UInt8: EndpointController] = [:]
    /// `endpoints` sorted by device index.
    public var orderedEndpoints: [EndpointController] {
        endpoints.keys.sorted().compactMap { endpoints[$0] }
    }

    /// Asked synchronously, right after an endpoint is identified and before anything is
    /// diverted, for the configuration to apply. Nil means `.native`.
    public var configurationProvider: (@MainActor (DeviceAddress, DeviceSnapshot) -> EndpointConfiguration)?
    public var onEndpointChange: ((DeviceAddress, EndpointController.State) -> Void)?
    public var onEndpointRemoved: ((DeviceAddress, RemovalReason) -> Void)?
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    public var onPointerDelta: ((PointerDelta) -> Void)?
    /// The pointer speed changed natively on that mouse (and only that one).
    public var onDeviceDPIChange: ((DeviceAddress, Int?) -> Void)?
    public var onLog: ((DeviceAddress?, String) -> Void)?

    private let transport: HIDPPTransport

    public init(transport: HIDPPTransport, kind: TransportKind, link: UInt32, tuning: ControllerTuning = .init()) {
        self.transport = transport
        self.kind = kind
        self.link = link
        self.tuning = tuning
    }

    public func address(of index: UInt8) -> DeviceAddress {
        DeviceAddress(link: link, index: index)
    }

    public func start() {}

    /// Re-applies configuration (after the Mac wakes): one slot, or every endpoint.
    public func refresh(index: UInt8? = nil) {}

    /// Hands every endpoint's buttons back to its mouse. Terminal.
    public func shutdown() {}

    public func setConfiguration(_ c: EndpointConfiguration, at index: UInt8) {}

    public func cycleDPI(at index: UInt8, presets: [Int]) {}

    public func setDPI(_ dpi: Int?, at index: UInt8) {}

    /// Easy-Switch the mouse at `index` to a zero-based channel.
    public func switchToHost(_ host: Int, at index: UInt8) {}

    /// Re-reads battery, pointer speed and Easy-Switch channel: one slot, or every endpoint.
    public func refreshDeviceInfo(at index: UInt8?) {}

    /// Reconnects one endpoint, or every endpoint on this link.
    public func reconnect(index: UInt8?) {}

    /// Returns once no endpoint has queued work (tests).
    public func waitUntilIdle() async {}
}
