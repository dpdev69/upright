import AppKit
import SwiftUI

/// The connected mouse: identity, battery, pointer speed and Easy-Switch, then what it reported
/// over HID++ and a live activity log.
struct DevicePane: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        Form {
            Section {
                DeviceHeader()
                if let snapshot = devices.snapshot {
                    DeviceInfoRows(snapshot: snapshot)
                }
                HStack {
                    Spacer()
                    Button("Reconnect") { devices.reconnect() }
                }
            }

            if case .failed(let message) = devices.status {
                Section {
                    ProblemDetails(summary: String(localized: "The mouse isn’t answering"), details: message)
                }
            }

            PointerSpeedSection(dpi: devices.snapshot?.dpi)

            if let snapshot = devices.snapshot, let hosts = snapshot.hosts, hosts.count > 1 {
                EasySwitchSection(hosts: hosts)
            }

            if let snapshot = devices.snapshot {
                Section("Controls") {
                    ForEach(snapshot.controls) { control in
                        ControlInfoRow(control: control)
                    }
                }

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
            } else {
                Section {
                    EmptyStateView(
                        title: String(localized: "No MX Vertical connected"),
                        message: String(localized: "Plug in the Unifying receiver, connect the USB cable, or pair over Bluetooth. Then click a mouse button to wake it."),
                        systemImage: "computermouse"
                    )
                }
            }

            Section {
                ActivityLog()
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    Toggle("Raw HID++ reports", isOn: $devices.logsTraffic)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(devices.logText, forType: .string)
                    }
                    .controlSize(.small)
                    Button("Clear") { devices.clearLog() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices.refreshDeviceInfo() }
    }
}

private struct DeviceInfoRows: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        LabeledContent("Name", value: snapshot.name)
        LabeledContent("Connection") {
            Label(snapshot.connection.title, systemImage: snapshot.connection.symbolName)
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
        let level = battery.isApproximate
            ? "~\(battery.percentage)%"
            : "\(battery.percentage)%"
        guard battery.isCharging else { return level }
        if battery.percentage >= 100 { return String(localized: "Full") }
        return String(localized: "\(level), charging")
    }
}

/// Easy-Switch channels, with buttons to move the mouse to another computer.
private struct EasySwitchSection: View {
    let hosts: HostInfo

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
            Text("Switch the mouse to Computer \((pendingSwitch ?? 0) + 1)?"),
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible,
            presenting: pendingSwitch
        ) { index in
            Button("Switch") { devices.switchToHost(index) }
        } message: { _ in
            Text("The mouse will disconnect from this Mac. Press the Easy-Switch button under the mouse to come back.")
        }
    }
}

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

    var body: some View {
        let descriptor = ControlDescriptor(cid: control.cid)
        LabeledContent {
            Text(control.flags.names.joined(separator: " · "))
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

private struct ActivityLog: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if devices.log.isEmpty {
                        Text("Nothing yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices.log) { entry in
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
            .onChange(of: devices.log.last?.id) { id in
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

    private static let shortLength = 110

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
