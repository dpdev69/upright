import SwiftUI

/// Sets up the buttons of one mouse model ("Configure: [model ▾]"): its global table, its
/// app profiles and its gesture buttons. Every identical mouse shares its model's setup, and
/// editing one model never changes another model's table: every binding here names the model
/// it edits, captured when the row is built.
struct ButtonsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor

    /// nil edits the global table; otherwise the app profile with this bundle ID.
    @State private var profileBundleID: String?
    @State private var confirmation: Confirmation?
    @State private var highlightedControl: UInt16?
    @State private var highlightGeneration = 0

    private enum Confirmation: Identifiable {
        case restoreDefaults(ModelKey)
        case clearOverrides(ModelKey, String)
        case copySetup(from: ModelKey, to: ModelKey)
        case applyToAll(from: ModelKey, targets: [ModelKey])

        var id: String {
            switch self {
            case .restoreDefaults(let model): return "restore." + model.rawValue
            case .clearOverrides(let model, let bundleID): return "clear." + model.rawValue + "." + bundleID
            case .copySetup(let source, let target): return "copy." + source.rawValue + "." + target.rawValue
            case .applyToAll(let source, _): return "all." + source.rawValue
            }
        }
    }

    private struct RowID: Hashable {
        let model: ModelKey
        let cid: UInt16
    }

    /// Where the rows of the selected model come from.
    private enum ControlSource {
        /// A mouse of the model is here and reported them.
        case live
        /// A mouse of the model reported them last time it was connected.
        case remembered
        /// The catalog's list for the model.
        case catalog
    }

    var body: some View {
        let selected = model.selectedModel
        let controls = model.controls(for: selected)
        Form {
            Section {
                header(for: selected)
            }

            if devices.needsInputMonitoring {
                Section {
                    InputMonitoringCallout()
                }
            }

            if model.isMissingAccessibility {
                Section {
                    AccessibilityCallout()
                }
            }

            if !model.isRemappingEnabled {
                Section {
                    remappingOffNote
                }
            }

            ProfileSection(model: selected, selectedBundleID: $profileBundleID)

            Section {
                if controls.isEmpty {
                    emptyState
                } else {
                    ForEach(controls) { control in
                        // A fresh row per model, so no picker state carries over to another model.
                        row(for: control, model: selected)
                            .id(RowID(model: selected, cid: control.cid))
                    }
                }
            } header: {
                if let profile = selectedProfile {
                    Text("Buttons in \(profile.displayName)")
                } else {
                    Text("Buttons")
                }
            } footer: {
                Text(footer(for: selected, controls: controls))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(gestureControls(in: controls, model: selected)) { control in
                if let gestures = gestureBinding(for: control.cid, model: selected) {
                    GestureEditor(gestures: gestures, title: control.name)
                        .id(RowID(model: selected, cid: control.cid))
                }
            }

            Section {
                Toggle("Remap buttons", isOn: $model.isRemappingEnabled)
                resetRow(for: selected)
            }

            Section {
                sharingRow(for: selected)
            } header: {
                Text("Other Mice")
            }
        }
        .formStyle(.grouped)
        .environment(\.actionTarget, actionTarget(for: selected))
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { item in
            switch item {
            case .restoreDefaults(let target):
                Button("Restore Defaults", role: .destructive) { model.restoreDefaultMappings(model: target) }
            case .clearOverrides(let target, let bundleID):
                Button("Clear Overrides", role: .destructive) { model.library[target][app: bundleID]?.overrides = [:] }
            case .copySetup(let source, let target):
                Button("Replace Setup", role: .destructive) {
                    profileBundleID = nil
                    model.copySetup(from: source, to: target)
                }
            case .applyToAll(let source, _):
                Button("Use for All Mice", role: .destructive) { model.applySetupToAllModels(from: source) }
            }
        } message: { item in
            confirmationMessage(item)
        }
        .onChange(of: model.lastPressedControl) { pressed in
            // Only presses of a mouse of the model on screen light up a row.
            guard let pressed, pressed.model == model.selectedModel else { return }
            flash(pressed.cid)
        }
        .onChange(of: model.selectedModel) { newModel in
            highlightedControl = nil
            // Keep the same app selected if the new model has a profile for it.
            if let bundleID = profileBundleID, model.library[newModel][app: bundleID] == nil {
                profileBundleID = nil
            }
        }
    }

    // MARK: Header

    /// The model picker, what is connected of that model, and who the setup applies to.
    private func header(for selected: ModelKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemName: liveRecords(of: selected).isEmpty ? "computermouse" : "computermouse.fill", size: 32)
            VStack(alignment: .leading, spacing: 4) {
                ModelPicker(selection: $model.selectedModel)
                    .snapshotAnchor("modelPicker")
                Text(modelStatus(for: selected))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if unitCount(of: selected) > 1 {
                    Label {
                        Text("Applies to every \(model.modelName(selected))")
                    } icon: {
                        Image(systemName: "square.on.square")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .snapshotAnchor("appliesToEvery")
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Endpoints of a model that are identified (connected or asleep) and not unsupported.
    private func liveRecords(of key: ModelKey) -> [DeviceRegistry.Record] {
        devices.records.filter { $0.model == key && $0.role != .unsupported && $0.snapshot != nil }
    }

    /// Mice of a model being served now; a mouse on two links (standby) counts once.
    private func unitCount(of key: ModelKey) -> Int {
        devices.records.filter { $0.model == key && $0.role == .active }.count
    }

    private func modelStatus(for key: ModelKey) -> String {
        let records = liveRecords(of: key).filter { if case .standby = $0.role { return false } else { return true } }
        let connected = records.filter(\.isConnected).map(\.displayName)
        if !connected.isEmpty {
            return String(localized: "Connected: \(ListFormatter.localizedString(byJoining: connected))")
        }
        if !records.isEmpty {
            return String(localized: "Asleep: \(ListFormatter.localizedString(byJoining: records.map(\.displayName)))")
        }
        if model.rememberedModels.contains(key) {
            return String(localized: "Not connected. Changes are saved and applied as soon as it connects.")
        }
        return String(localized: "Not connected yet. You can set it up now; changes apply as soon as one connects.")
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for control: ControlDescriptor, model selected: ModelKey) -> some View {
        let highlighted = highlightedControl == control.cid
        let note = gestureNote(for: control.cid, model: selected)
        let anchor = String(format: "row.%04X", Int(control.cid))
        if let profile = selectedProfile {
            let overrideRow = AppOverrideRow(
                control: control,
                override: model.overrideBinding(for: control.cid, model: selected, bundleID: profile.bundleID),
                globalAction: model.library[selected].global[control.cid],
                showsAccessibilityWarning: !permissions.isAccessibilityTrusted,
                isHighlighted: highlighted,
                note: note
            )
            .snapshotAnchor(anchor)
            if profile[control.cid] != nil {
                overrideRow.snapshotAnchor(String(format: "override.%04X", Int(control.cid)))
            } else {
                overrideRow
            }
        } else {
            ButtonRow(
                control: control,
                action: model.binding(for: control.cid, model: selected),
                showsAccessibilityWarning: !permissions.isAccessibilityTrusted,
                isHighlighted: highlighted,
                note: note
            )
            .snapshotAnchor(anchor)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "computermouse")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Connect a Logitech mouse")
                .font(.headline)
            Text("Its buttons appear here as soon as it connects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// The selected app profile of the model on screen.
    private var selectedProfile: AppProfile? {
        profileBundleID.flatMap { model.library[model.selectedModel][app: $0] }
    }

    /// The action being edited for a button of a model: the global one, or the selected app's override.
    private func editedAction(for cid: UInt16, model selected: ModelKey) -> ButtonAction? {
        if let bundleID = selectedProfile?.bundleID { return model.library[selected][app: bundleID]?[cid] }
        return model.library[selected].global[cid]
    }

    /// Gesture buttons whose movement can't be read without moving the pointer say so (judged on
    /// the selected mouse of the model, else the first one here).
    private func gestureNote(for cid: UInt16, model selected: ModelKey) -> Text? {
        guard editedAction(for: cid, model: selected)?.isGestures == true, !model.supportsRawXY(cid, model: selected) else { return nil }
        return Text("The pointer moves while you gesture with this button.")
    }

    private func gestureControls(in controls: [ControlDescriptor], model selected: ModelKey) -> [ControlDescriptor] {
        controls.filter { editedAction(for: $0.cid, model: selected)?.isGestures == true }
    }

    private func gestureBinding(for cid: UInt16, model selected: ModelKey) -> Binding<GestureSet>? {
        guard case .gestures(let current) = editedAction(for: cid, model: selected) else { return nil }
        let bundleID = selectedProfile?.bundleID
        return Binding(
            get: {
                let action = bundleID.map { model.library[selected][app: $0]?[cid] } ?? model.library[selected].global[cid]
                if case .gestures(let set) = action { return set }
                return current
            },
            set: { newValue in
                if let bundleID {
                    model.library[selected][app: bundleID]?[cid] = .gestures(newValue)
                } else {
                    model.library[selected].global[cid] = .gestures(newValue)
                }
            }
        )
    }

    /// What the mouse being set up can do: the selected mouse if it is of this model, else the
    /// first one here; unknown (everything offered) when none is.
    private func actionTarget(for selected: ModelKey) -> ActionTarget {
        guard let address = model.representativeDevice(of: selected) else { return .unknown }
        return ActionTarget(snapshot: model.snapshot(of: address), name: model.record(address)?.displayName)
    }

    // MARK: Live feedback

    private func flash(_ cid: UInt16) {
        highlightGeneration += 1
        let generation = highlightGeneration
        highlightedControl = cid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if generation == highlightGeneration { highlightedControl = nil }
        }
    }

    // MARK: Notes, reset and sharing

    private var remappingOffNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remapping is off")
                    .font(.headline)
                Text("Every button does what the mouse does on its own. You can still change the actions below; they apply when you turn remapping back on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Turn On") { model.isRemappingEnabled = true }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resetRow(for selected: ModelKey) -> some View {
        if let profile = selectedProfile {
            HStack {
                Text("Clear this app’s overrides so every button uses the global action.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear Overrides…") { confirmation = .clearOverrides(selected, profile.bundleID) }
                    .disabled(profile.overrides.isEmpty)
            }
        } else {
            HStack {
                Text("Restore Defaults hands every button back to the mouse. App profiles are kept.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restore Defaults…") { confirmation = .restoreDefaults(selected) }
                    .disabled(model.library[selected].global == .defaults)
            }
        }
    }

    /// "Copy setup from…" and "Use this setup for all my mice".
    @ViewBuilder
    private func sharingRow(for selected: ModelKey) -> some View {
        let sources = model.library.models
            .filter { $0.key != selected && !$0.value.isEmpty }
            .map(\.key)
            .sorted { model.modelName($0).localizedStandardCompare(model.modelName($1)) == .orderedAscending }
        let targets = model.knownModels.filter { $0 != selected }
        HStack {
            Text("Copy another model’s buttons and app profiles to this one.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Menu("Copy Setup From") {
                ForEach(sources, id: \.self) { source in
                    Button(model.modelName(source)) {
                        confirmation = .copySetup(from: source, to: selected)
                    }
                }
            }
            .fixedSize()
            .disabled(sources.isEmpty)
            .help(sources.isEmpty ? Text("No other model has a setup yet.") : Text("Replace this model’s setup with a copy of another’s"))
        }
        HStack {
            Text("Give every other mouse you use the same buttons and app profiles.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Use This Setup for All My Mice…") {
                confirmation = .applyToAll(from: selected, targets: targets)
            }
            .disabled(targets.isEmpty)
        }
    }

    private var confirmationTitle: Text {
        switch confirmation {
        case .clearOverrides(let target, let bundleID):
            return Text("Clear the overrides for \(model.library[target][app: bundleID]?.displayName ?? bundleID)?")
        case .copySetup(let source, let target):
            return Text("Replace the \(model.modelName(target)) setup with a copy of the \(model.modelName(source)) setup?")
        case .applyToAll(let source, _):
            return Text("Use the \(model.modelName(source)) setup for all your mice?")
        case .restoreDefaults(let target):
            return Text("Restore the default button actions of the \(model.modelName(target))?")
        case nil:
            return Text("Restore the default button actions?")
        }
    }

    private func confirmationMessage(_ item: Confirmation) -> Text {
        switch item {
        case .restoreDefaults:
            return Text("Every button goes back to what the mouse does on its own. App profiles are kept. Other models aren’t changed.")
        case .clearOverrides:
            return Text("Every button in this app uses the global action again.")
        case .copySetup(_, let target):
            return Text("The \(model.modelName(target))’s buttons and app profiles are replaced. Other models aren’t changed.")
        case .applyToAll(_, let targets):
            let names = ListFormatter.localizedString(byJoining: targets.map(model.modelName))
            return Text("The buttons and app profiles of these models are replaced with a copy: \(names). Buttons a model doesn’t have are ignored on it.")
        }
    }

    // MARK: Footer

    private func footer(for selected: ModelKey, controls: [ControlDescriptor]) -> String {
        if selectedProfile != nil {
            return String(localized: "Buttons without an override use the global action. Override with “Default” to leave a button to the mouse in this app only.")
        }
        guard !controls.isEmpty else {
            return String(localized: "Changes are saved and applied as soon as a mouse of this model connects.")
        }
        let name = model.modelName(selected)
        let intro: String
        switch controlSource(for: selected) {
        case .live:
            intro = String(localized: "These are the buttons your \(name) reports as remappable.")
        case .remembered:
            intro = String(localized: "These are the buttons your \(name) reported when it was last connected. Changes are saved and applied as soon as it connects.")
        case .catalog:
            intro = String(localized: "These are the buttons a \(name) is known to have. Changes are saved and applied as soon as one connects.")
        }
        let natives = controls.compactMap(Self.nativeBehavior)
        let defaultNote = natives.isEmpty
            ? String(localized: "“Default” leaves a button to the mouse.")
            : String(localized: "“Default” leaves a button to the mouse: \(ListFormatter.localizedString(byJoining: natives)).")
        return intro + " " + defaultNote
    }

    private func controlSource(for selected: ModelKey) -> ControlSource {
        if !liveRecords(of: selected).isEmpty { return .live }
        let remembered = model.settings.devicePreferences.devices.values.contains {
            $0.lastModel == selected && !$0.lastControls.isEmpty
        }
        return remembered ? .remembered : .catalog
    }

    /// What a control does on its own, in the model's wording ("the Top Button switches pointer
    /// speed (DPI)"); nil when it varies by mouse.
    private static func nativeBehavior(of control: ControlDescriptor) -> String? {
        switch control.cid {
        case KnownControl.back, 0x0054, 0x0055, 0x00AC, 0x00CE:
            return String(localized: "the \(control.name) goes back", comment: "Native behavior of a mouse button; the argument is its name")
        case KnownControl.forward, 0x0057, 0x0058, 0x00CF:
            return String(localized: "the \(control.name) goes forward", comment: "Native behavior of a mouse button; the argument is its name")
        case KnownControl.dpiSwitch, KnownControl.dpiChange:
            return String(localized: "the \(control.name) switches pointer speed (DPI)", comment: "Native behavior of a mouse button; the argument is its name")
        case KnownControl.middleClick:
            return String(localized: "the \(control.name) is a middle click", comment: "Native behavior of a mouse button; the argument is its name")
        case KnownControl.tiltLeft, KnownControl.tiltRight:
            return String(localized: "the \(control.name) scrolls sideways", comment: "Native behavior of a mouse button; the argument is its name")
        case KnownControl.smartShift:
            return String(localized: "the \(control.name) switches the wheel between ratchet and free spin", comment: "Native behavior of a mouse button; the argument is its name")
        default:
            return nil
        }
    }
}
