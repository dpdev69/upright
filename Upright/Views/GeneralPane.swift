import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var loginItem: LoginItemController

    @State private var confirmingReset = false
    @State private var importResult: ImportResult?
    /// A file read and validated, waiting for the user to review it.
    @State private var pendingImport: PendingImport?

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
                        Text("When off, every button of every mouse goes back to what the mouse does on its own.")
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
                        Text("Notifies you when a mouse drops to 15% and again at 5%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: settingsBinding(\.showBatteryInMenuBar)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show battery level in the menu bar")
                        Text("With several mice, the menu bar shows the lowest battery.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Battery")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mappings and app profiles")
                        Text("Save the setup of every mouse model to a file to back it up or move it to another Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Import…", action: importConfiguration)
                    Button("Export…", action: exportConfiguration)
                }
                HStack {
                    Text("Remove every button action and app profile, for every mouse model.")
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
                .snapshotAnchor("behavior.sleep")
                LabeledContent("When Upright quits") {
                    Text("Buttons return to their defaults")
                        .foregroundStyle(.secondary)
                }
                .snapshotAnchor("behavior.quit")
            } header: {
                Text("Behavior")
            } footer: {
                Text("Upright only uses temporary button diversion, so nothing is written to the mouse’s memory. Turning the mouse off and on always restores its factory behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .snapshotAnchor("behavior.note")
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
            Text("Every button of every mouse model goes back to what the mouse does on its own, and all app profiles are removed. Export first if you might want them back.")
        }
        .sheet(item: $pendingImport) { pending in
            ImportReviewSheet(pending: pending, onImport: finishImport)
                .environmentObject(model)
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

    /// Reads and validates the file, then shows it for review; nothing changes until the user
    /// confirms in the sheet.
    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Importing replaces the setup of each mouse model in the file. You can review it first.")
        panel.prompt = String(localized: "Review")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let target = model.selectedModel
            let preview = try model.previewImport(data, targetModel: target)
            pendingImport = PendingImport(fileName: url.lastPathComponent, data: data, preview: preview, target: target)
        } catch let error as MappingStore.ImportError {
            importResult = ImportResult(title: String(localized: "Import failed"), message: error.description)
        } catch {
            importResult = ImportResult(title: String(localized: "Import failed"), message: error.localizedDescription)
        }
    }

    private func finishImport(_ preview: MappingStore.ImportPreview) {
        pendingImport = nil
        let summary = model.applyImport(preview)
        let names = ListFormatter.localizedString(byJoining: summary.importedModels.map(model.modelName))
        var message = String(localized: "These models now use the setup from the file: \(names). Other models kept theirs. Your previous setup was saved; choose Undo Import to put it back.")
        if !summary.skipped.isEmpty {
            message += "\n\n" + String(localized: "\(summary.skipped.count) entries couldn’t be used and were left out.")
        }
        let result = ImportResult(
            title: summary.skipped.isEmpty
                ? String(localized: "Mappings imported")
                : String(localized: "Mappings imported with \(summary.skipped.count) skipped"),
            message: message,
            undo: summary
        )
        // Let the review sheet finish closing before the alert is presented.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            importResult = result
        }
    }
}

// MARK: Import review

/// A file read and validated, with the model a 2.x or 1.x file goes to.
struct PendingImport: Identifiable {
    let id = UUID()
    let fileName: String
    let data: Data
    var preview: MappingStore.ImportPreview
    var target: ModelKey
}

/// Shows what an import would change, model by model, before anything is replaced. A 2.x or
/// 1.x file (made for `ModelKey.mxVertical`) gets a picker for the model it goes to.
private struct ImportReviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let onImport: (MappingStore.ImportPreview) -> Void
    @State private var pending: PendingImport
    @State private var retargetError: String?

    init(pending: PendingImport, onImport: @escaping (MappingStore.ImportPreview) -> Void) {
        self.onImport = onImport
        _pending = State(initialValue: pending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Mappings")
                    .font(.headline)
                Text(verbatim: pending.fileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Form {
                modelsSection
                if !pending.preview.actionsToReview.isEmpty {
                    Section {
                        ForEach(Array(pending.preview.actionsToReview.enumerated()), id: \.offset) { _, item in
                            reviewRow(item)
                        }
                    } header: {
                        Text("Check that you trust these actions")
                    } footer: {
                        Text("They open apps, links or shortcuts when you press the button.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !pending.preview.skipped.isEmpty {
                    Section {
                        ForEach(Array(pending.preview.skipped.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Left out (can’t be used)")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 220, idealHeight: 320)

            HStack {
                Text("Your current setup is saved first, so you can undo the import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { onImport(pending.preview) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.preview.models.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540)
    }

    @ViewBuilder
    private var modelsSection: some View {
        switch pending.preview.format {
        case .singleModel:
            Section {
                ModelPicker(selection: targetBinding, label: Text("Import into"))
                    .snapshotAnchor("importTarget")
                if let retargetError {
                    Label(retargetError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Made for \(model.modelName(.mxVertical))")
            } footer: {
                Text("This file comes from an earlier version of Upright, which only supported the \(model.modelName(.mxVertical)). Its buttons and app profiles replace the setup of the model you choose; other models keep theirs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .library:
            Section {
                ForEach(pending.preview.importedModels, id: \.self) { key in
                    LabeledContent {
                        Text(model.connectedModels.contains(key) ? String(localized: "Connected") : String(localized: "Not connected"))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: name(of: key))
                    }
                }
            } header: {
                Text("Setups in this file")
            } footer: {
                Text("Each model’s buttons and app profiles are replaced by the file’s. Models the file doesn’t list keep their setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "<model> · Safari · Back Button – Move Up" over "Opens https://example.com".
    private func reviewRow(_ item: MappingStore.ReviewItem) -> some View {
        let profiles = pending.preview.models[item.model]
        let scope = item.bundleID.map { profiles?[app: $0]?.displayName ?? $0 } ?? String(localized: "All apps")
        var control = ControlDescriptor(cid: item.cid, model: item.model).name
        switch item.slot {
        case .button: break
        case .gestureTap: control += " – " + String(localized: "Click", comment: "Gesture slot: clicking the gesture button")
        case .gesture(let direction): control += " – " + direction.title
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(name(of: item.model, fallback: item.modelName)) · \(scope) · \(control)")
                .font(.callout)
            Text(verbatim: item.action.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func name(of key: ModelKey, fallback: String? = nil) -> String {
        if let name = pending.preview.modelNames[key] { return name }
        let known = model.modelName(key)
        if known == key.rawValue, let fallback { return fallback }
        return known
    }

    /// Changing the target validates the file again for that model (its mice may protect
    /// different buttons).
    private var targetBinding: Binding<ModelKey> {
        Binding(
            get: { pending.target },
            set: { newTarget in
                do {
                    pending.preview = try model.previewImport(pending.data, targetModel: newTarget)
                    pending.target = newTarget
                    retargetError = nil
                } catch {
                    retargetError = String(localized: "The file can’t be imported into that model.")
                }
            }
        )
    }
}
