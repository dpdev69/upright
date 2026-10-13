import Foundation
import UprightKit

// The probe's platform-independent half: the options, the "[device · link]" line prefixes, how a
// device is read and printed, and the per-link logic. Probe.swift adds the IOKit side (matching,
// opening, signals), so everything here can also be driven by the simulator.

// MARK: - Options

struct ProbeOptions: Equatable {
    /// Also list and read interfaces Upright doesn't use. Reads only; nothing is written to them.
    var all = false
    var divert = false
    /// Text a device label must contain (case-insensitive) to be diverted; nil diverts every device.
    var divertFilter: String?
    var trace = false
    var showHelp = false

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        for argument in arguments {
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--all":
                options.all = true
            case "--divert":
                options.divert = true
            case "--trace":
                options.trace = true
            default:
                guard argument.hasPrefix("--divert=") else {
                    throw UsageError(description: "unknown argument \(argument)")
                }
                let filter = argument.dropFirst("--divert=".count).trimmingCharacters(in: .whitespaces)
                guard !filter.isEmpty else {
                    throw UsageError(description: "--divert= needs a device name, for example --divert=\"MX Master\"")
                }
                options.divert = true
                options.divertFilter = filter
            }
        }
        return options
    }

    /// Whether a device is diverted. `label` is the device's label without the brackets,
    /// for example "MX Master 3S · Bolt slot 2".
    func shouldDivert(label: String) -> Bool {
        guard divert else { return false }
        guard let divertFilter else { return true }
        return label.range(of: divertFilter, options: .caseInsensitive) != nil
    }

    static let usage = """
    usage: upright-probe [--all] [--divert[=NAME]] [--trace]

    Finds Logitech mice (USB cable, Unifying, Bolt or Nano receiver, Bluetooth) and prints each
    one's HID++ identity, feature table and REPROG_CONTROLS_V4 control list, then keeps
    listening for receiver and device notifications. Every line starts with the device it
    belongs to, for example [MX Master 3S · Bolt slot 2].

      --all          Also list and read every Logitech HID++ interface Upright doesn't use:
                     Lightspeed and unknown receivers, keyboards and other devices behind a
                     receiver, HID++ 1.0 devices, and mice it doesn't recognize. These are only
                     read, never written to. Paste this output into new-mouse reports.
      --divert       Temporarily divert every remappable button of every supported mouse and
                     print press and release events, each with its mouse's prefix. Buttons
                     return to normal when you press Ctrl-C.
      --divert=NAME  The same, only for mice whose label contains NAME (case-insensitive),
                     for example --divert="master 3s" or --divert="bolt slot 2".
      --trace        Print the raw HID++ reports in both directions.

    Interfaces Upright serves are handled the way the app handles them: a receiver gets its
    notification flags turned on (read-modify-write), and --divert changes button reporting.
    """
}

// MARK: - Links

extension ConnectionKind {
    /// "Bolt", "USB", ...: the link part of a device label.
    var probeTitle: String {
        switch self {
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .unifying: return "Unifying"
        case .bolt: return "Bolt"
        case .nano: return "Nano"
        }
    }
}

/// One matched HID interface as the probe sees it.
struct ProbeLinkInfo {
    /// The hub's link number: part of every `DeviceAddress` on this interface.
    var number: UInt32
    /// "Bolt", "Unifying", "USB", "Bluetooth", "Lightspeed", ...
    var place: String
    var isReceiver: Bool
    /// How the device connects, for `DeviceSession`. A stand-in for interfaces Upright ignores.
    var connection: ConnectionKind
    var layout: PairingLayout
    var productID: UInt16?
    /// The IOHID product string; empty when there is none.
    var productName: String
    var summary: String
    /// Whether the interface can carry HID++ at all. A receiver's boot-mouse interface can't.
    var carriesHIDPP: Bool
    /// Why Upright never opens this interface; nil when it does.
    var ignoredReason: String?
    /// What Upright opens it as; nil for ignored interfaces.
    var transportKind: TransportKind?

