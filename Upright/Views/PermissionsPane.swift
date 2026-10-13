import SwiftUI

struct PermissionsPane: View {
    @EnvironmentObject private var permissions: PermissionsMonitor
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: String(localized: "Accessibility"),
                    symbolName: "accessibility",
                    tint: .blue,
                    explanation: String(localized: "Required to post the keyboard shortcuts, media keys and clicks your buttons are mapped to, and to change scrolling. Mission Control, opening apps and links, pointer speed and “Do Nothing” work without it."),
                    state: permissions.isAccessibilityTrusted ? .granted : .required
                ) {
                    if permissions.accessibilityGrantIsStale {
                        Button("Reset Permission") { permissions.resetAccessibilityPermission() }
                            .disabled(permissions.isResettingAccessibility)
                    } else {
                        Button("Open Settings…") { permissions.requestAccessibility() }
                    }
                }
                if permissions.accessibilityGrantIsStale && !permissions.isAccessibilityTrusted {
                    Label {
                        Text("Accessibility is off. If you already turned it on, macOS may have kept an outdated entry — Reset fixes that.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    if permissions.isResettingAccessibility {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Resetting permission"))
                    }
                }
            } footer: {
                Text("After you switch Upright on in System Settings, this page updates by itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(
                    title: String(localized: "Input Monitoring"),
                    symbolName: "keyboard.badge.eye",
                    tint: .purple,
                    explanation: String(localized: "Only needed if macOS hides the mouse from Upright, which can happen over Bluetooth. Upright then shows the MX Vertical as blocked and its buttons keep their normal behavior until you allow it."),
                    state: inputMonitoringState
                ) {
                    // Prompts while undecided, otherwise opens System Settings; never both at once.
                    // AppModel reconnects the mouse once access is granted.
                    Button(permissions.inputMonitoring == .denied ? "Open Settings…" : "Allow…") {
                        permissions.requestInputMonitoring()
                    }
                }
            }

            Section {
                Label("Upright never reads what you type. It only listens to the HID++ channel of Logitech receivers and MX Vertical mice, and only posts the actions you assign.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
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
