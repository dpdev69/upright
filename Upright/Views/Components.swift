import AppKit
@preconcurrency import ObjectiveC
import SwiftUI

enum StatusIndicator {
    case good
    case pending
    case idle
    case problem

    var color: Color {
        switch self {
        case .good: return .green
        case .pending: return .orange
        case .idle: return .secondary
        case .problem: return .red
        }
    }
}

struct StatusDot: View {
    let indicator: StatusIndicator

    var body: some View {
        Circle()
            .fill(indicator.color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// Rounded-square SF Symbol tile, in the style of System Settings' sidebar icons.
struct SymbolTile: View {
    let systemName: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(color.gradient)
            )
            .accessibilityHidden(true)
    }
}

struct BatteryLabel: View {
    let battery: BatteryStatus

    var body: some View {
        Label(battery.levelText, systemImage: battery.symbolName)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(battery.isLow ? Color.red : Color.secondary)
            .help(battery.isCharging ? String(localized: "Charging") : String(localized: "Battery level"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(battery.accessibilityDescription)
    }
}

extension BatteryStatus {
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// The level as the user's locale writes percentages.
    var percentText: String {
        Self.percentFormatter.string(from: NSNumber(value: Double(percentage) / 100)) ?? "\(percentage)%"
    }

    /// "80%", or "~50%" when the mouse only reports a coarse level.
    var levelText: String {
        isApproximate ? "~" + percentText : percentText
    }

    var isLow: Bool { percentage <= 10 && !isCharging }

    /// For example "Battery about 50%, charging".
    var accessibilityDescription: String {
        var text = isApproximate
            ? String(localized: "Battery about \(percentText)")
            : String(localized: "Battery \(percentText)")
        if isCharging { text += ", " + String(localized: "charging") }
        return text
    }
}

/// Reports the NSWindow hosting a SwiftUI view (nil until the view is in a window).
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onChange = onChange
    }

    final class WindowReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}

/// A row-style button for custom lists (the menu bar panel): highlights on hover and draws a
/// focus ring when reached with the keyboard.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isFocused ? 2 : 0)
                )
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            return hovering ? Color.primary.opacity(0.08) : .clear
        }
    }
}

/// Large header describing one mouse and its connection.
///
/// `DeviceHeader(record:)` shows that endpoint. `DeviceHeader()` shows the mouse selected in the
/// Mice pane, else the first connected one; with no mouse at all it falls back to what the
/// interfaces are doing (`DeviceManager.status`: searching, a receiver waiting for its mouse,
/// macOS blocking access). That fallback is the only place views read the compat status.
struct DeviceHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager

    private let fixedRecord: DeviceRegistry.Record?
    private let followsSelection: Bool

    /// The selected mouse, else the primary one, else the interfaces' status.
    init() {
        fixedRecord = nil
        followsSelection = true
    }

    /// One endpoint; nil shows the interfaces' status.
    init(record: DeviceRegistry.Record?) {
        fixedRecord = record
        followsSelection = false
    }

    var body: some View {
        if let record {
            DeviceHeaderContent(
                title: record.displayName,
                subtitle: record.stateDetail,
                indicator: record.indicator,
                isFilled: record.snapshot != nil,
                battery: record.isConnected ? record.snapshot?.battery : nil
            )
        } else {
            DeviceHeaderContent(
                title: devices.status.title,
                subtitle: devices.status.subtitle,
                indicator: devices.status.indicator,
                isFilled: false,
                battery: nil
            )
        }
    }

    private var record: DeviceRegistry.Record? {
        guard followsSelection else { return fixedRecord }
        let candidates = [model.selectedDevice, devices.primaryAddress].compactMap { $0 }
        for address in candidates {
            if let record = devices.records.first(where: { $0.address == address }), record.role != .unsupported {
                return record
            }
        }
        return nil
    }
}

