import AppKit
import SwiftUI

/// First-run window: connect the mouse, allow Accessibility, pick a starting setup.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        AppActivation.windowWillShow(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Marks onboarding done and closes the window.
    func finish() {
        AppModel.shared.settings.hasCompletedOnboarding = true
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let model = AppModel.shared
        let root = OnboardingView(onFinish: { [weak self] in self?.finish() })
            .environmentObject(model)
            .environmentObject(model.devices)
            .environmentObject(model.permissions)
            .environmentObject(model.settings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = String(localized: "Welcome to Upright")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        // Closing the window counts as done: it isn't shown again at the next launch.
        AppModel.shared.settings.hasCompletedOnboarding = true
        AppActivation.windowWillClose(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window, !window.isVisible else { return }
            self.window = nil
        }
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case connect, accessibility, setup
    }

    let onFinish: () -> Void

    @State private var step: Step = .connect

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(systemName: "computermouse.fill", color: .accentColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Upright")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StepDots(current: step.rawValue, count: Step.allCases.count)
            }
            .padding(.bottom, 20)

            Group {
                switch step {
                case .connect: ConnectStep()
                case .accessibility: AccessibilityStep()
                case .setup: SetupStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step != .connect {
                    Button("Back") { move(by: -1) }
                }
                Spacer()
                if step == .setup {
                    Button("Customize Buttons…") {
                        // Open Settings first so the app doesn't briefly drop out of the Dock.
                        SettingsWindowController.shared.show(pane: .buttons)
                        onFinish()
                    }
                    Button("Done") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { move(by: 1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 540, height: 460)
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A status line with an icon that differs by state, so it isn't conveyed by color alone.
private struct StatusRow: View {
    let isDone: Bool
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isDone ? Color.green : Color.secondary)
        }
        .font(.body.weight(.medium))
    }
}

// MARK: Steps

private struct ConnectStep: View {
    @EnvironmentObject private var devices: DeviceManager

    /// Mice Upright serves or is identifying, in list order. Unsupported devices aren't offered.
    private var mice: [DeviceRegistry.Record] {
        devices.records.filter { $0.role != .unsupported && $0.snapshot != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "Connect your Logitech mouse",
                message: "Plug in its receiver, connect the USB cable, or pair the mouse over Bluetooth. Then click a mouse button to wake it. Upright works with several mice at once."
            )
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if mice.isEmpty {
                        SearchingRow()
                    } else {
                        ForEach(mice) { record in
                            DetectedMouseRow(record: record)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            if devices.needsInputMonitoring {
                InputMonitoringCallout()
            } else if !devices.summary.anyPresent {
                Text("You can continue without a mouse; Upright connects as soon as one appears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The icon tile shared by the rows of the connect step.
private struct MouseTile: View {
    let isPresent: Bool

    var body: some View {
        Image(systemName: isPresent ? "computermouse.fill" : "computermouse")
            .font(.system(size: 30, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .frame(width: 52, height: 52)
            .background(Circle().fill(.quaternary))
            .accessibilityHidden(true)
    }
}

/// Shown while no mouse has identified: what the interfaces are doing (searching, connecting,
/// waiting for a mouse to wake).
private struct SearchingRow: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        HStack(spacing: 14) {
            MouseTile(isPresent: false)
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
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A mouse Upright found: its name, how it connects and its battery.
private struct DetectedMouseRow: View {
    let record: DeviceRegistry.Record

    var body: some View {
        HStack(spacing: 14) {
            MouseTile(isPresent: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: record.displayName)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(indicator: record.isConnected ? .good : .pending)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
            if let battery = record.snapshot?.battery {
                Label {
                    Text(verbatim: (battery.isApproximate ? "~" : "") + percent(battery.percentage))
                } icon: {
                    Image(systemName: battery.symbolName)
                }
                .font(.callout)
                .foregroundStyle(battery.percentage <= 10 && !battery.isCharging ? Color.red : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if record.isConnected {
            return String(localized: "Connected via \(record.connection.title)")
        }
        return String(localized: "Asleep — move the mouse to wake it")
    }

    private func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct AccessibilityStep: View {
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "Allow Accessibility",
                message: "Upright needs Accessibility access to send keyboard shortcuts, media keys and clicks for your mouse buttons. It doesn't read what you type."
            )
            StatusRow(
                isDone: permissions.isAccessibilityTrusted,
                text: permissions.isAccessibilityTrusted
                    ? String(localized: "Accessibility access is allowed")
                    : String(localized: "Accessibility access is not allowed yet")
            )
            if !permissions.isAccessibilityTrusted {
                HStack {
                    Button("Allow Accessibility…") { permissions.requestAccessibility() }
                        .controlSize(.large)
                    if permissions.accessibilityGrantIsStale {
                        Button("Reset Permission") { permissions.resetAccessibilityPermission() }
                            .disabled(permissions.isResettingAccessibility)
                    }
                }
                if permissions.accessibilityGrantIsStale {
                    Text("Accessibility is off. If you already turned it on, macOS may have kept an outdated entry — Reset fixes that.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Turn on Upright in System Settings → Privacy & Security → Accessibility. This step updates by itself once access is allowed. You can also skip it and allow access later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupStep: View {
    enum Choice: Hashable {
        case mouseDefaults
        case suggested
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                title: "Choose a starting setup",
                message: "You can change any button later in Settings, and set different actions for individual apps."
            )

            targetLine

            VStack(spacing: 8) {
                ChoiceCard(
                    title: "Keep mouse defaults",
                    detail: String(localized: "Every button keeps the behavior the mouse gives it. Nothing is remapped."),
                    isSelected: choice == .mouseDefaults
                ) { apply(.mouseDefaults) }
                if !suggested.isEmpty {
                    ChoiceCard(
                        title: "Suggested",
                        detail: suggestedDetail,
                        isSelected: choice == .suggested
                    ) { apply(.suggested) }
                }
            }

            if choice == .suggested, !permissions.isAccessibilityTrusted {
                Label("Mapped buttons start working once Accessibility access is allowed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TryItLine(presses: model.presses)
        }
    }

    /// The model this step sets up: the connected mouse's (`selectedModel` follows it).
    private var target: ModelKey { model.selectedModel }

    /// Names the mouse being set up, with a picker when mice of different models are connected.
    @ViewBuilder
    private var targetLine: some View {
        let models = model.connectedModels
        if models.count > 1 {
            Picker("Set up", selection: $model.selectedModel) {
                ForEach(models, id: \.self) { key in
                    Text(verbatim: model.modelName(key)).tag(key)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        } else if devices.summary.anyPresent {
            Text("Setting up your \(model.modelName(target)). Other mice keep their own setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("No mouse is connected yet, so this sets up the \(model.modelName(target)). Other mice keep their own setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The suggested mappings for the target model's buttons.
    private var suggested: [UInt16: ButtonAction] {
        ButtonMappings.suggested(for: target, controls: model.controls(for: target).map(\.cid)).mappedControls
    }

    private var choice: Choice {
        let table = model.profiles(for: target).global
        let wanted = suggested
        return !wanted.isEmpty && wanted.allSatisfy { table[$0.key] == $0.value } ? .suggested : .mouseDefaults
    }

    /// Describes what Suggested does on this model, from the table it would apply.
    private var suggestedDetail: String {
        let table = suggested
        var parts: [String] = []
        if table[KnownControl.back] != nil, table[KnownControl.forward] != nil {
            parts.append(String(localized: "Back and Forward navigate in apps (⌘[ and ⌘])."))
        }
        let others = table.keys.filter { $0 != KnownControl.back && $0 != KnownControl.forward }.sorted()
        for cid in others {
            guard let action = table[cid] else { continue }
            let name = ControlDescriptor(cid: cid, model: target).name
            if action == .system(.missionControl) {
                parts.append(String(localized: "\(name) opens Mission Control."))
            } else {
                parts.append(String(localized: "\(name): \(action.title)."))
            }
        }
        if table[KnownControl.back] != nil, table[KnownControl.forward] == nil {
            parts.insert(String(localized: "\(ControlDescriptor(cid: KnownControl.back, model: target).name): \(ButtonAction.system(.navigateBack).title)."), at: 0)
        } else if table[KnownControl.forward] != nil, table[KnownControl.back] == nil {
            parts.insert(String(localized: "\(ControlDescriptor(cid: KnownControl.forward, model: target).name): \(ButtonAction.system(.navigateForward).title)."), at: 0)
        }
        return parts.joined(separator: " ")
    }

    /// Changes only the target model's global table; no other model's setup is touched.
    private func apply(_ choice: Choice) {
        var profiles = model.profiles(for: target)
        for (cid, action) in suggested {
            switch choice {
            case .suggested:
                profiles.global[cid] = action
            case .mouseDefaults:
                if profiles.global[cid] == action { profiles.global[cid] = .deviceDefault }
            }
        }
        model.setProfiles(profiles, for: target)
    }
}

/// Live feedback for the last button a mouse reported to Upright.
private struct TryItLine: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @ObservedObject var presses: PressFeed
    /// Presses from before this step are old news.
    @State private var shownSince = Date()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pressed == nil ? "hand.point.up.left" : "checkmark.circle.fill")
                .foregroundStyle(pressed == nil ? Color.secondary : Color.green)
                .accessibilityHidden(true)
            if let pressed {
                Text(description(of: pressed))
                    .id(pressed.date)
                    .transition(.opacity)
            } else if !devices.summary.anyPresent {
                Text("Connect a mouse to try a button.")
            } else {
                Text("Try it: press a remapped button.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.2), value: pressed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var pressed: AppModel.PressedControl? {
        presses.last.flatMap { $0.date >= shownSince ? $0 : nil }
    }

    /// For example "MX Master 3S: Back Button → ⌘[".
    private func description(of press: AppModel.PressedControl) -> String {
        let key = press.model ?? model.selectedModel
        let device = model.record(press.source)?.displayName ?? model.modelName(key)
        let control = ControlDescriptor(cid: press.cid, model: key).name
        let action = model.effectiveMappings(model: key)[press.cid].title
        return String(localized: "\(device): \(control) → \(action)")
    }
}

private struct ChoiceCard: View {
    let title: LocalizedStringKey
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
