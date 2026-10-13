import SwiftUI

struct PermissionsPane: View {
    @EnvironmentObject private var permissions: PermissionsMonitor
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    symbolName: "accessibility",
                    tint: .blue,
                    explanation: "Required to send keyboard shortcuts, media keys and clicks when you press a mapped button. Mission Control actions and “Do Nothing” work without it.",
                    state: permissions.isAccessibilityTrusted ? .granted : .required
                ) {
                    Button("Open Settings…") { permissions.requestAccessibility() }
                }
            } footer: {
                Text("After you switch Upright on in System Settings, this page updates by itself. If you rebuild Upright from source, macOS may ask again because the app’s signature changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(
                    title: "Input Monitoring",
                    symbolName: "keyboard.badge.eye",
                    tint: .purple,
                    explanation: "Required to see the MX Vertical over Bluetooth and apply button remaps. Without it the mouse stays “Not connected” and the top button keeps changing pointer speed.",
                    state: inputMonitoringState
                ) {
                    Button(permissions.inputMonitoring == .notDetermined ? "Request…" : "Open Settings…") {
                        permissions.requestInputMonitoring()
                    }
                }
            }

            Section {
                Label("Upright never reads what you type. It only listens to the HID++ channel of Logitech receivers and MX Vertical mice, and only posts the actions you assign.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
    }

    private var inputMonitoringState: PermissionState {
        if permissions.inputMonitoring == .granted { return .granted }
        if devices.status == .accessDenied { return .required }
        return .optional
    }
}

enum PermissionState {
    case granted
    case required
    case optional
}

struct PermissionRow<Actions: View>: View {
    let title: String
    let symbolName: String
    let tint: Color
    let explanation: String
    let state: PermissionState
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemName: symbolName, color: tint, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    badge
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if state != .granted {
                actions()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption.weight(.medium))
        case .required:
            Label("Needed", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption.weight(.medium))
        case .optional:
            Text("Not needed right now")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