    static func make(number: UInt32, descriptor d: HIDInterfaceDescriptor) -> ProbeLinkInfo {
        let classification = InterfaceClassifier.classify(d)
        let pid = UInt16(exactly: d.productID)
        let transport = d.transport.lowercased()

        let place: String
        let isReceiver: Bool
        let connection: ConnectionKind
        var layout = PairingLayout.unifying
        switch classification {
        case .receiver(let kind, let receiverLayout):
            (place, isReceiver, connection, layout) = (kind.probeTitle, true, kind, receiverLayout)
        case .direct(let kind):
            (place, isReceiver, connection) = (kind.probeTitle, false, kind)
        case .ignored:
            if let receiver = pid.flatMap({ DeviceCatalog.receivers[$0] }) {
                place = receiver.family.probeTitle
                isReceiver = true
                connection = receiver.kind
                layout = receiver.layout ?? (receiver.family == .bolt ? .bolt : .unifying)
            } else if let pid, (0xC500...0xC5FF).contains(pid) {
                (place, isReceiver, connection) = ("unknown receiver", true, .unifying)
            } else if transport.contains("bluetooth") {
                (place, isReceiver, connection) = ("Bluetooth", false, .bluetooth)
            } else {
                (place, isReceiver, connection) = (transport.contains("usb") ? "USB" : "HID", false, .usb)
            }
        }

        // A receiver's mouse and keyboard interfaces don't carry HID++, only its vendor-page one.
        let carries: Bool
        if classification.ignoredReason == nil {
            carries = true
        } else {
            carries = d.isVendorHIDPP || d.hasUnknownUsage || (!isReceiver && d.usagePage == 0x01)
        }
        return ProbeLinkInfo(
            number: number,
            place: place,
            isReceiver: isReceiver,
            connection: connection,
            layout: layout,
            productID: pid,
            productName: d.productName,
            summary: d.summary,
            carriesHIDPP: carries,
            ignoredReason: classification.ignoredReason,
            transportKind: classification.transportKind
        )
    }
}

extension ReceiverModel.Family {
    var probeTitle: String {
        switch self {
        case .unifying: return "Unifying"
        case .bolt: return "Bolt"
        case .nano: return "Nano"
        case .lightspeed: return "Lightspeed"
        case .legacy27MHz: return "27 MHz"
        }
    }
}

// MARK: - Output

/// Prints lines, each prefixed with the device (or link) it belongs to: "[MX Master 3S · Bolt slot 2]".
@MainActor
final class ProbeConsole {
    private let sink: (String) -> Void
    private(set) var links: [UInt32: ProbeLinkInfo] = [:]
    private var names: [DeviceAddress: String] = [:]

    init(sink: @escaping (String) -> Void = ProbeConsole.writeLine) {
        self.sink = sink
    }

    nonisolated static func writeLine(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func addLink(_ info: ProbeLinkInfo) {
        links[info.number] = info
    }

    func removeLink(_ number: UInt32) {
        links[number] = nil
        names = names.filter { $0.key.link != number }
    }

    /// The name a device reported, used in its label from now on.
    func setName(_ name: String, for address: DeviceAddress) {
        names[address] = name
    }

    func forget(_ address: DeviceAddress) {
        names[address] = nil
    }

    /// The link part of a device label: "Bolt slot 2", "USB".
    func place(of address: DeviceAddress) -> String {
        guard let link = links[address.link] else { return "link \(address.link)" }
        return link.isReceiver && !address.isDirect ? "\(link.place) slot \(address.index)" : link.place
    }

    private func baseLabel(for address: DeviceAddress) -> String {
        guard let link = links[address.link] else { return "link \(address.link)" }
        if link.isReceiver && address.isDirect { return "\(link.place) receiver" }
        let place = place(of: address)
        let name = names[address] ?? (link.isReceiver || link.productName.isEmpty ? "Logitech device" : link.productName)
        return "\(name) · \(place)"
    }

    /// "MX Master 3S · Bolt slot 2", "MX Vertical · USB", or "Bolt receiver" for the receiver itself.
    /// Two devices that would read alike (two MX Verticals on USB) are told apart by link number.
    func label(for address: DeviceAddress) -> String {
        let base = baseLabel(for: address)
        var others = Set(names.keys)
        for number in links.keys { others.insert(DeviceAddress(link: number, index: DeviceAddress.direct)) }
        let clashes = others.contains { $0.link != address.link && baseLabel(for: $0) == base }
        return clashes ? "\(base) #\(address.link)" : base
    }

    /// A line about the probe itself.
    func say(_ text: String) {
        emit("probe", text)
    }

    /// A line about an interface: its device label on a direct link, "Bolt receiver" on a receiver.
    func say(_ text: String, link: UInt32) {
        say(text, at: DeviceAddress(link: link, index: DeviceAddress.direct))
    }

    func say(_ text: String, at address: DeviceAddress) {
        emit(label(for: address), text)
    }

    private func emit(_ label: String, _ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            sink("[\(label)] \(line)")
        }
    }
}

