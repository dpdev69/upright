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
        } label: {
            MenuBarLabel(devices: model.devices)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var devices: DeviceManager

    var body: some View {
        Image(systemName: devices.snapshot == nil ? "computermouse" : "computermouse.fill")
            .accessibilityLabel("Upright")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasLaunchedKey = "hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            SettingsWindowController.shared.show(pane: .buttons)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.devices.shutdown()
    }
}
