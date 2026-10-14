import AppKit
import SwiftUI

/// The entry point. Demo Mode is configured first, so `AppModel.shared` is built for the right
/// environment (simulated mice and their own defaults with `--demo`).
///
/// `--export-snapshots <dir>` never starts the SwiftUI app: no scene, no status item (whose
/// visibility AppKit would save in the user's defaults), no windows and, as a menu bar app, no
/// Dock icon. It renders the UI offscreen and quits.
@main
@MainActor
enum UprightLauncher {
    static func main() {
        DemoMode.configure(arguments: CommandLine.arguments)
        if let directory = DemoMode.exportDirectory {
            SnapshotExportRunner.run(to: directory)
        } else {
            UprightApp.main()
        }
    }
}

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasLaunchedKey = "hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.start()
        // Read by MappingStore to tell upgrades from fresh installs. Demo Mode writes its own suite.
        model.defaults.set(true, forKey: Self.hasLaunchedKey)
        if !model.settings.hasCompletedOnboarding {
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

/// `--demo --export-snapshots <dir>`: a bare NSApplication (no SwiftUI scene) that runs the
/// simulated fleet, renders the UI offscreen into the directory (`SnapshotExporter`), then
/// exits 0 on success or 1 on failure.
@MainActor
enum SnapshotExportRunner {
    private static var delegate: ExportDelegate?

    static func run(to directory: URL) {
        let app = NSApplication.shared
        let delegate = ExportDelegate(directory: directory)
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    private final class ExportDelegate: NSObject, NSApplicationDelegate {
        let directory: URL

        init(directory: URL) {
            self.directory = directory
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let model = AppModel.shared
            model.start()
            let directory = directory
            Task { @MainActor in
                var status: Int32 = 0
                do {
                    try await SnapshotExporter.run(model: model, to: directory)
                } catch {
                    FileHandle.standardError.write(Data("Snapshot export failed: \(error)\n".utf8))
                    status = 1
                }
                model.devices.shutdown()
                exit(status)
            }
        }
    }
}