/// The header's layout: a mouse glyph, a name, a status line and an optional battery level.
struct DeviceHeaderContent: View {
    let title: String
    let subtitle: String
    let indicator: StatusIndicator
    var isFilled = true
    var battery: BatteryStatus?
    var badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isFilled ? "computermouse.fill" : "computermouse")
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                        .font(.title3.weight(.semibold))
                    if let badge {
                        BadgeLabel(text: badge)
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(indicator: indicator)
                    Text(verbatim: subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer()
            if let battery {
                BatteryLabel(battery: battery)
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A small capsule label, e.g. "Untested model".
struct BadgeLabel: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

extension DeviceRegistry.Record {
    var isStandby: Bool {
        if case .standby = role { return true }
        return false
    }

    /// Why the device isn't served, for the "Other Logitech devices" list.
    var unsupportedReason: UnsupportedReason? {
        if case .unsupported(let reason, _) = state { return reason }
        return nil
    }

    /// The snapshot of a connected or asleep mouse, or what an unsupported device reported.
    var anySnapshot: DeviceSnapshot? {
        if case .unsupported(_, let partial) = state { return partial }
        return snapshot
    }

    /// "Bolt receiver, slot 2", "USB cable", "Bluetooth".
    var placeText: String {
        guard !address.isDirect else { return connection.title }
        return String(localized: "\(connection.title), slot \(Int(address.index))", comment: "Where a mouse is connected: a receiver and its slot")
    }

    /// A word or two: "Connected", "Asleep", "Connecting…".
    var stateText: String {
        switch state {
        case .connected: return String(localized: "Connected")
        case .asleep: return String(localized: "Asleep")
        case .probing: return String(localized: "Connecting…")
        case .waitingForDevice: return String(localized: "Waiting")
        case .failed(let message):
            return message == "Disconnected" ? String(localized: "Disconnected") : String(localized: "Not answering")
        case .unsupported: return String(localized: "Not supported")
        }
    }

    /// A status line for headers: how it is connected and what it is doing.
    var stateDetail: String {
        switch state {
        case .connected:
            return String(localized: "Connected via \(placeText)")
        case .asleep:
            return String(localized: "Asleep — move the mouse to wake it")
        case .probing:
            return String(localized: "Connecting via \(placeText)…")
        case .waitingForDevice:
            return String(localized: "\(placeText) — click a mouse button to wake it")
        case .failed(let message):
            return message == "Disconnected" ? String(localized: "Disconnected") : String(localized: "The mouse isn’t answering")
        case .unsupported(let reason, _):
            return reason.message
        }
    }

    var indicator: StatusIndicator {
        switch state {
        case .connected: return isStandby ? .idle : .good
        case .asleep, .probing, .waitingForDevice: return .pending
        case .unsupported: return .idle
        case .failed: return .problem
        }
    }

    /// The model's catalog entry says it was tested on real hardware (only the MX Vertical).
    var isUntestedModel: Bool {
        guard let model else { return false }
        return DeviceCatalog.model(model)?.verification != .hardware
    }
}

extension ConnectionKind {
    /// "USB", "Bluetooth", "Unifying", "Bolt", "Nano": compact, for rows and badges.
    var compactTitle: String {
        switch self {
        case .usb: return String(localized: "USB", comment: "Short connection name")
        case .bluetooth: return String(localized: "Bluetooth", comment: "Short connection name")
        case .unifying: return "Unifying"
        case .bolt: return "Bolt"
        case .nano: return "Nano"
        }
    }
}

/// How to get a mouse talking to Upright, shown while none is connected.
struct ConnectionHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("How to connect")
                    .font(.headline)
                Text("Plug in a Logitech Unifying, Bolt or Nano receiver, connect the USB cable, or pair the mouse over Bluetooth. Then click a mouse button to wake it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown when macOS refuses to open a Logitech interface until Input Monitoring is allowed.
/// Names the interfaces it refused (`DeviceManager.blockedInterfaces`).
struct InputMonitoringCallout: View {
    @EnvironmentObject private var permissions: PermissionsMonitor
    @EnvironmentObject private var devices: DeviceManager
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Image(systemName: "keyboard.badge.eye")
                .font(compact ? .body : .title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Monitoring needed")
                    .font(.headline)
                if !compact {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(compact ? "Allow…" : "Open Settings…") {
                permissions.requestInputMonitoring()
            }
            .controlSize(compact ? .small : .regular)
        }
    }

    private var message: String {
        let names = ListFormatter.localizedString(byJoining: devices.blockedInterfaces)
        if names.isEmpty {
            return String(localized: "macOS is hiding your Logitech mouse, so button remaps are not applied. Allow Upright under Privacy & Security → Input Monitoring. The buttons keep their normal behavior until then.")
        }
        return String(localized: "macOS is hiding \(names), so button remaps are not applied there. Allow Upright under Privacy & Security → Input Monitoring. The buttons keep their normal behavior until then.")
    }
}

/// Inline call to action shown when a mapping needs Accessibility access.
struct AccessibilityCallout: View {
    @EnvironmentObject private var permissions: PermissionsMonitor
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(compact ? .body : .title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility access needed")
                    .font(.headline)
                if !compact {
                    Text("Upright sends keyboard shortcuts, media keys and clicks on behalf of your mouse. Until you allow it, mapped buttons keep their normal behavior.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(compact ? "Allow…" : "Open Settings…") {
                permissions.requestAccessibility()
            }
            .controlSize(compact ? .small : .regular)
        }
    }
}

/// Placeholder for panes with nothing to show (ContentUnavailableView needs macOS 14).
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Holds notification observers and an optional local event monitor, and removes them when it
/// goes away. Owners keep one as a `let`, so their own deinit has nothing isolated to touch.
/// Not thread-safe: use it from the main actor only (its deinit runs wherever the last
/// reference is released, after which nothing else can reach it).
final class ListenerTokens: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?

    var hasMonitor: Bool { monitor != nil }

    func addObserver(_ token: NSObjectProtocol) {
        observers.append(token)
    }

    func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func setMonitor(_ token: Any?) {
        removeMonitor()
        monitor = token
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        removeMonitor()
        removeObservers()
    }
}
