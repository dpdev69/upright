import AppKit
import ApplicationServices
import IOKit.hid

/// Tracks the two privacy permissions Upright can need.
///
/// - Accessibility: required to post the keyboard shortcuts, media keys and clicks that
///   buttons are mapped to.
/// - Input Monitoring: only needed if macOS refuses to open the mouse's HID++ interface.
@MainActor
final class PermissionsMonitor: ObservableObject {
    enum InputMonitoringStatus: Equatable {
        case granted
        case denied
        case notDetermined
    }

    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoring: InputMonitoringStatus = .notDetermined

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        // There is no public change notification for these permissions, so poll gently.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }

        let access: InputMonitoringStatus
        switch HIDDeviceMonitor.inputMonitoringAccess {
        case kIOHIDAccessTypeGranted: access = .granted
        case kIOHIDAccessTypeDenied: access = .denied
        default: access = .notDetermined
        }
        if access != inputMonitoring { inputMonitoring = access }
    }

    /// Shows the system prompt (first time only) and opens the Accessibility list.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openAccessibilitySettings()
        }
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        if !HIDDeviceMonitor.requestInputMonitoringAccess() {
            openInputMonitoringSettings()
        }
        refresh()
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
