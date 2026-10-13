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
    /// Pointer speed, when the mouse has ADJUSTABLE_DPI (0x2201).
    public var dpi: DPIInfo?
    public var firmware: [FirmwareInfo]
    public var serialNumber: String?
    /// Easy-Switch channels, when the mouse has CHANGE_HOST (0x1814).
    public var hosts: HostInfo?

    public init(
        name: String,
        connection: ConnectionKind,
        deviceIndex: UInt8,
        protocolVersion: String,
        features: [FeatureEntry],
        controls: [ControlInfo],
        battery: BatteryStatus?,
        dpi: DPIInfo? = nil,
        firmware: [FirmwareInfo] = [],
        serialNumber: String? = nil,
        hosts: HostInfo? = nil
    ) {
        self.name = name
        self.connection = connection
        self.deviceIndex = deviceIndex
        self.protocolVersion = protocolVersion
        self.features = features
        self.controls = controls
        self.battery = battery
        self.dpi = dpi
        self.firmware = firmware
        self.serialNumber = serialNumber
        self.hosts = hosts
    }

    public var configurableControls: [ControlInfo] { controls.filter(\.isConfigurable) }

    /// The main firmware entry ("RBM 14.00.B0015"), for display.
    public var firmwareVersion: String? {
        (firmware.first { $0.kind == .firmware } ?? firmware.first)?.displayString
    }

    public func feature(_ feature: HIDPPFeature) -> FeatureEntry? {
        features.first { $0.featureID == feature.rawValue }
    }
}

/// One live HID++ 2.0 conversation with an MX Vertical: discovers its features and controls,
/// diverts the buttons that have mappings, and turns diverted-button and raw XY reports into events.
@MainActor
public final class DeviceSession {
    public let device: HIDPPDevice
    public let connection: ConnectionKind
    public private(set) var snapshot: DeviceSnapshot?
    public private(set) var divertedControls: Set<UInt16> = []
    /// Diverted controls that report raw pointer movement while held.
    public private(set) var rawXYControls: Set<UInt16> = []

    public var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw pointer movement (dx, dy) while a raw-XY control is held.
    public var onPointerDelta: ((Int, Int) -> Void)?
    /// The device reconnected (0x1D4B) and has dropped its temporary diversion state.
    public var onReconfigurationNeeded: (() -> Void)?
    public var onBatteryChange: ((BatteryStatus) -> Void)?

    private struct Reporting: Equatable {
        var diverted: Bool
        var rawXY: Bool
    }

    private var tracker = ButtonStateTracker()
    private var appliedState: [UInt16: Reporting] = [:]
    private var reprogIndex: UInt8?
    private var changeHostIndex: UInt8?
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