// MARK: - Formatting

enum ProbeVerdict: Equatable {
    case supported
    /// Fails Upright's device checks (the capability gate).
    case unsupported(UnsupportedReason)
    /// Passes the checks, but the interface it sits on is one Upright never opens.
    case interfaceNotOpened(String)
}

enum ProbeFormat {
    static func hex<T: BinaryInteger>(_ value: T, _ width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    /// The name the device reported, or "Logitech device" when it reported none.
    static func displayName(_ snapshot: DeviceSnapshot) -> String {
        snapshot.name == DeviceSession.defaultName ? "Logitech device" : snapshot.name
    }

    /// The name in a device's label: the catalog's short name for a known model ("Lift"), else
    /// what the device reported. It stays the same from the first line to the last.
    static func labelName(_ snapshot: DeviceSnapshot) -> String {
        snapshot.identity.flatMap { DeviceCatalog.model($0.model)?.name } ?? displayName(snapshot)
    }

    static func batteryText(_ battery: BatteryStatus?) -> String {
        guard let battery else { return "not reported" }
        return "\(battery.percentage)%" + (battery.isApproximate ? " (approximate)" : "") + (battery.isCharging ? " (charging)" : "")
    }

    static func modelText(_ key: ModelKey) -> String {
        guard let model = DeviceCatalog.model(key) else { return "\(key.rawValue) (not in Upright's catalog)" }
        let how: String
        switch model.verification {
        case .hardware: how = "tested on hardware"
        case .publishedDump: how = "from published dumps, untested"
        case .unverified: how = "unverified"
        }
        return "\(key.rawValue) (\(model.name) in Upright's catalog, \(how))"
    }

    static func modelIDsText(_ ids: ModelIDs) -> String {
        let parts: [(String, UInt16?)] = [("Bluetooth", ids.bluetooth), ("Bluetooth LE", ids.bluetoothLE), ("wireless", ids.wireless), ("USB", ids.usb)]
        let present = parts.compactMap { name, pid in pid.map { "\(name) \(hex($0, 4))" } }
        return present.isEmpty ? "none reported" : present.joined(separator: ", ")
    }

    static func dpiText(_ dpi: DPIInfo?) -> String {
        guard let dpi else { return "not adjustable over HID++ (no 0x2201)" }
        let supported = dpi.step.map { "\(dpi.minimum)–\(dpi.maximum) in steps of \($0)" }
            ?? dpi.supported.map(String.init).joined(separator: ", ")
        return "\(dpi.current) DPI (default \(dpi.defaultValue); supported: \(supported.isEmpty ? "unknown" : supported))"
    }

    /// The full device report, one entry per line (the console adds the prefix).
    /// `place` is the link part of the label ("Bolt slot 2"); `isReceiver` says what the
    /// transport PID in the identity means.
    static func dump(_ s: DeviceSnapshot, verdict: ProbeVerdict, place: String, isReceiver: Bool) -> [String] {
        var out: [String] = []
        let name = displayName(s)
        switch verdict {
        case .supported:
            out.append("✓ \(name): Upright supports this device")
        case .interfaceNotOpened(let why):
            out.append("✓ \(name): passes Upright's device checks, but Upright never opens this interface (\(why))")
        case .unsupported(let reason):
            out.append("✗ \(name): not supported by Upright: \(reason.message)")
        }
        out.append("    Connection: \(place), device index 0x\(hex(s.deviceIndex, 2)), HID++ \(s.protocolVersion)")
        if (s.protocolVersion.split(separator: ".").first.flatMap { Int($0) } ?? 2) < 2 {
            // HID++ 1.0 devices have no feature table; all there is to say comes from the receiver.
            if let identity = s.identity {
                out.append("    Kind: \(identity.kind.name) (from the receiver)")
                if let pid = identity.transportPID { out.append("    Wireless PID from the receiver: \(hex(pid, 4))") }
            }
            out.append("    No feature table or control list: this is a HID++ 1.0 device.")
            return out
        }
        out.append("    Battery: \(batteryText(s.battery))")
        for firmware in s.firmware where !firmware.displayString.isEmpty {
            out.append("    \(firmware.kind.title): \(firmware.displayString)")
        }
        if let identity = s.identity {
            let deviceID = identity.deviceID(at: s.address)
            out.append("    Identity:")
            out.append("      Kind: \(identity.kind.name)")
            out.append("      Model: \(modelText(identity.model))")
            out.append("      Model IDs (0x0003): \(modelIDsText(identity.modelIDs))")
            if let extended = identity.extendedModelID {
                out.append("      Extended model ID: 0x\(hex(extended, 2))")
            }
            if let pid = identity.transportPID {
                out.append("      \(isReceiver ? "Wireless PID from the receiver" : "Product ID of the interface"): \(hex(pid, 4))")
            }
            out.append("      Unit ID: \(identity.unitID.map { hex($0, 8) } ?? "none reported")")
            out.append("      Serial number: \(identity.serialNumber ?? "none reported")")
            out.append("      Device ID: \(deviceID.rawValue)" + (deviceID.isStable ? "" : " (transient: settings for this unit can't be remembered)"))
        }
        out.append("    Pointer speed: \(dpiText(s.dpi))")
        if let hosts = s.hosts {
            out.append("    Easy-Switch: channel \(hosts.current + 1) of \(hosts.count)")
            for index in 0..<hosts.count {
                let hostName = hosts.name(at: index).map { "“\($0)”" } ?? "(no name)"
                out.append("      \(index == hosts.current ? "▸" : " ") \(index + 1): \(hostName)")
            }
        }
        out.append("    Features (\(s.features.count)):")
        for feature in s.features {
            let flags = feature.flags == 0 ? "" : "  (flags 0x\(hex(feature.flags, 2)))"
            let index = feature.index < 10 ? "0\(feature.index)" : "\(feature.index)"
            out.append("      [\(index)] 0x\(hex(feature.featureID, 4)) v\(feature.version)  \(feature.name)\(flags)")
        }
        out.append(contentsOf: controlLines(s, verdict: verdict))
        return out
    }

    private static func controlLines(_ s: DeviceSnapshot, verdict: ProbeVerdict) -> [String] {
        if s.controls.isEmpty {
            if let reprog = s.feature(.reprogControlsV4) {
                return ["    Controls: REPROG_CONTROLS_V4 v\(reprog.version) lists none"]
            }
            return ["    Controls: no REPROG_CONTROLS_V4 (0x1B04)"]
        }
        // "Remappable by Upright" only means something for a device Upright serves.
        let served = verdict == .supported
        let divertable = s.controls.filter(\.isConfigurable).count
        let count = served ? "\(divertable) remappable by Upright" : "\(divertable) divertable"
        var out = ["    Controls (REPROG_CONTROLS_V4 v\(s.reprogVersion), \(s.controls.count) controls, \(count)):"]
        for control in s.controls {
            let flags = control.flags.names + (control.supportsRawXY ? ["raw XY"] : [])
            let name = ControlCatalog.solaarName(for: control.cid) ?? "unnamed"
            out.append(
                "     \(control.isConfigurable ? "*" : " ") CID 0x\(hex(control.cid, 4))  TID 0x\(hex(control.taskID, 4))  \(pad(name, to: 24))"
                    + " [\(flags.joined(separator: ", "))]"
                    + "  (flags 0x\(hex(control.flags.rawValue, 2)), extra 0x\(hex(control.additionalFlags, 2)), position \(control.position), group \(control.group)/0x\(hex(control.groupMask, 2)))"
            )
        }
        out.append("    (* = \(served ? "remappable by Upright" : "divertable, though Upright doesn't use this device"); raw XY = can report pointer movement while held)")
        return out
    }

    /// What changed between two snapshots of a connected device (battery, speed, Easy-Switch channel).
    static func changes(from old: DeviceSnapshot, to new: DeviceSnapshot) -> [String] {
        var out: [String] = []
        if old.battery != new.battery {
            out.append("Battery: \(batteryText(old.battery)) → \(batteryText(new.battery))")
        }
        if let before = old.dpi?.current, let after = new.dpi?.current, before != after {
            out.append("Pointer speed: \(before) → \(after) DPI")
        }
        if let before = old.hosts?.current, let after = new.hosts?.current, before != after {
            out.append("Easy-Switch: channel \(before + 1) → \(after + 1)")
        }
        return out
    }
}

// MARK: - Reading a device

enum ProbeReadOutcome {
    /// Identified. `gate` is why Upright wouldn't serve it, nil when it would.
    case device(DeviceSnapshot, gate: UnsupportedReason?)
    case noAnswer(Error)
}

/// Reads a device without Upright's gate in the way, and without writing anything.
@MainActor
enum ProbeReader {
    /// Identifies the device the way Upright does (`DeviceSession.start`, which only reads and
    /// decides support), then reads whatever that stopped short of for an unsupported device:
    /// controls, battery, firmware, pointer speed and Easy-Switch.
    static func read(
        client: HIDPPClient,
        address: DeviceAddress,
        connection: ConnectionKind,
        transportPID: UInt16?,
        fallbackName: String?,
        kindHint: DeviceKind?,
        pingTimeout: TimeInterval
    ) async -> ProbeReadOutcome {
        let device = HIDPPDevice(client: client, index: address.index)
        let session = DeviceSession(device: device, connection: connection, address: address, transportPID: transportPID, fallbackName: fallbackName, kindHint: kindHint)
        do {
            return .device(try await session.start(pingTimeout: pingTimeout), gate: nil)
        } catch HIDPPError.unsupportedDevice(let reason, let partial) {
            let seed = partial ?? DeviceSnapshot(
                name: fallbackName ?? DeviceSession.defaultName, connection: connection, deviceIndex: address.index,
                protocolVersion: "?", features: [], controls: [], battery: nil, address: address
            )
            return .device(await complete(seed, client: client, index: address.index), gate: reason)
        } catch {
            return .noAnswer(error)
        }
    }

    /// Fills in what the capability gate stopped before reading. Anything the device doesn't
    /// answer stays empty.
    static func complete(_ original: DeviceSnapshot, client: HIDPPClient, index: UInt8) async -> DeviceSnapshot {
        var s = original
        let major = s.protocolVersion.split(separator: ".").first.flatMap { Int($0) } ?? 0
        guard major >= 2 else { return s }

        let device = HIDPPDevice(client: client, index: index)
        let info = DeviceFeatures(device: device)
        if s.features.isEmpty {
            s.features = (try? await device.featureTable()) ?? []
        }
        if s.controls.isEmpty, (try? await device.featureIndex(for: .reprogControlsV4)) != nil {
            s.reprogVersion = (try? await device.featureVersion(for: .reprogControlsV4)) ?? 0
            s.controls = (try? await ReprogControls(device: device).allControls()) ?? []
        }
        if s.battery == nil {
            s.battery = await device.battery()
        }
        if s.firmware.isEmpty, (try? await device.featureIndex(for: .deviceFirmwareVersion)) != nil {
            s.firmware = (try? await info.firmware()) ?? []
        }
        if s.dpi == nil, (try? await device.featureIndex(for: .adjustableDPI)) != nil {
            s.dpi = try? await info.dpi()
        }
        if s.hosts == nil, (try? await device.featureIndex(for: .changeHost)) != nil, var hosts = try? await info.hosts() {
            if (try? await device.featureIndex(for: .hostsInfo)) != nil {
                hosts.names = (try? await info.hostNames(count: hosts.count)) ?? []
            }
            s.hosts = hosts
        }
        return s
    }
}

// MARK: - Per-link logic

/// Runs the probe on the links Probe.swift opens: serves the ones Upright serves (through
/// `HIDPPLink`, exactly as the app does), reads the others without writing (`--all`), and
/// prints everything through the console.
@MainActor
final class ProbeRunner {
    let options: ProbeOptions
    let console: ProbeConsole

    /// Read timeout for a ping or a table read while scanning.
    var scanTimeout: TimeInterval = 1.0

    private var hubs: [UInt32: HIDPPLink] = [:]
    private var clients: [UInt32: HIDPPClient] = [:]
    private var scans: [UInt32: Task<Void, Never>] = [:]
    private var lastSnapshots: [DeviceAddress: DeviceSnapshot] = [:]
    private var awake: Set<DeviceAddress> = []
    /// Devices whose buttons this run diverted.
    private(set) var divertedAddresses: Set<DeviceAddress> = []

    init(options: ProbeOptions, console: ProbeConsole) {
        self.options = options
        self.console = console
    }

    var hasDivertedButtons: Bool { !divertedAddresses.isEmpty }

    /// Registers a matched interface and says what Upright does with it.
    func announce(_ info: ProbeLinkInfo) {
        console.addLink(info)
        var text = "→ \(info.summary)\n    Upright: "
        if let kind = info.transportKind {
            switch kind {
            case .receiver(let connection): text += "serves it as a \(connection.probeTitle) receiver"
            case .direct(let connection): text += "serves it as a mouse connected by \(connection.probeTitle)"
            }
        } else {
            text += "ignores it (\(info.ignoredReason ?? "not a supported device"))"
        }
        if !info.carriesHIDPP { text += "\n    This interface doesn't carry HID++, so it isn't opened." }
        console.say(text, link: info.number)
    }

    // MARK: Interfaces Upright serves

    /// Hands a link Upright serves to its hub and prints what its endpoints report.
    func attachHub(_ link: HIDPPLink, info: ProbeLinkInfo) {
        console.addLink(info)
        hubs[info.number] = link
        trace(link.client, link: info.number)
        link.onLog = { [weak self] address, text in
            guard let self else { return }
            if let address {
                self.console.say(text, at: address)
            } else {
                self.console.say(text, link: info.number)
            }
        }
        link.onEndpointChange = { [weak self] address, state in
            self?.report(state, at: address, link: link, info: info)
        }
        link.onEndpointRemoved = { [weak self] address, reason in
            self?.endpointRemoved(address, reason)
        }
        link.onButtonEvent = { [weak self] event in
            self?.buttonEvent(event)
        }
        if options.divert {
            link.configurationProvider = { [weak self] address, snapshot in
                self?.configuration(for: address, snapshot: snapshot) ?? .native
            }
        }
        link.start()
        if options.all, info.isReceiver {
            // The hub leaves keyboards and other non-pointers in a receiver's slots alone; read them.
            scans[info.number] = Task { [weak self] in
                await self?.scanReceiver(client: link.client, info: info, hub: link)
            }
        }
    }

    private func configuration(for address: DeviceAddress, snapshot: DeviceSnapshot) -> EndpointConfiguration {
        console.setName(ProbeFormat.labelName(snapshot), for: address)
        guard options.shouldDivert(label: console.label(for: address)) else { return .native }
        divertedAddresses.insert(address)
        return EndpointConfiguration(divert: Set(snapshot.configurableControls.map(\.cid)))
    }

    private func report(_ state: EndpointController.State, at address: DeviceAddress, link: HIDPPLink, info: ProbeLinkInfo) {
        switch state {
        case .probing:
            console.say("… probing", at: address)
        case .waitingForDevice:
            console.say("… not answering yet (asleep, off, or connected to another computer); click a button to wake it", at: address)
        case .asleep:
            awake.remove(address)
            console.say("… stopped answering (asleep or out of range); it is reconfigured when it wakes", at: address)
        case .failed(let message):
            console.say("✗ \(message)", at: address)
        case .connected(let snapshot):
            connected(snapshot, at: address, info: info)
        case .unsupported(let reason, let partial):
            unsupported(reason, partial: partial, at: address, link: link, info: info)
        }
    }

    private func connected(_ snapshot: DeviceSnapshot, at address: DeviceAddress, info: ProbeLinkInfo) {
        console.setName(ProbeFormat.labelName(snapshot), for: address)
        let previous = lastSnapshots[address]
        lastSnapshots[address] = snapshot
        if let previous {
            // Reconnected or refreshed: not worth the whole table again.
            if awake.insert(address).inserted { console.say("✓ answering again", at: address) }
            for change in ProbeFormat.changes(from: previous, to: snapshot) { console.say(change, at: address) }
            return
        }
        awake.insert(address)
        console.say(ProbeFormat.dump(snapshot, verdict: .supported, place: console.place(of: address), isReceiver: info.isReceiver).joined(separator: "\n"), at: address)
        if divertedAddresses.contains(address) {
            console.say("Diverting all \(snapshot.configurableControls.count) remappable buttons. Press them to see events; Ctrl-C restores them.", at: address)
        } else if options.divert {
            console.say("Not diverting this device (it doesn't match --divert=\(options.divertFilter ?? "")).", at: address)
        }
    }

    private func unsupported(_ reason: UnsupportedReason, partial: DeviceSnapshot?, at address: DeviceAddress, link: HIDPPLink, info: ProbeLinkInfo) {
        let seed = partial ?? DeviceSnapshot(
            name: DeviceSession.defaultName, connection: info.connection, deviceIndex: address.index,
            protocolVersion: "?", features: [], controls: [], battery: nil, address: address
        )
        if partial != nil { console.setName(ProbeFormat.labelName(seed), for: address) }
        console.say("✗ not supported by Upright: \(reason.message). Reading its details (reads only)...", at: address)
        // The device checks stop at the first failure; the report reads the rest (reads only).
        Task { [weak self] in
            let snapshot = await ProbeReader.complete(seed, client: link.client, index: address.index)
            guard let self, link.endpoints[address.index] != nil else { return }
            self.console.setName(ProbeFormat.labelName(snapshot), for: address)
            self.console.say(ProbeFormat.dump(snapshot, verdict: .unsupported(reason), place: self.console.place(of: address), isReceiver: info.isReceiver).joined(separator: "\n"), at: address)
        }
    }

    private func endpointRemoved(_ address: DeviceAddress, _ reason: HIDPPLink.RemovalReason) {
        let why: String
        switch reason {
        case .unpaired: why = "the device was unpaired from the receiver"
        case .retired(let newAddress): why = "the same unit now answers in slot \(newAddress.index)"
        case .replaced: why = "another device took the slot"
        case .transportClosed: why = "the HID connection closed"
        }
        console.say("← removed: \(why)", at: address)
        lastSnapshots[address] = nil
        awake.remove(address)
        divertedAddresses.remove(address)
        console.forget(address)
    }

    private func buttonEvent(_ event: ButtonEvent) {
        let model = lastSnapshots[event.source]?.identity?.model
        let name = ControlDescriptor(cid: event.cid, model: model).name
        let state = event.phase == .press ? "pressed" : "released"
        console.say("● \(name) (0x\(ProbeFormat.hex(event.cid, 4))) \(state)", at: event.source)
    }

    // MARK: Interfaces Upright doesn't serve (--all)

    /// Reads a link Upright doesn't open: its receiver slots, or the one device behind it.
    /// Nothing is written.
    func attachRaw(client: HIDPPClient, info: ProbeLinkInfo) {
        console.addLink(info)
        clients[info.number] = client
        trace(client, link: info.number)
        scans[info.number] = Task { [weak self] in
            guard let self else { return }
            if info.isReceiver {
                await self.scanReceiver(client: client, info: info, hub: nil)
            } else {
                await self.dumpDevice(client: client, info: info, index: DeviceAddress.direct, transportPID: info.productID, kindHint: nil)
            }
        }
    }

    /// Prints a receiver's pairing table and reads its devices: every occupied slot when `hub`
    /// is nil, otherwise only the non-pointers (keyboards ...) the hub leaves alone.
    private func scanReceiver(client: HIDPPClient, info: ProbeLinkInfo, hub: HIDPPLink?) async {
        let records: [UInt8: PairingRecord]?
        do {
            records = try await ReceiverDirectory.readPairings(using: client, layout: info.layout, timeout: scanTimeout)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let layoutName = info.layout == .bolt ? "Bolt" : "Unifying"
        var slots: [(slot: UInt8, record: PairingRecord?)] = []
        if let records {
            if records.isEmpty {
                console.say("Pairing table (\(layoutName) layout): nothing paired", link: info.number)
            } else {
                var text = "Pairing table (\(layoutName) layout):"
                for slot in records.keys.sorted() {
                    guard let record = records[slot] else { continue }
                    let model = DeviceCatalog.model(forPID: record.wirelessPID)?.name
                    var line = "\n  slot \(slot): wireless PID \(ProbeFormat.hex(record.wirelessPID, 4)), \(record.kind.name)"
                    if let model { line += ", \(model) in Upright's catalog" }
                    if let serial = try? await ReceiverDirectory.readSerial(using: client, slot: slot, layout: info.layout, timeout: scanTimeout) {
                        line += ", receiver-side serial \(serial)"
                    }
                    text += line
                    slots.append((slot, record))
                }
                console.say(text, link: info.number)
            }
        } else if hub == nil {
            // The hub does its own announcements and pings; a bare scan has to look for itself.
            console.say("The receiver can't list its pairings; pinging slots 1...6", link: info.number)
            for slot in ReceiverDirectory.slots {
                guard !Task.isCancelled else { return }
                do {
                    _ = try await HIDPPDevice(client: client, index: slot).protocolVersion(timeout: scanTimeout)
                    slots.append((slot, nil))
                } catch HIDPPError.transportClosed {
                    return
                } catch {
                    continue
                }
            }
        } else {
            console.say("The receiver can't list its pairings", link: info.number)
        }

        for (slot, record) in slots {
            guard !Task.isCancelled else { return }
            if let hub {
                guard record?.kind.isDefinitelyNotPointer == true, hub.endpoints[slot] == nil else { continue }
            }
            await dumpDevice(client: client, info: info, index: slot, transportPID: record?.wirelessPID, kindHint: record?.kind)
        }
    }

    /// Identifies one device and prints its full report, whatever Upright thinks of it.
    private func dumpDevice(client: HIDPPClient, info: ProbeLinkInfo, index: UInt8, transportPID: UInt16?, kindHint: DeviceKind?) async {
        let address = DeviceAddress(link: info.number, index: index)
        let outcome = await ProbeReader.read(
            client: client, address: address, connection: info.connection, transportPID: transportPID,
            fallbackName: info.isReceiver || info.productName.isEmpty ? nil : info.productName,
            kindHint: kindHint, pingTimeout: scanTimeout
        )
        guard !Task.isCancelled, console.links[info.number] != nil else { return }
        switch outcome {
        case .noAnswer(let error):
            console.say("✗ no HID++ answer (\(error)). If it is a wireless device, wake it (move or click) and run again.", at: address)
        case .device(let snapshot, let gate):
            console.setName(ProbeFormat.labelName(snapshot), for: address)
            let verdict: ProbeVerdict = gate.map { .unsupported($0) } ?? info.ignoredReason.map { .interfaceNotOpened($0) } ?? .supported
            console.say(ProbeFormat.dump(snapshot, verdict: verdict, place: console.place(of: address), isReceiver: info.isReceiver).joined(separator: "\n"), at: address)
        }
    }

    // MARK: Shared

    private func trace(_ client: HIDPPClient, link: UInt32) {
        guard options.trace else { return }
        client.onTraffic = { [weak self] direction, bytes in
            MainActorDelivery.run {
                guard let self else { return }
                let arrow = direction == .outgoing ? ">>" : "<<"
                let text = bytes.prefix(20).map { ProbeFormat.hex($0, 2) }.joined(separator: " ")
                let index = bytes.count > 1 ? bytes[1] : DeviceAddress.direct
                self.console.say("    \(arrow) \(text)", at: DeviceAddress(link: link, index: index))
            }
        }
    }

    /// Stops everything on one link. The transport is the caller's.
    func detach(link number: UInt32) {
        scans[number]?.cancel()
        scans[number] = nil
        hubs.removeValue(forKey: number)?.shutdown()
        clients.removeValue(forKey: number)?.close()
        console.removeLink(number)
    }

    /// Hands every diverted button back to its mouse and stops all links.
    func shutdown() {
        for hub in hubs.values {
            hub.onEndpointChange = nil
            hub.onEndpointRemoved = nil
        }
        for number in Set(hubs.keys).union(clients.keys).union(scans.keys) {
            detach(link: number)
        }
    }
}
