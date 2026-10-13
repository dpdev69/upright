import AppKit
import SwiftUI

/// Hosts the settings UI in an AppKit window so it can be opened on demand from the menu bar
/// without SwiftUI reopening it every time the app starts at login.
///
/// The window object (and its saved frame) lives for the whole run, but its SwiftUI content is
/// released when it closes, so nothing in it keeps updating in the background.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let autosaveName = "UprightSettings"
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show(pane: SettingsPane? = nil) {
        let model = AppModel.shared
        if let pane { model.selectedPane = pane }

        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            // Setting the content resizes the window to fit it; keep the saved frame instead.
            let frame = window.frame
            window.contentViewController = NSHostingController(rootView: Self.rootView(model: model))
            window.setFrame(frame, display: false)
        }
        AppActivation.windowWillShow(window)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    private static func rootView(model: AppModel) -> some View {
        SettingsView()
            .environmentObject(model)
            .environmentObject(model.devices)
            .environmentObject(model.permissions)
            .environmentObject(model.loginItem)
            .environmentObject(model.settings)
            .environmentObject(model.scroll)
            .environmentObject(model.frontmostMonitor)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Upright"
        window.toolbar = NSToolbar(identifier: "UprightSettings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        window.delegate = self
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        AppActivation.windowWillClose(window)
        // Drop the SwiftUI hierarchy after AppKit has finished closing the window.
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.isVisible else { return }
            window.contentViewController = nil
            window.contentView = NSView()
        }
    }
}

/// Upright is a menu bar app, but while one of its windows is open it shows in the Dock and the
/// ⌘-Tab switcher so the window can be found again.
@MainActor
enum AppActivation {
    private static var openWindows = Set<ObjectIdentifier>()

    static func windowWillShow(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        activate()
    }

    static func windowWillClose(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        if openWindows.isEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
