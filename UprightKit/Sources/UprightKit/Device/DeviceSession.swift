import Foundation

/// Everything Upright learned about a connected mouse.
public struct DeviceSnapshot: Hashable, Sendable {
    public var name: String
    public var connection: ConnectionKind
    public var deviceIndex: UInt8
    public var protocolVersion: String
    public var features: [FeatureEntry]
    public var controls: [ControlInfo]
    public var battery: BatteryStatus?

    public init(name: String, connection: ConnectionKind, deviceIndex: UInt8, protocolVersion: String, features: [FeatureEntry], controls: [ControlInfo], battery: BatteryStatus?) {
        self.name = name
        self.connection = connection
        self.deviceIndex = deviceIndex
        self.protocolVersion = protocolVersion
        self.features = features
        self.controls = controls
        self.battery = battery
    }

    public var configurableControls: [ControlInfo] { controls.filter(\.isConfigurable) }
}

/// One live HID++ 2.0 conversation with an MX Vertical: discovers its features and controls,
/// diverts the buttons that have mappings, and turns diverted-button reports into events.
@MainActor
public final class DeviceSession {
    public let device: HIDPPDevice
    public let connection: ConnectionKind
    public private(set) var snapshot: DeviceSnapshot?
    public private(set) var divertedControls: Set<UInt16> = []

    public var onButtonEvent: ((ButtonEvent) -> Void)?
    /// The device reconnected (0x1D4B) and has dropped its temporary diversion state.
    public var onReconfigurationNeeded: (() -> Void)?
    public var onBatteryChange: ((BatteryStatus) -> Void)?

    private var tracker = ButtonStateTracker()
    private var appliedState: [UInt16: Bool] = [:]
    private var reprogIndex: UInt8?
    private var wirelessStatusIndex: UInt8?
    private var batteryFeature: (index: UInt8, feature: HIDPPFeature)?

    public init(device: HIDPPDevice, connection: ConnectionKind) {
        self.device = device
        self.connection = connection
    }

    public func start() async throws -> DeviceSnapshot {
        let version = try await device.protocolVersion()
        guard version.major >= 2 else {
            throw HIDPPError.unsupportedProtocol(major: version.major, minor: version.minor)
        }
        let features = (try? await device.featureTable()) ?? []
        let name = (try? await device.name()) ?? MXVertical.displayName

        guard let reprog = try await device.featureIndex(for: .reprogControlsV4) else {
            throw HIDPPError.featureNotSupported(HIDPPFeature.reprogControlsV4.rawValue)
        }
        reprogIndex = reprog
        wirelessStatusIndex = (try? await device.featureIndex(for: .wirelessDeviceStatus)) ?? nil
        if let index = (try? await device.featureIndex(for: .unifiedBattery)) ?? nil {
            batteryFeature = (index, .unifiedBattery)
        } else if let index = (try? await device.featureIndex(for: .batteryStatus)) ?? nil {
            batteryFeature = (index, .batteryStatus)
        }

        let controls = try await ReprogControls(device: device).allControls()
        let battery = await device.battery()

        let snapshot = DeviceSnapshot(
            name: name,
            connection: connection,
            deviceIndex: device.index,
            protocolVersion: "\(version.major).\(version.minor)",
            features: features,
            controls: controls,
            battery: battery
        )
        self.snapshot = snapshot
        return snapshot
    }

    /// Diverts exactly the configurable controls in `wanted`; every other configurable control
    /// goes back to its native behavior. `force` re-sends state the device may have lost.
    public func applyDiversion(_ wanted: Set<UInt16>, force: Bool = false) async throws {
        guard let snapshot else { return }
        if force { appliedState.removeAll() }

        let stillDiverted = tracker.pressed.filter(wanted.contains)
        if stillDiverted.count != tracker.pressed.count {
            tracker.update(pressedNow: stillDiverted).forEach { onButtonEvent?($0) }
        }

        let reprog = ReprogControls(device: device)
        for control in snapshot.configurableControls {
            let divert = wanted.contains(control.cid)
            if appliedState[control.cid] == divert { continue }
            try await reprog.setDiverted(divert, cid: control.cid)
            appliedState[control.cid] = divert
            if divert {
                divertedControls.insert(control.cid)
            } else {
                divertedControls.remove(control.cid)
            }
        }
    }

    public func refreshBattery() async {
        guard let battery = await device.battery() else { return }
        snapshot?.battery = battery
    }

    /// Consumes device events addressed to this session. Returns false for anything else.
    public func handle(_ message: HIDPPMessage) -> Bool {
        guard message.deviceIndex == device.index, message.softwareID == 0, message.function == 0 else { return false }

        if let reprogIndex, message.featureIndex == reprogIndex {
            let pressed = ReprogControls.pressedControls(fromEventParameters: message.parameters)
            tracker.update(pressedNow: pressed).forEach { onButtonEvent?($0) }
            return true
        }
        if let wirelessStatusIndex, message.featureIndex == wirelessStatusIndex {
            // [status, request, reason]; status 1 means the device just reconnected.
            if message.parameters[0] == 1 {
                appliedState.removeAll()
                onReconfigurationNeeded?()
            }
            return true
        }
        if let batteryFeature, message.featureIndex == batteryFeature.index {
            let status = batteryFeature.feature == .unifiedBattery
                ? BatteryStatus(unifiedBatteryParameters: message.parameters)
                : BatteryStatus(batteryStatusParameters: message.parameters)
            if let status {
                snapshot?.battery = status
                onBatteryChange?(status)
            }
            return true
        }
        return false
    }

    /// Emits release events for anything still held (the device went away mid-press).
    public func releaseAll() {
        tracker.reset().forEach { onButtonEvent?($0) }
    }

    /// The device may have lost diversion state (sleep, power cycle); re-send everything next time.
    public func invalidateAppliedState() {
        appliedState.removeAll()
    }

    /// Fire-and-forget messages that hand every diverted control back to the mouse.
    public func restoreMessages() -> [HIDPPMessage] {
        guard let reprogIndex else { return [] }
        return divertedControls.sorted().map {
            ReprogControls.undivertMessage(deviceIndex: device.index, featureIndex: reprogIndex, cid: $0, softwareID: device.client.softwareID)
        }
    }
}
