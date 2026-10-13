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
    /// Who the device is: kind, unit and model IDs, model key. Nil only in legacy test fixtures.
    public var identity: DeviceIdentity?
    /// The endpoint this was read from; `.unassigned` on legacy single-mouse paths.
    public var address: DeviceAddress = .unassigned
    /// The REPROG_CONTROLS_V4 (0x1B04) feature version; 0 when unknown.
    public var reprogVersion: UInt8 = 0

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
        hosts: HostInfo? = nil,
        identity: DeviceIdentity? = nil,
        address: DeviceAddress = .unassigned,
        reprogVersion: UInt8 = 0
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
        self.identity = identity
        self.address = address
        self.reprogVersion = reprogVersion
    }

    /// The model's key. Fixtures without an identity are MX Verticals, the only model before v3.
    public var modelKey: ModelKey { identity?.model ?? .mxVertical }

    public var configurableControls: [ControlInfo] { controls.filter(\.isConfigurable) }

    /// The main firmware entry ("RBM 14.00.B0015"), for display.
    public var firmwareVersion: String? {
        (firmware.first { $0.kind == .firmware } ?? firmware.first)?.displayString
    }

    public func feature(_ feature: HIDPPFeature) -> FeatureEntry? {
        features.first { $0.featureID == feature.rawValue }
    }
}

/// One live HID++ 2.0 conversation with one mouse at one address: identifies it, decides whether
/// Upright can serve it, diverts the buttons that have mappings, and turns diverted-button and
/// raw XY reports into events stamped with its address.
@MainActor
public final class DeviceSession {
    public let device: HIDPPDevice
    public let connection: ConnectionKind
    /// Stamped on every event and on the snapshot.
    public let address: DeviceAddress
    /// The receiver's wireless PID for the slot, or the interface's product ID on a direct link.
    /// Keys the model when the device lists no model IDs (0x0003).
    public let transportPID: UInt16?
    /// What to call the device when it doesn't report a name: the IOHID product string of a
    /// direct link, or the codename a receiver lists for the slot. Nil uses `defaultName`.
    public let fallbackName: String?
    /// The kind the receiver lists for the slot (pairing record or 0x41). Only used when the
    /// device doesn't report its own kind (0x0005 getDeviceType), which is authoritative.
    public let kindHint: DeviceKind?

    public private(set) var snapshot: DeviceSnapshot?
    public private(set) var divertedControls: Set<UInt16> = []
    /// Diverted controls that report raw pointer movement while held.
    public private(set) var rawXYControls: Set<UInt16> = []

    public var onButtonEvent: ((ButtonEvent) -> Void)?
    /// Raw pointer movement (dx, dy) while a raw-XY control is held. Kept for single-mouse
    /// callers; `onSourcedPointerDelta` carries the address.
    public var onPointerDelta: ((Int, Int) -> Void)?
    /// Raw pointer movement while a raw-XY control is held, stamped with `address`.
    public var onSourcedPointerDelta: ((PointerDelta) -> Void)?
    /// The device reconnected (0x1D4B) and has dropped its temporary diversion state.
    public var onReconfigurationNeeded: (() -> Void)?
    public var onBatteryChange: ((BatteryStatus) -> Void)?

    /// The name used when the device reports none and no fallback was given.
    public nonisolated static var defaultName: String {
        NSLocalizedString("Logitech mouse", comment: "Name shown for a mouse that doesn't report its own name")
    }

    private struct Reporting: Equatable {
        var diverted: Bool
        var rawXY: Bool
    }

    private var tracker: ButtonStateTracker
    private var appliedState: [UInt16: Reporting] = [:]
    private var reprogIndex: UInt8?
    private var changeHostIndex: UInt8?
    private var wirelessStatusIndex: UInt8?
    private var batteryFeature: (index: UInt8, feature: HIDPPFeature)?
    /// Set when a raw-XY control goes down on a 0x1B04 v5+ device; see `isSpuriousRawXYReport`.
    private var awaitingFirstRawXYReport = false

    /// The legacy single-mouse form: events are stamped `.unassigned`.
    public convenience init(device: HIDPPDevice, connection: ConnectionKind) {
        self.init(device: device, connection: connection, address: .unassigned)
    }

    public init(
        device: HIDPPDevice,
        connection: ConnectionKind,
        address: DeviceAddress,
        transportPID: UInt16? = nil,
        fallbackName: String? = nil,
        kindHint: DeviceKind? = nil
    ) {
        self.device = device
        self.connection = connection
        self.address = address
        self.transportPID = transportPID
        self.fallbackName = fallbackName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.kindHint = kindHint
        tracker = ButtonStateTracker(source: address)
    }

    // MARK: Identification

