import AppKit
import Combine
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var panel = PanelWindow()
    @State private var highlightedControl: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            callout

            if let snapshot = devices.snapshot, snapshot.dpi != nil || (snapshot.hosts?.count ?? 0) > 1 {
                Divider().padding(.horizontal, 10)
                DeviceQuickControls(snapshot: snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 10)

            mappingsSection
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

            Divider().padding(.horizontal, 10)

            VStack(spacing: 1) {
                MenuItemButton(title: String(localized: "Settings…"), systemImage: "gearshape", shortcut: "⌘,") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)

                MenuItemButton(title: String(localized: "Reconnect Mouse"), systemImage: "arrow.clockwise") {
                    devices.reconnect()
                }

                MenuItemButton(title: String(localized: "Quit Upright"), systemImage: "power", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 440)
        .background(WindowReader { panel.window = $0 })
        .onAppear { devices.refreshDeviceInfo() }
        .onReceive(panel.didBecomeKey) { devices.refreshDeviceInfo() }
        .onChange(of: model.lastPressedControl) { pressed in
            guard let pressed else { return }
            flash(pressed.cid)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: devices.snapshot == nil ? "computermouse" : "computermouse.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(devices.status.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
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

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                StatusDot(indicator: devices.status.indicator)
                if case .failed = devices.status {
                    Text("Connection problem")
                    Button(String(localized: "Details…")) { openSettings(pane: .device) }
                        .buttonStyle(.link)
                        .help(devices.status.subtitle)
                } else {
                    Text(devices.status.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let battery = devices.snapshot?.battery {
                HStack(spacing: 5) {
                    BatteryLabel(battery: battery)
                    if battery.isCharging {
                        Text("Charging")
                    }
                }
            }
        }
    }

    // MARK: Callouts

    @ViewBuilder
    private var callout: some View {
        if devices.status == .accessDenied {
            InputMonitoringCallout(compact: true)
                .modifier(CalloutBackground(tint: .orange))
        } else if model.isMissingAccessibility {
            AccessibilityCallout(compact: true)
                .modifier(CalloutBackground(tint: .orange))
        } else if devices.status == .searching {
            ConnectHint()
                .modifier(CalloutBackground(tint: .secondary))
        }
    }

    // MARK: Mappings

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            mappingsHeader
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 4)

            let mappings = model.effectiveMappings
            ForEach(devices.controls) { control in
                MappingSummaryRow(
                    control: control,
                    action: mappings[control.cid],
                    isPaused: !model.isRemappingEnabled,
                    isHighlighted: highlightedControl == control.cid
                ) {
                    openSettings(pane: .buttons)
                }
            }
        }
    }

    private var mappingsHeader: some View {
        HStack(spacing: 6) {
            if let app = activeProfileApp {
                Text("In \(app.name)")
                    .help(String(localized: "\(app.name) has its own button settings"))
            } else {
                Text("Buttons")
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

    /// The frontmost app, when it has an enabled profile of its own.
    private var activeProfileApp: FrontmostApp? {
        guard let app = model.frontmostApp, model.profiles.enabledProfile(forBundleID: app.bundleID) != nil else { return nil }
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
    /// clicked), then opens Settings.
    private func openSettings(pane: SettingsPane? = nil) {
        panel.close()
        SettingsWindowController.shared.show(pane: pane)
    }
}

// MARK: - Device controls

/// Pointer speed presets and the current Easy-Switch channel.
private struct DeviceQuickControls: View {
    let snapshot: DeviceSnapshot

    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            devices.setDPI(preset)
            settings.preferredDPI = preset
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
        .help(String(localized: "Set pointer speed to \(preset) DPI"))
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

/// How to get the mouse talking to Upright, shown while nothing is connected.
private struct ConnectHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("How to connect")
                    .font(.headline)
                Text("Plug in the Unifying receiver, connect the USB cable, or pair over Bluetooth. Then click a mouse button to wake it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
