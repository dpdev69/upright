import AppKit
import Combine
import SwiftUI

/// The panel that drops down from the menu bar icon: one row per mouse (name, connection,
/// battery, state), pointer speed and Easy-Switch of the mouse in focus, and what its buttons do.
///
/// The mouse in focus (`AppModel.menuDevice`) is the last one pressed, else the one selected in
/// Settings, else the first connected one.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var panel = PanelWindow()
    @State private var highlightedControl: UInt16?
    /// Models whose "New:" banner was dismissed (saved in the app's defaults).
    @State private var dismissedNewModels: Set<String> = []

    private static let dismissedNewModelsKey = "menuBar.dismissedNewModels"

    var body: some View {
        let mice = pointerRecords
        VStack(alignment: .leading, spacing: 0) {
            header(mice: mice)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            callout(mice: mice)

            if let newModel = newModel(in: mice) {
                NewModelBanner(name: newModel.name) {
                    dismissNewModel(newModel.key)
                    model.selectedModel = newModel.key
                    openSettings(pane: .buttons)
                } onDismiss: {
                    dismissNewModel(newModel.key)
                }
                .modifier(CalloutBackground(tint: .accentColor))
            }

            if !mice.isEmpty {
                Divider().padding(.horizontal, 10)
                deviceRows(mice)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }

            if let target = quickControlsTarget {
                Divider().padding(.horizontal, 10)
                DeviceQuickControls(
                    record: target.record,
                    snapshot: target.snapshot,
                    showsName: mice.count > 1
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 10)

            mappingsSection(showsModelName: Set(mice.compactMap(\.model)).count > 1)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

            Divider().padding(.horizontal, 10)

            VStack(spacing: 1) {
                MenuItemButton(title: String(localized: "Settings…"), systemImage: "gearshape", shortcut: "⌘,") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)

                MenuItemButton(title: String(localized: "Reconnect All Mice"), systemImage: "arrow.clockwise") {
                    devices.reconnect(nil)
                }
                .help(String(localized: "Looks for every Logitech mouse again and reapplies their button configuration"))

                MenuItemButton(title: String(localized: "Quit Upright"), systemImage: "power", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 440)
        .background(WindowReader { panel.window = $0 })
        .onAppear {
            loadDismissedNewModels()
            devices.refreshDeviceInfo()
        }
        .onReceive(panel.didBecomeKey) { devices.refreshDeviceInfo() }
        .onReceive(model.presses.pressed) { pressed in
            // Only buttons of the mouse whose summary is shown flash.
            guard pressed.source == model.menuDevice || (pressed.model != nil && pressed.model == menuModel) else { return }
            flash(pressed.cid)
        }
    }

    /// Served mice in list order; a second link to a mouse already listed is left out.
    private var pointerRecords: [DeviceRegistry.Record] {
        devices.records.filter { $0.role != .unsupported && !$0.isStandby }
    }

    // MARK: Header

    private func header(mice: [DeviceRegistry.Record]) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: devices.summary.anyConnected ? "computermouse.fill" : "computermouse")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Upright")
                    .font(.headline)
                statusLine(mice: mice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("Remap buttons", isOn: $model.isRemappingEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(model.isRemappingEnabled ? String(localized: "Remapping is on") : String(localized: "Remapping is off"))
                .accessibilityLabel(Text("Remap buttons"))
        }
    }

    @ViewBuilder
    private func statusLine(mice: [DeviceRegistry.Record]) -> some View {
        HStack(spacing: 5) {
            if mice.isEmpty {
                // No mouse yet: what the interfaces are doing (searching, a receiver waiting
                // for its mouse, access refused). The one place the panel reads the compat status.
                StatusDot(indicator: devices.status.indicator)
                Text(devices.status.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !devices.summary.problems.isEmpty, devices.summary.connectedCount == 0 {
                StatusDot(indicator: .problem)
                Text("Connection problem")
                Button(String(localized: "Details…")) { openSettings(pane: .device, device: devices.summary.problems.first) }
                    .buttonStyle(.link)
            } else {
                StatusDot(indicator: devices.summary.anyConnected ? .good : .pending)
                Text(verbatim: Self.fleetText(mice: mice, connected: devices.summary.connectedCount))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "2 mice connected", "1 mouse connected", "Asleep — move a mouse to wake it", "Connecting…".
    private static func fleetText(mice: [DeviceRegistry.Record], connected: Int) -> String {
        if connected == 1 { return String(localized: "1 mouse connected") }
        if connected > 1 { return String(localized: "\(connected) mice connected") }
        if mice.contains(where: { if case .asleep = $0.state { return true } else { return false } }) {
            return String(localized: "Asleep — move a mouse to wake it")
        }
        return String(localized: "Connecting…")
    }

    // MARK: Callouts

    @ViewBuilder
    private func callout(mice: [DeviceRegistry.Record]) -> some View {
        if devices.needsInputMonitoring {
            InputMonitoringCallout(compact: true)
                .modifier(CalloutBackground(tint: .orange))
        } else if model.isMissingAccessibility {
            AccessibilityCallout(compact: true)
                .modifier(CalloutBackground(tint: .orange))
        } else if mice.isEmpty, devices.status == .searching {
            ConnectionHint()
                .modifier(CalloutBackground(tint: .secondary))
        }
    }

    // MARK: New model

    /// A connected model Upright has no setup for yet (other than the MX Vertical, which the
    /// first-run window covers), until its banner is dismissed or the model gets a setup.
    private func newModel(in mice: [DeviceRegistry.Record]) -> (key: ModelKey, name: String)? {
        guard settings.hasCompletedOnboarding else { return nil }
        for record in mice where record.role == .active && record.snapshot != nil {
            guard let key = record.model, key != .mxVertical,
                  model.library.models[key] == nil,
                  !dismissedNewModels.contains(key.rawValue)
            else { continue }
            return (key, model.modelName(key))
        }
        return nil
    }

    private func loadDismissedNewModels() {
        dismissedNewModels = Set(model.defaults.stringArray(forKey: Self.dismissedNewModelsKey) ?? [])
    }

    private func dismissNewModel(_ key: ModelKey) {
        dismissedNewModels.insert(key.rawValue)
        model.defaults.set(dismissedNewModels.sorted(), forKey: Self.dismissedNewModelsKey)
    }

    // MARK: Mice

    private func deviceRows(_ mice: [DeviceRegistry.Record]) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(mice.enumerated()), id: \.element.address) { index, record in
                MenuDeviceRow(record: record, isInFocus: mice.count > 1 && record.address == model.menuDevice) {
                    openSettings(pane: .device, device: record.address)
                }
                .snapshotAnchor("battery.\(index + 1)")
            }
        }
    }

    /// The mouse in focus, when it has a pointer speed or several Easy-Switch channels.
    private var quickControlsTarget: (record: DeviceRegistry.Record, snapshot: DeviceSnapshot)? {
        guard let address = model.menuDevice,
              let record = devices.records.first(where: { $0.address == address }),
              record.role == .active,
              let snapshot = record.snapshot,
              snapshot.dpi != nil || (snapshot.hosts?.count ?? 0) > 1
        else { return nil }
        return (record, snapshot)
    }

    // MARK: Mappings

    /// The model whose buttons are summarized: the mouse in focus, else the Buttons pane's model.
    private var menuModel: ModelKey {
        model.menuDevice.flatMap(model.model(of:)) ?? model.selectedModel
    }

    private func mappingsSection(showsModelName: Bool) -> some View {
        let shownModel = menuModel
        let mappings = model.effectiveMappings(model: shownModel)
        return VStack(alignment: .leading, spacing: 1) {
            mappingsHeader(model: shownModel, showsModelName: showsModelName)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 4)

            ForEach(model.controls(for: shownModel)) { control in
                MappingSummaryRow(
                    control: control,
                    action: mappings[control.cid],
                    isPaused: !model.isRemappingEnabled,
                    isHighlighted: highlightedControl == control.cid
                ) {
                    if model.selectedModel != shownModel { model.selectedModel = shownModel }
                    openSettings(pane: .buttons)
                }
            }
        }
    }

    private func mappingsHeader(model shownModel: ModelKey, showsModelName: Bool) -> some View {
        HStack(spacing: 4) {
            Group {
                if let app = activeProfileApp(for: shownModel) {
                    Text("In \(app.name)")
                        .help(String(localized: "\(app.name) has its own button settings"))
                } else {
                    Text("Buttons")
                }
            }
            if showsModelName {
                Text(verbatim: "· " + model.modelName(shownModel))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.isRemappingEnabled {
                Label("Paused — mouse defaults", systemImage: "pause.circle")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The frontmost app, when it has an enabled profile of its own for `shownModel`.
    private func activeProfileApp(for shownModel: ModelKey) -> FrontmostApp? {
        guard let app = model.frontmostApp,
              model.profiles(for: shownModel).enabledProfile(forBundleID: app.bundleID) != nil
        else { return nil }
        return app
    }

    private func flash(_ cid: UInt16) {
        withAnimation(.easeOut(duration: 0.15)) { highlightedControl = cid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard highlightedControl == cid else { return }
            withAnimation(.easeOut(duration: 0.3)) { highlightedControl = nil }
        }
    }

    // MARK: Actions

    /// Closes this panel (a MenuBarExtra window doesn't close itself when a button in it is
    /// clicked), then opens Settings, optionally on one mouse in the Mice pane.
    private func openSettings(pane: SettingsPane? = nil, device: DeviceAddress? = nil) {
        panel.close()
        SettingsWindowController.shared.show(pane: pane, device: device)
    }
}

// MARK: - Menu bar label

/// The status item: a filled mouse while any mouse is connected, and optionally the lowest
/// battery level among connected mice (red when it is low).
struct MenuBarLabel: View {
    @ObservedObject var devices: DeviceManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        let summary = devices.summary
        let icon = Image(systemName: summary.anyConnected ? "computermouse.fill" : "computermouse")
        Group {
            if settings.showBatteryInMenuBar, let battery = summary.lowestBattery?.status {
                // One Text, so the menu bar shows both the icon and the level.
                Text(icon) + Text(verbatim: " " + battery.levelText).foregroundColor(battery.isLow ? .red : nil)
            } else {
                icon
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    /// Every mouse, for example "Upright, MX Vertical connected, battery 80%, MX Master 3S asleep".
    private var accessibilityText: String {
        var parts = ["Upright"]
        let mice = devices.records.filter { $0.role != .unsupported && !$0.isStandby }
        if mice.isEmpty {
            // No mouse yet: what the interfaces are doing (the documented status fallback).
            switch devices.status {
            case .connected: parts.append(String(localized: "connected"))
            case .asleep: parts.append(String(localized: "mouse asleep"))
            case .probing, .waiting: parts.append(String(localized: "connecting"))
            case .searching: parts.append(String(localized: "not connected"))
            case .accessDenied: break
            case .failed: parts.append(String(localized: "connection problem"))
            }
        }
        for record in mice {
            let name = record.displayName
            switch record.state {
            case .connected(let snapshot):
                if let battery = snapshot.battery {
                    parts.append(String(localized: "\(name) connected, \(battery.accessibilityDescription)", comment: "Menu bar accessibility: a mouse and its battery"))
                } else {
                    parts.append(String(localized: "\(name) connected", comment: "Menu bar accessibility"))
                }
            case .asleep:
                parts.append(String(localized: "\(name) asleep", comment: "Menu bar accessibility"))
            case .probing, .waitingForDevice:
                parts.append(String(localized: "\(name) connecting", comment: "Menu bar accessibility"))
            case .failed:
                parts.append(String(localized: "\(name) has a connection problem", comment: "Menu bar accessibility"))
            case .unsupported:
                break
            }
        }
        if devices.needsInputMonitoring {
            parts.append(String(localized: "needs Input Monitoring access"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Device rows

/// One mouse: connection glyph, name, connection and state, battery.
private struct MenuDeviceRow: View {
    let record: DeviceRegistry.Record
    /// The mouse the controls below act on (marked when there are several).
    let isInFocus: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: record.connection.symbolName)
                    .foregroundStyle(record.isConnected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: record.displayName)
                        .fontWeight(isInFocus ? .semibold : .regular)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        StatusDot(indicator: record.indicator)
                        Text(verbatim: "\(record.connection.compactTitle) · \(record.stateText)")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let battery = record.snapshot?.battery {
                    BatteryLabel(battery: battery)
                        .font(.callout)
                        .opacity(record.isConnected ? 1 : 0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityHint(Text("Opens this mouse in Settings"))
        .accessibilityAddTraits(.isButton)
    }

    /// "MX Master 3S, Bolt receiver, connected, Battery 80%".
    private var accessibilityText: String {
        var parts = [record.displayName, record.connection.title, record.stateText]
        if let battery = record.snapshot?.battery {
            parts.append(battery.accessibilityDescription)
        }
        return parts.joined(separator: ", ")
    }
}

/// "New: MX Master 3S. Its buttons work as usual. Set Up…"
private struct NewModelBanner: View {
    let name: String
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("New: \(name)")
                    .font(.headline)
                Text("Its buttons work as usual until you set them up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up…", action: onSetUp)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss"))
            .accessibilityLabel(Text("Dismiss"))
        }
    }
}

// MARK: - Device controls

/// Pointer speed presets and the current Easy-Switch channel of one mouse.
private struct DeviceQuickControls: View {
    let record: DeviceRegistry.Record
    let snapshot: DeviceSnapshot
    /// Several mice: name the one these controls act on.
    let showsName: Bool

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsName {
                Text(verbatim: record.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }

            if let dpi = snapshot.dpi {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Pointer speed", systemImage: "speedometer")
                        Spacer(minLength: 8)
                        Text("\(dpi.current) DPI")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    if !settings.dpiPresets.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(settings.dpiPresets, id: \.self) { preset in
                                presetButton(preset, dpi: dpi)
                            }
                        }
                    }
                }
            }

            if let hosts = snapshot.hosts, hosts.count > 1 {
                HStack {
                    Label("Easy-Switch", systemImage: "laptopcomputer.and.arrow.down")
                    Spacer(minLength: 8)
                    Text(channelText(hosts))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.callout)
    }

    private func presetButton(_ preset: Int, dpi: DPIInfo) -> some View {
        let isCurrent = dpi.nearest(to: preset) == dpi.current
        return Button {
            model.setPreferredDPI(preset, for: record.address)
        } label: {
            Text(verbatim: "\(preset)")
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(isCurrent ? .callout.weight(.semibold) : .callout)
        .overlay(alignment: .bottom) {
            if isCurrent {
                Capsule().fill(Color.accentColor).frame(width: 14, height: 2).offset(y: 3)
            }
        }
        .accessibilityLabel(Text("\(preset) DPI"))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help(String(localized: "Set the pointer speed of \(record.displayName) to \(preset) DPI"))
    }

    private func channelText(_ hosts: HostInfo) -> String {
        let channel = hosts.current + 1
        if let name = hosts.name(at: hosts.current), !name.isEmpty {
            return String(localized: "Channel \(channel) · \(name)")
        }
        return String(localized: "Channel \(channel) of \(hosts.count)")
    }
}

// MARK: - Rows

private struct MappingSummaryRow: View {
    let control: ControlDescriptor
    let action: ButtonAction
    let isPaused: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: control.symbolName)
                    .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(control.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    if isPaused, action != .deviceDefault {
                        Image(systemName: "pause.circle")
                            .help(String(localized: "Remapping is off"))
                    } else if action.isGestures {
                        Image(systemName: action.symbolName)
                    }
                    Text(action.title)
                        .lineLimit(1)
                        .strikethrough(isPaused && action != .deviceDefault)
                }
                .foregroundStyle(.secondary)
                .opacity(isPaused ? 0.7 : 1)
            }
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.18 : 0))
                    .padding(-4)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
        .help(action.helpText)
        .accessibilityLabel(Text(control.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text("Opens button settings"))
    }

    private var accessibilityValue: String {
        isPaused && action != .deviceDefault
            ? String(localized: "\(action.title), paused")
            : action.title
    }
}

private struct MenuItemButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 16)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct CalloutBackground: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }
}

/// The MenuBarExtra panel's window: closes it on demand and reports when it opens.
@MainActor
private final class PanelWindow: ObservableObject {
    let didBecomeKey = PassthroughSubject<Void, Never>()

    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            tokens.removeObservers()
            guard let window else { return }
            tokens.addObserver(
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActorDelivery.run { self?.didBecomeKey.send() }
                }
            )
        }
    }

    private let tokens = ListenerTokens()

    func close() {
        if let window {
            window.close()
        } else if let key = NSApp.keyWindow, key !== SettingsWindowController.shared.window {
            key.close()
        }
    }
}
