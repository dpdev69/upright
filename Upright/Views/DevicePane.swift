import AppKit
import SwiftUI

/// The Mice pane: every mouse Upright knows (connected, seen before, and other Logitech devices
/// it found but can't configure), then the selected one in detail: identity, nickname, the
/// "Remap this mouse" switch, battery, pointer speed and Easy-Switch, what it reported over
/// HID++, and the activity log (labelled per device, with a device filter).
struct DevicePane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var settings: AppSettings

    /// A remembered mouse or an unsupported device. AppModel's `selectedDevice` only tracks served
    /// mice (it also picks the Buttons pane's model), so these are kept here.
    @State private var pinnedSelection: DeviceListSelection?
    @State private var pendingForget: RememberedDevice?

    var body: some View {
        let remembered = RememberedDevice.list(store: settings.devicePreferences, live: devices.records)
        let current = resolvedSelection(remembered: remembered)

        Form {
            if devices.needsInputMonitoring {
                Section {
                    InputMonitoringCallout()
                }
            }

            DeviceListView(records: devices.records, remembered: remembered, selection: selectionBinding(remembered: remembered))

            switch current {
            case .live(let address):
                if let record = devices.records.first(where: { $0.address == address }) {
                    LiveDeviceDetail(record: record, standbyOf: standbyTarget(of: record))
                }
            case .remembered(let id):
                if let device = remembered.first(where: { $0.id == id }) {
                    RememberedDeviceDetail(device: device) { pendingForget = device }
                }
            case nil:
                Section {
                    DeviceHeader(record: nil)
                    ConnectionHint()
                }
                PointerSpeedSection(address: nil, dpi: nil)
            }

            DeviceActivitySection()
        }
        .formStyle(.grouped)
        .onAppear { devices.refreshDeviceInfo() }
        .confirmationDialog(
            Text("Forget \(pendingForget?.displayName ?? "")?"),
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
            titleVisibility: .visible,
            presenting: pendingForget
        ) { device in
            Button("Forget", role: .destructive) {
                model.forget(device.id)
                if pinnedSelection == .remembered(device.id) { pinnedSelection = nil }
            }
        } message: { _ in
            Text("Upright forgets this mouse’s nickname, pointer speed and remapping switch. The button setup for its model stays.")
        }
    }

    // MARK: Selection

    /// The pinned selection while it still exists (a remembered mouse that came back shows as
    /// the live one), else the served mouse AppModel has selected.
    private func resolvedSelection(remembered: [RememberedDevice]) -> DeviceListSelection? {
        switch pinnedSelection {
        case .remembered(let id):
            if let live = devices.records.first(where: { $0.deviceID == id && $0.role == .active }) {
                return .live(live.address)
            }
            if remembered.contains(where: { $0.id == id }) { return pinnedSelection }
        case .live(let address):
            if devices.records.contains(where: { $0.address == address }) { return pinnedSelection }
        case nil:
            break
        }
        guard let address = model.selectedDevice, devices.records.contains(where: { $0.address == address }) else {
            return nil
        }
        return .live(address)
    }

    private func selectionBinding(remembered: [RememberedDevice]) -> Binding<DeviceListSelection?> {
        Binding(
            get: { resolvedSelection(remembered: remembered) },
            set: { value in
                if case .live(let address) = value,
                   let record = devices.records.first(where: { $0.address == address }),
                   record.role != .unsupported {
                    pinnedSelection = nil
                    model.selectedDevice = address
                } else {
                    pinnedSelection = value
                }
            }
        )
    }

    /// The active endpoint a standby link stands in for.
    private func standbyTarget(of record: DeviceRegistry.Record) -> DeviceRegistry.Record? {
        guard case .standby(let active) = record.role else { return nil }
        return devices.records.first { $0.address == active }
    }
}

// MARK: - Live device

private struct LiveDeviceDetail: View {
    let record: DeviceRegistry.Record
    /// For a standby link: the endpoint of the same mouse that Upright uses.
    let standbyOf: DeviceRegistry.Record?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @State private var copiedReport = false

