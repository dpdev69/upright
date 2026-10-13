import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if devices.status == .accessDenied {
                InputMonitoringCallout(compact: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.12)))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else if model.isMissingAccessibility {
                AccessibilityCallout(compact: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.12)))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 10)

            VStack(spacing: 1) {
                ForEach(devices.controls) { control in
                    MappingSummaryRow(control: control, action: model.mappings[control.cid], dimmed: !model.isRemappingEnabled) {
                        SettingsWindowController.shared.show(pane: .buttons)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 10)

            VStack(spacing: 1) {
                MenuItemButton(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)

                MenuItemButton(title: "Reconnect Mouse", systemImage: "arrow.clockwise") {
                    devices.reconnect()
                }

                MenuItemButton(title: "Quit Upright", systemImage: "power", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: devices.snapshot == nil ? "computermouse" : "computermouse.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                Text(devices.status.title)
                    .font(.headline)
                HStack(spacing: 5) {
                    StatusDot(indicator: devices.status.indicator)
                    Text(devices.status.subtitle)
                        .lineLimit(2)
                    if let battery = devices.snapshot?.battery {
                        Text("·")
                        BatteryLabel(battery: battery)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("Remap buttons", isOn: $model.isRemappingEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(model.isRemappingEnabled ? "Remapping is on" : "Remapping is off")
        }
    }
}

private struct MappingSummaryRow: View {
    let control: ControlDescriptor
    let action: ButtonAction
    let dimmed: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: control.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(control.name)
                Spacer(minLength: 8)
                Text(action == .deviceDefault ? "Default" : action.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(control.name): \(action.title)")
    }
}

private struct MenuItemButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
