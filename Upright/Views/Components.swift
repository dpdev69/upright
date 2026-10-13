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

/// Large header describing the mouse and its connection.
struct DeviceHeader: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: devices.snapshot == nil ? "computermouse" : "computermouse.fill")
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 3) {
                Text(devices.status.title)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(indicator: devices.status.indicator)
                    Text(devices.status.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer()
            if let battery = devices.snapshot?.battery {
                BatteryLabel(battery: battery)
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shown when macOS is hiding the mouse until Input Monitoring is allowed.
struct InputMonitoringCallout: View {
    @EnvironmentObject private var permissions: PermissionsMonitor
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Image(systemName: "keyboard.badge.eye")
                .font(compact ? .body : .title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Monitoring needed")
                    .font(.headline)
                if !compact {
                    Text("macOS is hiding the MX Vertical, so button remaps are not applied. Allow Upright under Privacy & Security → Input Monitoring. The top button keeps changing pointer speed until then.")
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
