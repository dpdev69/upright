import AppKit
import SwiftUI

/// Hosts the settings UI in an AppKit window so it can be opened on demand from the menu bar
/// (and on first launch) without SwiftUI reopening it every time the app starts at login.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(pane: SettingsPane? = nil) {
        let model = AppModel.shared
        if let pane { model.selectedPane = pane }

        let window = self.window ?? makeWindow(model: model)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let root = SettingsView()
            .environmentObject(model)
            .environmentObject(model.devices)
            .environmentObject(model.permissions)
            .environmentObject(model.loginItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 780, height: 560))
        window.title = "Upright"
        window.toolbar = NSToolbar(identifier: "UprightSettings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("UprightSettings") {
            window.center()
        }
        window.setFrameAutosaveName("UprightSettings")
        window.delegate = self
        return window
    }
}
