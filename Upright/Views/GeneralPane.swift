import AppKit
import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var loginItem: LoginItemController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.isEnabled || loginItem.requiresApproval }, set: { loginItem.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("Keep your buttons remapped from the moment you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if loginItem.requiresApproval {
                    HStack {
                        Label("Approve Upright in Login Items to finish turning this on.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.errorMessage {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle(isOn: $model.isRemappingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remap buttons")
                        Text("When off, every button goes back to what the mouse does on its own.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Remapping")
            }

            Section {
                LabeledContent("Sleep and wake") {
                    Text("Reapplied automatically")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("When Upright quits") {
                    Text("Buttons return to their defaults")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Upright only uses temporary button diversion, so nothing is written to the mouse’s memory. Turning the mouse off and on always restores its factory behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit Upright") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}
