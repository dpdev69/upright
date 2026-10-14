import AppKit
import ApplicationServices
import IOKit.hid
import os

/// Tracks the two privacy permissions Upright can need.
///
/// - Accessibility: required to post the keyboard shortcuts, media keys and clicks that
///   buttons are mapped to.
/// - Input Monitoring: only needed if macOS refuses to open the mouse's HID++ interface.
///
/// In Demo Mode (`AppEnvironment.demo`) both read as granted, nothing is polled and nothing is
/// ever asked: no system prompt, no System Settings, no `tccutil`, no IOKit access check.
@MainActor
final class PermissionsMonitor: ObservableObject {
    enum InputMonitoringStatus: Equatable {
        case granted
        case denied
        case notDetermined
    }

    @Published private(set) var isAccessibilityTrusted: Bool
    @Published private(set) var inputMonitoring: InputMonitoringStatus
    /// Accessibility was granted on an earlier run but isn't now. Usually the app was rebuilt or
    /// moved and macOS still lists the old copy as allowed; resetting the entry fixes it.
    @Published private(set) var accessibilityGrantIsStale = false
    @Published private(set) var isResettingAccessibility = false
    /// Set while the mouse is blocked for lack of Input Monitoring; with a window open, a grant is then noticed within a second.
    /// Input Monitoring is optional and usually never decided, which alone doesn't warrant fast polling.
    var needsInputMonitoring = false {
        didSet { if needsInputMonitoring != oldValue { reschedulePollingIfNeeded() } }
    }

    private static let wasTrustedKey = "accessibilityWasTrusted"
    private static let promptShownKey = "accessibilityPromptShown"
    private static let pollWhileWaiting: TimeInterval = 1
    private static let pollWhenIdle: TimeInterval = 60
    /// How long asking for a permission keeps polling fast with no window open.
    private static let fastPollWindow: TimeInterval = 120

    private let defaults: UserDefaults
    private let environment: AppEnvironment
    private let launcher = ProcessLauncher()
    private let logger = Logger(subsystem: "Upright", category: "Permissions")
    private var timer: Timer?
    /// Fast polling continues until then (set when Upright asks for a permission).
    private var fastPollUntil: Date?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, environment: AppEnvironment = .live) {
        self.defaults = defaults
        self.environment = environment
        if environment.checksPermissions {
            isAccessibilityTrusted = AXIsProcessTrusted()
            inputMonitoring = .notDetermined
            refresh()
        } else {
            isAccessibilityTrusted = true
            inputMonitoring = .granted
        }
    }

    /// Starts watching for changes. There is no public change notification for these
    /// permissions, so this polls (see `pollInterval`) and also checks when Upright becomes
    /// active and when the Mac wakes.
    func start() {
        guard environment.checksPermissions, observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
        schedulePolling()
    }

    func refresh() {
        guard environment.checksPermissions else { return }
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        if trusted, !defaults.bool(forKey: Self.wasTrustedKey) {
            defaults.set(true, forKey: Self.wasTrustedKey)
        }
        let stale = !trusted && defaults.bool(forKey: Self.wasTrustedKey)
        if stale != accessibilityGrantIsStale { accessibilityGrantIsStale = stale }

        let access: InputMonitoringStatus
        switch HIDDeviceMonitor.inputMonitoringAccess {
        case kIOHIDAccessTypeGranted: access = .granted
        case kIOHIDAccessTypeDenied: access = .denied
        default: access = .notDetermined
        }
        if access != inputMonitoring { inputMonitoring = access }

        reschedulePollingIfNeeded()
    }

    /// Called when one of Upright's windows opens or closes (the activation policy changes).
    func windowsChanged() {
        reschedulePollingIfNeeded()
    }

    /// Every second while a grant is awaited and the user is likely granting it right now: one
    /// of Upright's windows is open (the app is a regular app only then), or Upright asked for a
    /// permission in the last two minutes. Once a minute otherwise.
    private var pollInterval: TimeInterval {
        let waitingForGrant = !isAccessibilityTrusted || (needsInputMonitoring && inputMonitoring != .granted)
        let windowOpen = NSApp?.activationPolicy() == .regular
        let recentlyAsked = fastPollUntil.map { Date() < $0 } ?? false
        return waitingForGrant && (windowOpen || recentlyAsked) ? Self.pollWhileWaiting : Self.pollWhenIdle
    }

    private func reschedulePollingIfNeeded() {
        if timer != nil, timer?.timeInterval != pollInterval { schedulePolling() }
    }

    /// Polls fast for a while after Upright sends the user to grant something.
    private func pollFastForAWhile() {
        fastPollUntil = Date().addingTimeInterval(Self.fastPollWindow)
        if timer != nil { schedulePolling() }
    }

    private func schedulePolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = pollInterval / 5
        // .common keeps polling while a menu is open or a slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Accessibility

    /// Shows the system prompt the first time; after that macOS ignores the prompt request,
    /// so this opens the Accessibility list instead. Never both at once.
    func requestAccessibility() {
        guard environment.checksPermissions else { return }
        pollFastForAWhile()
        if !defaults.bool(forKey: Self.promptShownKey) {
            promptForAccessibility()
        } else if !AXIsProcessTrusted() {
            openAccessibilitySettings()
        }
        refresh()
    }

    func openAccessibilitySettings() {
        guard environment.checksPermissions else { return }
        pollFastForAWhile()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Removes Upright's (possibly stale) Accessibility entry, then asks for access again.
    func resetAccessibilityPermission() {
        guard environment.checksPermissions, !isResettingAccessibility, let bundleID = Bundle.main.bundleIdentifier else { return }
        isResettingAccessibility = true
        pollFastForAWhile()
        launcher.run("/usr/bin/tccutil", arguments: ["reset", "Accessibility", bundleID]) { [weak self] status in
            guard let self else { return }
            self.isResettingAccessibility = false
            if status != 0 {
                self.logger.error("tccutil reset Accessibility exited with \(status)")
            }
            self.defaults.set(false, forKey: Self.wasTrustedKey)
            self.promptForAccessibility()
            self.refresh()
        }
    }

    private func promptForAccessibility() {
        defaults.set(true, forKey: Self.promptShownKey)
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Input Monitoring

    /// Shows the system prompt while access is undecided; otherwise opens the Input Monitoring list.
    func requestInputMonitoring() {
        guard environment.checksPermissions else { return }
        pollFastForAWhile()
        refresh()
        if inputMonitoring == .notDetermined {
            HIDDeviceMonitor.requestInputMonitoringAccess()
        } else if inputMonitoring == .denied {
            openInputMonitoringSettings()
        }
        refresh()
    }

    func openInputMonitoringSettings() {
        guard environment.checksPermissions else { return }
        pollFastForAWhile()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