        var snapshot = DeviceSnapshot(
            name: name,
            connection: connection,
            deviceIndex: device.index,
            protocolVersion: "\(version.major).\(version.minor)",
            features: features,
            controls: controls,
            battery: battery
        )
        try await readDeviceInfo(into: &snapshot)
        self.snapshot = snapshot
        return snapshot
    }

    // MARK: Device information

    /// Firmware, serial number, pointer speed and Easy-Switch channels. Each is optional: a
    /// missing feature or a refused request leaves it empty, but a device that stops answering
    /// fails the whole read.
    private func readDeviceInfo(into snapshot: inout DeviceSnapshot) async throws {
        let info = DeviceFeatures(device: device)
        if try await has(.deviceFirmwareVersion) {
            snapshot.firmware = try await optional { try await info.firmware() } ?? []
            let version = snapshot.feature(.deviceFirmwareVersion)?.version ?? 0
            if version >= 4 {
                snapshot.serialNumber = try await optional { try await info.serialNumber() }
            }
        }
        if try await has(.adjustableDPI) {
            snapshot.dpi = try await optional { try await info.dpi() }
        }
        if try await has(.changeHost) {
            changeHostIndex = try await device.featureIndex(for: .changeHost)
            if var hosts = try await optional({ try await info.hosts() }) {
                if try await has(.hostsInfo) {
                    hosts.names = try await optional { try await info.hostNames(count: hosts.count) } ?? []
                }
                snapshot.hosts = hosts
            }
        }
    }

    /// Re-reads the current pointer speed (the top button changes it natively when not diverted).
    public func refreshDPI() async throws {
        guard snapshot != nil, try await has(.adjustableDPI) else { return }
        let info = DeviceFeatures(device: device)
        if snapshot?.dpi == nil {
            snapshot?.dpi = try await optional { try await info.dpi() }
        } else if let current = try await optional({ try await info.currentDPI() }) {
            snapshot?.dpi?.current = current
        }
    }

    /// Sets the pointer speed to the supported value nearest `value`. Returns the value applied,
    /// or nil when the mouse can't change its resolution.
    @discardableResult
    public func setDPI(_ value: Int) async throws -> Int? {
        guard let dpi = snapshot?.dpi else { return nil }
        let target = dpi.nearest(to: value)
        try await DeviceFeatures(device: device).setDPI(target)
        snapshot?.dpi?.current = target
        return target
    }

    /// Re-reads which Easy-Switch channel is active.
    public func refreshHosts() async throws {
        guard snapshot?.hosts != nil else { return }
        if let hosts = try await optional({ try await DeviceFeatures(device: device).hosts() }) {
            snapshot?.hosts?.count = hosts.count
            snapshot?.hosts?.current = hosts.current
        }
    }

    /// Fire-and-forget setCurrentHost for a zero-based channel, or nil without Easy-Switch.
    public func changeHostMessage(host: Int) -> HIDPPMessage? {
        guard let changeHostIndex else { return nil }
        return DeviceFeatures.changeHostMessage(deviceIndex: device.index, featureIndex: changeHostIndex, host: host, softwareID: device.client.softwareID)
    }

    private func has(_ feature: HIDPPFeature) async throws -> Bool {
        try await optional { try await device.featureIndex(for: feature) } != nil
    }

    /// Runs an optional read: device errors and missing features give nil, but a device that
    /// stopped answering (or a closed transport) still throws.
    private func optional<T>(_ body: () async throws -> T?) async throws -> T? {
        do {
            return try await body()
        } catch let error as HIDPPError where error.meansDeviceUnreachable || error == .transportClosed {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: Diversion

    /// Diverts exactly the configurable controls in `wanted` plus those in `rawXY`; every other
    /// configurable control goes back to its native behavior. Controls in `rawXY` that support it
    /// also report raw movement while held. `force` re-sends state the device may have lost.
    ///
    /// A control the device refuses is skipped so it can't block the others; the refusals are
    /// returned by CID and retried on the next call. Errors meaning the device stopped
    /// answering are thrown.
    @discardableResult
    public func applyDiversion(_ wanted: Set<UInt16>, rawXY: Set<UInt16> = [], force: Bool = false) async throws -> [UInt16: Error] {
        guard let snapshot else { return [:] }
        if force { appliedState.removeAll() }
        let wanted = wanted.union(rawXY)

        let stillDiverted = tracker.pressed.filter(wanted.contains)
        if stillDiverted.count != tracker.pressed.count {
            tracker.update(pressedNow: stillDiverted).forEach { onButtonEvent?($0) }
        }

        let reprog = ReprogControls(device: device)
        var failures: [UInt16: Error] = [:]
        for control in snapshot.configurableControls {
            let divert = wanted.contains(control.cid)
            // Raw XY bits are only sent to controls that advertise the capability.
            let raw: Bool? = control.supportsRawXY ? divert && rawXY.contains(control.cid) : nil
            let target = Reporting(diverted: divert, rawXY: raw ?? false)
            if appliedState[control.cid] == target { continue }
            do {
                try await reprog.setReporting(cid: control.cid, diverted: divert, rawXY: raw)
            } catch let error as HIDPPError where error.meansDeviceUnreachable || error == .transportClosed {
                throw error
            } catch {
                failures[control.cid] = error
                continue
            }
            appliedState[control.cid] = target
            if divert {
                divertedControls.insert(control.cid)
            } else {
                divertedControls.remove(control.cid)
            }
            if target.rawXY {
                rawXYControls.insert(control.cid)
            } else {
                rawXYControls.remove(control.cid)
            }
        }
        return failures
    }

    public func refreshBattery() async {
        guard let battery = await device.battery(previous: snapshot?.battery) else { return }
        snapshot?.battery = battery
    }

    /// Consumes device events addressed to this session. Returns false for anything else.
    public func handle(_ message: HIDPPMessage) -> Bool {
        guard message.deviceIndex == device.index, message.softwareID == 0 else { return false }

        if let reprogIndex, message.featureIndex == reprogIndex {
            switch message.function {
            case 0:
                let pressed = ReprogControls.pressedControls(fromEventParameters: message.parameters)
                tracker.update(pressedNow: pressed).forEach { onButtonEvent?($0) }
            case 1:
                let delta = ReprogControls.rawXYDelta(fromEventParameters: message.parameters)
                onPointerDelta?(delta.dx, delta.dy)
            default:
                break
            }
            return true
        }
        guard message.function == 0 else { return false }
        if let wirelessStatusIndex, message.featureIndex == wirelessStatusIndex {
            // [status, request, reason]; status 1 means the device just reconnected.
            if message.parameters[0] == 1 {
                appliedState.removeAll()
                onReconfigurationNeeded?()
            }
            return true
        }
        if let batteryFeature, message.featureIndex == batteryFeature.index {
            let previous = snapshot?.battery
            let status = batteryFeature.feature == .unifiedBattery
                ? BatteryStatus(unifiedBatteryParameters: message.parameters, reportsPercentage: !(previous?.isApproximate ?? false))
                : BatteryStatus(batteryStatusParameters: message.parameters, previous: previous)
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
            ReprogControls.undivertMessage(deviceIndex: device.index, featureIndex: reprogIndex, cid: $0,
                                           softwareID: device.client.softwareID, clearRawXY: rawXYControls.contains($0))
        }
    }
}
