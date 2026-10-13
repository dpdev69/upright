import SwiftUI

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
        case restoreDefaults
        case clearOverrides(String)

        var id: String {
            switch self {
            case .restoreDefaults: return "restore"
            case .clearOverrides(let bundleID): return "clear." + bundleID
            }
        }
    }

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

            if !model.isRemappingEnabled {
                Section {
                    remappingOffNote
                }
            }

            ProfileSection(selectedBundleID: $profileBundleID)

            Section {
                ForEach(devices.controls) { control in
                    row(for: control)
                }
            } header: {
                if let profile = selectedProfile {
                    Text("Buttons in \(profile.displayName)")
                } else {
                    Text("Buttons")
                }
            } footer: {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(gestureControls) { control in
                if let gestures = gestureBinding(for: control.cid) {
                    GestureEditor(gestures: gestures, title: control.name)
                }
            }

            Section {
                Toggle("Remap buttons", isOn: $model.isRemappingEnabled)
                resetRow
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { item in
            switch item {
            case .restoreDefaults:
                Button("Restore Defaults", role: .destructive) { model.restoreDefaultMappings() }
            case .clearOverrides(let bundleID):
                Button("Clear Overrides", role: .destructive) { model.profiles[app: bundleID]?.overrides = [:] }
            }
        } message: { item in
            switch item {
            case .restoreDefaults:
                Text("Every button goes back to what the mouse does on its own. App profiles are kept.")
            case .clearOverrides:
                Text("Every button in this app uses the global action again.")
            }
        }
        .onChange(of: model.lastPressedControl) { pressed in
            guard let pressed else { return }
            flash(pressed.cid)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for control: ControlDescriptor) -> some View {
        let highlighted = highlightedControl == control.cid
        if let profile = selectedProfile {
            AppOverrideRow(
                control: control,
                override: model.overrideBinding(for: control.cid, bundleID: profile.bundleID),
                globalAction: model.profiles.global[control.cid],
                showsAccessibilityWarning: !permissions.isAccessibilityTrusted,
                isHighlighted: highlighted,
                note: gestureNote(for: control.cid)
            )
        } else {
            ButtonRow(
                control: control,
                action: model.binding(for: control.cid),
                showsAccessibilityWarning: !permissions.isAccessibilityTrusted,
                isHighlighted: highlighted,
                note: gestureNote(for: control.cid)
            )
        }
    }

    private var selectedProfile: AppProfile? {
        profileBundleID.flatMap { model.profiles[app: $0] }
    }

    /// The action being edited for a button: the global one, or the selected app's override.
    private func editedAction(for cid: UInt16) -> ButtonAction? {
        if let profile = selectedProfile { return profile[cid] }
        return model.profiles.global[cid]
    }

    /// Gesture buttons whose movement can't be read without moving the pointer say so.
    private func gestureNote(for cid: UInt16) -> Text? {
        guard editedAction(for: cid)?.isGestures == true, !model.supportsRawXY(cid) else { return nil }
        return Text("The pointer moves while you gesture with this button.")
    }

    private var gestureControls: [ControlDescriptor] {
        devices.controls.filter { editedAction(for: $0.cid)?.isGestures == true }
    }

    private func gestureBinding(for cid: UInt16) -> Binding<GestureSet>? {
        guard case .gestures(let current) = editedAction(for: cid) else { return nil }
        let bundleID = selectedProfile?.bundleID
        return Binding(
            get: {
                let action: ButtonAction?
                if let bundleID {
                    action = model.profiles[app: bundleID]?[cid]
                } else {
                    action = model.profiles.global[cid]
                }
                if case .gestures(let set) = action { return set }
                return current
            },
            set: { newValue in
                if let bundleID {
                    model.profiles[app: bundleID]?[cid] = .gestures(newValue)
                } else {
                    model.profiles.global[cid] = .gestures(newValue)
                }
            }
        )
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

    // MARK: Notes and footer

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
    private var resetRow: some View {
        if let profile = selectedProfile {
            HStack {
                Text("Clear this app’s overrides so every button uses the global action.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear Overrides…") { confirmation = .clearOverrides(profile.bundleID) }
                    .disabled(profile.overrides.isEmpty)
            }
        } else {
            HStack {
                Text("Restore Defaults hands every button back to the mouse. App profiles are kept.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restore Defaults…") { confirmation = .restoreDefaults }
                    .disabled(model.mappings == .defaults)
            }
        }
    }

    private var confirmationTitle: Text {
        switch confirmation {
        case .clearOverrides(let bundleID):
            return Text("Clear the overrides for \(model.profiles[app: bundleID]?.displayName ?? bundleID)?")
        case .restoreDefaults, nil:
            return Text("Restore the default button actions?")
        }
    }

    private var footer: String {
        if selectedProfile != nil {
            return String(localized: "Buttons without an override use the global action. Override with “Default” to leave a button to the mouse in this app only.")
        }
        if devices.snapshot != nil {
            return String(localized: "These are the buttons your mouse reports as remappable. “Default” leaves a button to the mouse: the thumb buttons go back and forward, and the top button switches pointer speed (DPI).")
        }
        return String(localized: "Connect your MX Vertical to see every button it reports. Changes are saved and applied as soon as it connects.")
    }
}
