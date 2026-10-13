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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "Connect your MX Vertical",
                message: "Plug in the Unifying receiver, connect the USB cable, or pair the mouse over Bluetooth. Then click a mouse button to wake it."
            )
            GroupBox {
                DeviceHeader()
                    .padding(6)
            }
            if devices.status == .accessDenied {
                InputMonitoringCallout()
            } else if devices.snapshot == nil {
                Text("You can continue without the mouse; Upright connects as soon as it appears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

            VStack(spacing: 8) {
                ChoiceCard(
                    title: "Keep mouse defaults",
                    detail: "Back and Forward work as mouse buttons 4 and 5; the top button changes pointer speed.",
                    isSelected: choice == .mouseDefaults
                ) { apply(.mouseDefaults) }
                ChoiceCard(
                    title: "Suggested",
                    detail: "Back and Forward navigate in apps (⌘[ and ⌘]); the top button opens Mission Control.",
                    isSelected: choice == .suggested
                ) { apply(.suggested) }
            }

            if choice == .suggested, !permissions.isAccessibilityTrusted {
                Label("Back and Forward start working once Accessibility access is allowed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TryItLine()
        }
    }

    private var choice: Choice {
        Self.suggested.allSatisfy { model.mappings[$0.key] == $0.value } ? .suggested : .mouseDefaults
    }

    private func apply(_ choice: Choice) {
        var mappings = model.mappings
        for (cid, action) in Self.suggested {
            switch choice {
            case .suggested:
                mappings[cid] = action
            case .mouseDefaults:
                if mappings[cid] == action { mappings[cid] = .deviceDefault }
            }
        }
        model.mappings = mappings
    }

    /// Back/Forward navigate, the top button opens Mission Control (what Upright 1.x shipped with).
    private static var suggested: [UInt16: ButtonAction] { ButtonMappings.legacyDefaults.mappedControls }
}

/// Live feedback for the last button the mouse reported to Upright.
private struct TryItLine: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    /// Presses from before this step are old news.
    @State private var shownSince = Date()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pressed == nil ? "hand.point.up.left" : "checkmark.circle.fill")
                .foregroundStyle(pressed == nil ? Color.secondary : Color.green)
                .accessibilityHidden(true)
            if let pressed {
                Text("\(ControlDescriptor(cid: pressed.cid).name): \(model.effectiveMappings[pressed.cid].title)")
                    .id(pressed.date)
                    .transition(.opacity)
            } else if devices.snapshot == nil {
                Text("Connect the mouse to try a button.")
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
        model.lastPressedControl.flatMap { $0.date >= shownSince ? $0 : nil }
    }
}

private struct ChoiceCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
                    Text(detail)
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