    var body: some View {
        let isServed = record.role != .unsupported

        Section {
            DeviceHeaderContent(
                title: record.displayName,
                subtitle: record.stateDetail,
                indicator: record.indicator,
                isFilled: record.snapshot != nil,
                battery: record.isConnected ? record.snapshot?.battery : nil,
                badge: isServed && record.isUntestedModel ? String(localized: "Untested model") : nil
            )

            if let standbyOf {
                Label {
                    Text("This is a second connection to \(standbyOf.displayName). Upright uses its \(standbyOf.connection.compactTitle) connection and leaves this one as it is.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "link")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if isServed, let id = record.deviceID {
                if id.isStable {
                    NicknameField(id: id, placeholder: baseName)
                        .id(id)
                    RemapThisMouseToggle(id: id)
                } else {
                    Label("Settings for this mouse can’t be remembered: it doesn’t report a serial number.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let snapshot = record.anySnapshot {
                DeviceInfoRows(record: record, snapshot: snapshot)
            } else {
                LabeledContent("Connection") {
                    Label(record.placeText, systemImage: record.connection.symbolName)
                }
            }

            HStack {
                if copiedReport {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("Copy Device Report") { copyReport() }
                    .help("Copies what this device reported (features, buttons, connection) for a bug report or a new-model request")
                if isServed {
                    Button("Reconnect") { devices.reconnect(record.address) }
                        .help("Identifies this mouse again and reapplies its button configuration")
                }
            }
        } footer: {
            if isServed && record.isUntestedModel {
                Text("Upright was built and tested on the MX Vertical. This model should work, but it hasn’t been tested on real hardware yet. If something is off, copy the device report into an issue on GitHub.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if case .failed(let message) = record.state, message != "Disconnected" {
            Section {
                ProblemDetails(summary: String(localized: "The mouse isn’t answering"), details: message)
            }
        }

        if isServed, !record.isStandby, let snapshot = record.snapshot {
            if let dpi = snapshot.dpi {
                PointerSpeedSection(address: record.address, dpi: dpi)
            }
            if let hosts = snapshot.hosts, hosts.count > 1 {
                EasySwitchSection(hosts: hosts, address: record.address, deviceName: record.displayName)
            }
        }

        if let snapshot = record.anySnapshot {
            if !snapshot.controls.isEmpty {
                Section("Controls") {
                    ForEach(snapshot.controls) { control in
                        ControlInfoRow(control: control, model: record.model)
                    }
                }
            }
            if !snapshot.features.isEmpty {
                Section("HID++ features") {
                    ForEach(snapshot.features) { feature in
                        LabeledContent {
                            Text(String(format: "0x%04X  v%d", feature.featureID, feature.version))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: "\(feature.index).  \(feature.name)")
                        }
                    }
                }
            }
        }
    }

    /// The name without a nickname, for the nickname field's placeholder.
    private var baseName: String {
        if let model = record.model, let name = DeviceCatalog.model(model)?.name { return name }
        return record.anySnapshot?.name ?? record.displayName
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceReport.text(for: record), forType: .string)
        withAnimation { copiedReport = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedReport = false }
        }
    }
}

private struct DeviceInfoRows: View {
    let record: DeviceRegistry.Record
    let snapshot: DeviceSnapshot

    var body: some View {
        if snapshot.name != record.displayName {
            LabeledContent("Name", value: snapshot.name)
        }
        LabeledContent("Connection") {
            Label(record.placeText, systemImage: record.connection.symbolName)
        }
        if let battery = snapshot.battery {
            LabeledContent("Battery") {
                Label(Self.batteryText(battery), systemImage: battery.symbolName)
            }
        }
        if let firmware = snapshot.firmwareVersion {
            LabeledContent("Firmware") {
                Text(firmware)
                    .textSelection(.enabled)
                    .help(snapshot.firmware.map { "\($0.kind.title): \($0.displayString)" }.joined(separator: "\n"))
            }
        }
        if let serial = snapshot.serialNumber {
            LabeledContent("Serial number") {
                Text(serial)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        LabeledContent("HID++ version", value: snapshot.protocolVersion)
        LabeledContent("Device index", value: String(format: "0x%02X", snapshot.deviceIndex))
    }

    /// "~50%" for coarse levels; "Charging" or "Full" while on power.
    static func batteryText(_ battery: BatteryStatus) -> String {
        let level = battery.levelText
        guard battery.isCharging else { return level }
        if battery.percentage >= 100 { return String(localized: "Full") }
        return String(localized: "\(level), charging")
    }
}

/// The mouse's nickname, saved when editing ends (Return or leaving the field).
private struct NicknameField: View {
    let id: DeviceID
    let placeholder: String

    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Nickname", text: $draft, prompt: Text(verbatim: placeholder))
            .focused($isFocused)
            .onAppear { draft = model.devicePreferences(for: id).nickname ?? "" }
            .onSubmit(commit)
            .onChange(of: isFocused) { focused in
                if !focused { commit() }
            }
            .onDisappear(perform: commit)
            .help("Shown in the menu bar and in this list instead of the model name")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = trimmed.isEmpty ? nil : trimmed
        let binding = model.preferences(id)
        guard binding.wrappedValue.trimmedNickname != nickname else { return }
        var prefs = binding.wrappedValue
        prefs.nickname = nickname
        binding.wrappedValue = prefs
    }
}

private struct RemapThisMouseToggle: View {
    let id: DeviceID

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let binding = model.preferences(id)
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Remap this mouse", isOn: Binding(
                get: { binding.wrappedValue.remapEnabled },
                set: { enabled in
                    var prefs = binding.wrappedValue
                    prefs.remapEnabled = enabled
                    binding.wrappedValue = prefs
                }
            ))
            Text(caption(isOn: binding.wrappedValue.remapEnabled))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(isOn: Bool) -> String {
        if !model.isRemappingEnabled {
            return String(localized: "Remapping is paused for every mouse (menu bar switch).")
        }
        return isOn
            ? String(localized: "Its buttons follow the setup in Buttons.")
            : String(localized: "Every button on this mouse does what it normally does.")
    }
}

/// Easy-Switch channels of one mouse, with buttons to move it to another computer.
private struct EasySwitchSection: View {
    let hosts: HostInfo
    let address: DeviceAddress
    let deviceName: String

    @EnvironmentObject private var devices: DeviceManager
    @State private var pendingSwitch: Int?

    var body: some View {
        Section {
            ForEach(0..<hosts.count, id: \.self) { index in
                LabeledContent {
                    if index == hosts.current {
                        Label("This Mac", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Switch…") { pendingSwitch = index }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Computer \(index + 1)")
                        if let name = hosts.name(at: index) {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Easy-Switch")
        } footer: {
            Text("Switching moves the mouse to another paired computer, and it disconnects from this Mac right away. Press the Easy-Switch button under the mouse to come back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            Text("Switch \(deviceName) to Computer \((pendingSwitch ?? 0) + 1)?"),
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible,
            presenting: pendingSwitch
        ) { index in
            Button("Switch") { devices.switchToHost(index, on: address) }
        } message: { _ in
            Text("The mouse will disconnect from this Mac. Press the Easy-Switch button under the mouse to come back.")
        }
    }
}

// MARK: - Remembered device

private struct RememberedDeviceDetail: View {
    let device: RememberedDevice
    let onForget: () -> Void

    var body: some View {
        Section {
            DeviceHeaderContent(
                title: device.displayName,
                subtitle: device.lastSeenText,
                indicator: .idle,
                isFilled: false,
                badge: isUntested ? String(localized: "Untested model") : nil
            )
            NicknameField(id: device.id, placeholder: baseName)
                .id(device.id)
            RemapThisMouseToggle(id: device.id)
            if let connection = device.connection {
                LabeledContent("Last connection") {
                    Label(connection.title, systemImage: connection.symbolName)
                }
            }
            if let dpi = device.preferences.preferredDPI {
                LabeledContent("Pointer speed") {
                    Text("\(dpi) DPI")
                        .monospacedDigit()
                }
            }
            HStack {
                Spacer()
                Button("Forget This Mouse…", role: .destructive, action: onForget)
            }
        } footer: {
            Text("Connect the mouse to change its pointer speed or Easy-Switch channel.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var isUntested: Bool {
        guard let model = device.model else { return false }
        return DeviceCatalog.model(model)?.verification != .hardware
    }

    private var baseName: String {
        device.model.flatMap { DeviceCatalog.model($0)?.name }
            ?? device.preferences.lastName
            ?? device.displayName
    }
}

// MARK: - Shared rows

/// A short problem statement with the full technical message behind a disclosure.
private struct ProblemDetails: View {
    let summary: String
    let details: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            DisclosureGroup("Details") {
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ControlInfoRow: View {
    let control: ControlInfo
    let model: ModelKey?

    var body: some View {
        let descriptor = ControlDescriptor(cid: control.cid, model: model)
        LabeledContent {
            Text((control.flags.names + (control.supportsRawXY ? ["raw XY"] : [])).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            HStack(spacing: 8) {
                Text(descriptor.hexID)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(descriptor.name)
                if control.isConfigurable {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .help("Remappable in Upright")
                        .accessibilityLabel(Text("Remappable"))
                }
            }
        }
    }
}

// MARK: - Activity

/// The activity log of every device, each line labelled with its device, with a device filter.
private struct DeviceActivitySection: View {
    @EnvironmentObject private var devices: DeviceManager
    /// nil shows every line.
    @State private var filter: DeviceAddress?

    var body: some View {
        let entries = filtered
        Section {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All devices").tag(DeviceAddress?.none)
                    if !devices.records.isEmpty {
                        Divider()
                    }
                    ForEach(devices.records) { record in
                        Text(verbatim: "\(record.displayName) · \(record.connection.compactTitle)")
                            .tag(Optional(record.address))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                Toggle("Raw HID++ reports", isOn: $devices.logsTraffic)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            ActivityLog(entries: entries)
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.text(of: entries), forType: .string)
                }
                .controlSize(.small)
                .help("Copies the lines shown")
                Button("Clear") { devices.clearLog() }
                    .controlSize(.small)
            }
        }
        .onChange(of: devices.records.map(\.address)) { addresses in
            if let filter, !addresses.contains(filter) { self.filter = nil }
        }
    }

    /// Lines about the chosen device, plus lines about the interface it is on (its receiver).
    private var filtered: [DeviceManager.LogEntry] {
        guard let filter else { return devices.log }
        return devices.log.filter { entry in
            if let address = entry.address { return address == filter }
            return entry.link == filter.link
        }
    }

    private static func text(of entries: [DeviceManager.LogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(formatter.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }
}

private struct ActivityLog: View {
    let entries: [DeviceManager.LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text("Nothing yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 160, idealHeight: 200, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: entries.last?.id) { id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .accessibilityLabel(Text("Activity log"))
        }
    }
}

/// One log line. Long messages show their first line, with the rest behind "More".
private struct LogEntryRow: View {
    let entry: DeviceManager.LogEntry

    @State private var expanded = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let shortLength = 140

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .foregroundStyle(.tertiary)
            Text(expanded || !isLong ? entry.text : summary)
                .foregroundStyle(entry.isTraffic ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private var isLong: Bool {
        entry.text.count > Self.shortLength || entry.text.contains("\n")
    }

    private var summary: String {
        let firstLine = entry.text.prefix { $0 != "\n" }
        let short = firstLine.prefix(Self.shortLength)
        return short.count < entry.text.count ? short + "…" : String(short)
    }
}

// MARK: - Device report

/// Plain text describing one device for a GitHub issue: identity, connection, features and
/// controls (CID, task ID, flags, raw XY). The unit ID and serial number are left out; the
/// report only says whether the device reports them.
enum DeviceReport {
    static func text(for record: DeviceRegistry.Record) -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("Upright device report")
        lines.append("Upright \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        let snapshot = record.anySnapshot
        let catalog = record.model.flatMap(DeviceCatalog.model)
        lines.append("Device: \(snapshot?.name ?? record.displayName)")
        if let model = record.model {
            let verification: String
            switch catalog?.verification {
            case .hardware: verification = "tested on hardware"
            case .publishedDump: verification = "catalog: published data, untested"
            case .unverified: verification = "catalog: unverified"
            case nil: verification = "not in catalog"
            }
            lines.append("Model: \(catalog?.name ?? "?") (\(model.rawValue), \(verification))")
        }
        lines.append("Connection: \(record.connection.rawValue), index \(record.address.isDirect ? "0xFF (direct)" : "\(record.address.index)")")
        lines.append("State: \(stateDescription(record))")

        if let identity = snapshot?.identity {
            lines.append("Kind: \(identity.kind.name)")
            let ids = identity.modelIDs
            lines.append("Model IDs: bt \(hex(ids.bluetooth)), btle \(hex(ids.bluetoothLE)), wpid \(hex(ids.wireless)), usb \(hex(ids.usb)); extended \(identity.extendedModelID.map { String(format: "0x%02X", $0) } ?? "-")")
            lines.append("Transport PID: \(hex(identity.transportPID))")
            lines.append("Unit ID: \(identity.unitID == nil ? "not reported" : "reported (not included)")")
            lines.append("Serial number: \(identity.serialNumber == nil ? "not reported" : "reported (not included)")")
        }

        guard let snapshot else {
            lines.append("")
            lines.append("No HID++ data yet.")
            return lines.joined(separator: "\n")
        }
        lines.append("HID++: \(snapshot.protocolVersion); REPROG_CONTROLS_V4 version \(snapshot.reprogVersion)")
        for firmware in snapshot.firmware where !firmware.displayString.isEmpty {
            lines.append("\(firmware.kind.title): \(firmware.displayString)")
        }
        if let dpi = snapshot.dpi {
            let step = dpi.step.map { ", step \($0)" } ?? ""
            lines.append("Pointer speed: \(dpi.current) DPI (default \(dpi.defaultValue); \(dpi.minimum)–\(dpi.maximum)\(step); \(dpi.supported.count) values)")
        } else {
            lines.append("Pointer speed: no ADJUSTABLE_DPI (0x2201)")
        }
        if let hosts = snapshot.hosts {
            lines.append("Easy-Switch: \(hosts.count) channels, current \(hosts.current + 1)")
        }
        if let battery = snapshot.battery {
            lines.append("Battery: \(battery.percentage)%\(battery.isApproximate ? " (approximate)" : "")\(battery.isCharging ? ", charging" : "")")
        }

        lines.append("")
        lines.append("Features (index, ID, version, name):")
        for feature in snapshot.features {
            lines.append(String(format: "  %2d  0x%04X  v%d  ", Int(feature.index), Int(feature.featureID), Int(feature.version)) + feature.name)
        }

        lines.append("")
        lines.append("Controls (CID, task ID, flags, raw XY, position, group, group mask):")
        for control in snapshot.controls {
            let name = ControlDescriptor(cid: control.cid, model: record.model).name
            let flags = control.flags.names.joined(separator: " ")
            lines.append(String(
                format: "  0x%04X  tid 0x%04X  [%@]  rawXY %@  pos %d  group %d  gmask 0x%02X  ",
                Int(control.cid), Int(control.taskID), flags, control.supportsRawXY ? "yes" : "no",
                Int(control.position), Int(control.group), Int(control.groupMask)
            ) + name)
        }
        return lines.joined(separator: "\n")
    }

    private static func hex(_ value: UInt16?) -> String {
        value.map { String(format: "0x%04X", $0) } ?? "-"
    }

    private static func stateDescription(_ record: DeviceRegistry.Record) -> String {
        switch record.state {
        case .connected: return record.isStandby ? "connected (standby: same unit on a better link)" : "connected"
        case .asleep: return "asleep"
        case .probing: return "probing"
        case .waitingForDevice: return "waiting for device"
        case .failed(let message): return "failed: \(message)"
        case .unsupported(let reason, _): return "unsupported: \(reason)"
        }
    }
}
