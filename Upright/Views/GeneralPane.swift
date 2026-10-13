import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var loginItem: LoginItemController

    @State private var confirmingReset = false
    @State private var importResult: ImportResult?

    private struct ImportResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Set after a successful import, so the alert can offer to undo it.
        var undo: AppModel.ImportSummary?
    }

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
                if !loginItem.isRunningFromApplicationsFolder {
                    Label("Upright isn’t in your Applications folder. Move it there first: if this copy is moved or deleted, it won’t open at login.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loginItem.requiresApproval {
                    HStack {
                        Label("Approve Upright in Login Items to finish turning this on.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.errorMessage {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
                Toggle(isOn: settingsBinding(\.batteryAlertsEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Low battery alerts")
                        Text("Notifies you when the mouse drops to 15% and again at 5%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Show battery level in the menu bar", isOn: settingsBinding(\.showBatteryInMenuBar))
            } header: {
                Text("Battery")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mappings and app profiles")
                        Text("Save them to a file to back them up or move them to another Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Import…", action: importConfiguration)
                    Button("Export…", action: exportConfiguration)
                }
                HStack {
                    Text("Remove every button action and app profile.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All…", role: .destructive) { confirmingReset = true }
                }
            } header: {
                Text("Configuration")
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
                    .fixedSize(horizontal: false, vertical: true)
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
        .confirmationDialog("Reset all mappings?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every button goes back to what the mouse does on its own, and all app profiles are removed. Export first if you might want them back.")
        }
        .alert(
            importResult?.title ?? "",
            isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } }),
            presenting: importResult
        ) { result in
            if let summary = result.undo {
                Button("Undo Import") { model.undoImport(summary) }
            }
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result.message)
        }
    }

    private func settingsBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }

    // MARK: Export / import

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "Upright Mappings.json")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = model.exportData()
        do {
            guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            importResult = ImportResult(
                title: String(localized: "Export failed"),
                message: error.localizedDescription
            )
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Importing replaces your current mappings and app profiles.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let summary = try model.importData(data)
            importResult = ImportResult(
                title: summary.skipped.isEmpty
                    ? String(localized: "Mappings imported")
                    : String(localized: "Mappings imported with \(summary.skipped.count) skipped"),
                message: importMessage(summary),
                undo: summary
            )
        } catch let error as MappingStore.ImportError {
            importResult = ImportResult(title: String(localized: "Import failed"), message: error.description)
        } catch {
            importResult = ImportResult(title: String(localized: "Import failed"), message: error.localizedDescription)
        }
    }

    private func importMessage(_ summary: AppModel.ImportSummary) -> String {
        var parts = [String(localized: "Your mappings and app profiles now match the file. Your previous setup was saved; choose Undo Import to put it back.")]
        if !summary.actionsToReview.isEmpty {
            let imported = model.profiles
            let lines = summary.actionsToReview.map { "• " + reviewLine($0, in: imported) }
            parts.append(String(localized: "Check that you trust these actions, which open apps, links or shortcuts:") + "\n" + bulletList(lines))
        }
        if !summary.skipped.isEmpty {
            parts.append(String(localized: "These entries couldn’t be used and were left out:") + "\n" + bulletList(summary.skipped.map { "• " + $0 }))
        }
        return parts.joined(separator: "\n\n")
    }

    private func bulletList(_ lines: [String]) -> String {
        let limit = 12
        let more = lines.count > limit ? "\n" + String(localized: "…and \(lines.count - limit) more.") : ""
        return lines.prefix(limit).joined(separator: "\n") + more
    }

    /// "Safari · Back Button – Move Up: Opens https://example.com"
    private func reviewLine(_ item: MappingStore.ReviewItem, in profiles: MappingProfiles) -> String {
        let scope = item.bundleID.map { profiles[app: $0]?.displayName ?? $0 } ?? String(localized: "All apps")
        var control = ControlDescriptor(cid: item.cid).name
        switch item.slot {
        case .button: break
        case .gestureTap: control += " – " + String(localized: "Click", comment: "Gesture slot: clicking the gesture button")
        case .gesture(let direction): control += " – " + direction.title
        }
        return "\(scope) · \(control): \(item.action.helpText)"
    }
}