    /// Reads who the device is and what it can do, without changing anything on it. In order:
    /// protocol version, feature table, name, kind (0x0005), unit and model IDs and serial
    /// (0x0003), the capability gate with the control table (0x1B04), then battery, firmware,
    /// pointer speed and Easy-Switch channels.
    ///
    /// The gate (D2): HID++ 2.0 or later; a pointer (0x0005 kind when the device reports one,
    /// else `kindHint`, else a control flagged as a mouse button); 0x1B04 with at least one
    /// configurable control. A device that fails it throws `HIDPPError.unsupportedDevice` with
    /// what was read so far. That is terminal: nothing was written, and it must not be retried.
    /// Errors meaning the device stopped answering are thrown as they are.
    ///
    /// `pingTimeout` bounds the first request (a sleeping receiver slot), nil uses the client's.
    public func start(pingTimeout: TimeInterval? = nil) async throws -> DeviceSnapshot {
        let version = try await device.protocolVersion(timeout: pingTimeout)
        var snapshot = DeviceSnapshot(
            name: fallbackName ?? Self.defaultName,
            connection: connection,
            deviceIndex: device.index,
            protocolVersion: "\(version.major).\(version.minor)",
            features: [],
            controls: [],
            battery: nil,
            address: address
        )
        guard version.major >= 2 else {
            snapshot.identity = DeviceIdentity(name: snapshot.name, kind: kindHint ?? .unknown, transportPID: transportPID)
            throw HIDPPError.unsupportedDevice(.hidpp10(major: version.major, minor: version.minor), partial: snapshot)
        }

        snapshot.features = try await optional { try await device.featureTable() } ?? []
        if let name = try await optional({ try await device.name() }),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot.name = name
        }
        var identity = try await DeviceFeatures(device: device).identity(name: snapshot.name, transportPID: transportPID)
        // DeviceKind(hidpp20:) never gives `.unknown`: it means 0x0005 getDeviceType didn't answer.
        let kindIsReported = identity.kind != .unknown
        if !kindIsReported, let kindHint { identity.kind = kindHint }
        snapshot.identity = identity
        snapshot.serialNumber = identity.serialNumber

        if kindIsReported ? !identity.kind.isPointer : identity.kind.isDefinitelyNotPointer {
            throw HIDPPError.unsupportedDevice(.notAPointer(identity.kind), partial: snapshot)
        }
        guard let reprog = try await device.featureIndex(for: .reprogControlsV4) else {
            throw HIDPPError.unsupportedDevice(.noReprogControls, partial: snapshot)
        }
        snapshot.reprogVersion = try await optional { try await device.featureVersion(for: .reprogControlsV4) } ?? 0
        snapshot.controls = try await ReprogControls(device: device).allControls()
        if !kindIsReported, !identity.kind.isPointer, !snapshot.controls.contains(where: \.isMouseButton) {
            throw HIDPPError.unsupportedDevice(.notAPointer(identity.kind), partial: snapshot)
        }
        guard !snapshot.configurableControls.isEmpty else {
            throw HIDPPError.unsupportedDevice(.noConfigurableControls, partial: snapshot)
        }

        reprogIndex = reprog
        wirelessStatusIndex = try await optional { try await device.featureIndex(for: .wirelessDeviceStatus) }
        for feature in [HIDPPFeature.unifiedBattery, .batteryStatus, .batteryVoltage] {
            if let index = try await optional({ try await device.featureIndex(for: feature) }) {
                batteryFeature = (index, feature)
                break
            }
        }
        snapshot.battery = await device.battery()
        try await readDeviceInfo(into: &snapshot)
        self.snapshot = snapshot
        return snapshot
    }

    // MARK: Device information

    /// Firmware, pointer speed and Easy-Switch channels. Each is optional: a missing feature or
    /// a refused request leaves it empty, but a device that stops answering fails the whole read.
    private func readDeviceInfo(into snapshot: inout DeviceSnapshot) async throws {
        let info = DeviceFeatures(device: device)
        if try await has(.deviceFirmwareVersion) {
            snapshot.firmware = try await optional { try await info.firmware() } ?? []
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
            emit(tracker.update(pressedNow: stillDiverted))
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

    // MARK: Events

    /// Consumes device events addressed to this session. Returns false for anything else.
    public func handle(_ message: HIDPPMessage) -> Bool {
        guard message.deviceIndex == device.index, message.softwareID == 0 else { return false }

        if let reprogIndex, message.featureIndex == reprogIndex {
            switch message.function {
            case 0:
                let pressed = ReprogControls.pressedControls(fromEventParameters: message.parameters)
                emit(tracker.update(pressedNow: pressed))
            case 1:
                guard !isSpuriousRawXYReport() else { break }
                let delta = ReprogControls.rawXYDelta(fromEventParameters: message.parameters)
                onPointerDelta?(delta.dx, delta.dy)
                onSourcedPointerDelta?(PointerDelta(source: address, dx: delta.dx, dy: delta.dy))
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
            let status: BatteryStatus?
            switch batteryFeature.feature {
            case .unifiedBattery:
                status = BatteryStatus(unifiedBatteryParameters: message.parameters, reportsPercentage: !(previous?.isApproximate ?? false))
            case .batteryVoltage:
                status = BatteryStatus(batteryVoltageParameters: message.parameters)
            default:
                status = BatteryStatus(batteryStatusParameters: message.parameters, previous: previous)
            }
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
        emit(tracker.reset())
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

    private func emit(_ events: [ButtonEvent]) {
        let rawXYPressed = events.contains { $0.phase == .press && rawXYControls.contains($0.cid) }
        if rawXYPressed, (snapshot?.reprogVersion ?? 0) >= 5 {
            awaitingFirstRawXYReport = true
        } else if !tracker.pressed.contains(where: rawXYControls.contains) {
            awaitingFirstRawXYReport = false
        }
        events.forEach { onButtonEvent?($0) }
    }

    /// The raw-XY quirk (D16): on REPROG_CONTROLS_V4 version 5 and later, the first raw-XY report
    /// after a raw-XY control goes down carries a bogus movement (Solaar ignores it, citing the MX
    /// Master 3S), so it is dropped. Not verified on hardware; earlier versions are unaffected.
    private func isSpuriousRawXYReport() -> Bool {
        guard awaitingFirstRawXYReport else { return false }
        awaitingFirstRawXYReport = false
        return true
    }
}
