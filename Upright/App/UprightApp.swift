import AppKit
import SwiftUI

@main
@MainActor
struct UprightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .environmentObject(model.permissions)
                .environmentObject(model.settings)
        } label: {
            MenuBarLabel(devices: model.devices, settings: model.settings)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var devices: DeviceManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        let icon = Image(systemName: devices.snapshot == nil ? "computermouse" : "computermouse.fill")
        Group {
            if settings.showBatteryInMenuBar, let battery = devices.snapshot?.battery {
                // One Text, so the menu bar shows both the icon and the level.
                Text(icon) + Text(verbatim: " " + battery.levelText)
            } else {
                icon
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// For example "Upright, connected, battery 80%".
    private var accessibilityText: String {
        var parts = ["Upright"]
        switch devices.status {
        case .connected: parts.append(String(localized: "connected"))
        case .asleep: parts.append(String(localized: "mouse asleep"))
        case .probing, .waiting: parts.append(String(localized: "connecting"))
        case .searching: parts.append(String(localized: "not connected"))
        case .accessDenied: parts.append(String(localized: "needs Input Monitoring access"))
        case .failed: parts.append(String(localized: "connection problem"))
        @unknown default: break
        }
        if let battery = devices.snapshot?.battery {
            parts.append(battery.accessibilityDescription)
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasLaunchedKey = "hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()

        // Read by MappingStore to tell upgrades from fresh installs.
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
        if !AppModel.shared.settings.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingWindowController.shared.isVisible {
            OnboardingWindowController.shared.show()
        } else {
            SettingsWindowController.shared.show()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.devices.shutdown()
    }
}
