import AppKit
import SwiftUI

/// Diagnostics: what the mouse reported over HID++, plus a live activity log.
struct DevicePane: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        Form {
            Section {
                DeviceHeader()
                if let snapshot = devices.snapshot {
                    LabeledContent("Connection") {
                        Label(snapshot.connection.title, systemImage: snapshot.connection.symbolName)
                    }
                    LabeledContent("HID++ version", value: snapshot.protocolVersion)
                    LabeledContent("Device index", value: String(format: "0x%02X", snapshot.deviceIndex))
                }
                HStack {
                    Spacer()
                    Button("Reconnect") { devices.reconnect() }
                }
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
                            Text("\(feature.index).  \(feature.name)")
                        }
                    }
                }
            } else {
                Section {
                    EmptyStateView(
                        title: "No MX Vertical connected",
                        message: "Plug in the Unifying or Bolt receiver, connect the USB cable, or pair over Bluetooth. Then click a mouse button to wake it.",
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
                }
            }
        }
    }
}

private struct ActivityLog: View {
    @EnvironmentObject private var devices: DeviceManager

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if devices.log.isEmpty {
                        Text("Nothing yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.date))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .foregroundStyle(entry.isTraffic ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: devices.log.last?.id) { id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
