import SwiftUI

struct ButtonsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        Form {
            Section {
                DeviceHeader()
            }

            if devices.status == .accessDenied {
                Section {
                    InputMonitoringCallout()
                }
            }

            if model.isMissingAccessibility {
                Section {
                    AccessibilityCallout()
                }
            }

            Section {
                ForEach(devices.controls) { control in
                    ButtonRow(
                        control: control,
                        action: model.binding(for: control.cid),
                        showsAccessibilityWarning: !permissions.isAccessibilityTrusted
                    )
                    .disabled(!model.isRemappingEnabled)
                }
            } header: {
                Text("Buttons")
            } footer: {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remap buttons", isOn: $model.isRemappingEnabled)
                HStack {
                    Text("Start from the suggested setup: Back, Forward and Mission Control.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        model.restoreDefaultMappings()
                    }
                    .disabled(model.mappings == .defaults)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: String {
        if devices.snapshot != nil {
            return "These are the buttons your mouse reports as remappable. “Default” leaves a button to the mouse, so the top button keeps cycling pointer speed."
        }
        return "Connect your MX Vertical to see every button it reports. Changes are saved and applied as soon as it connects."
    }
}
