import AppKit

/// The app whose per-app profile applies.
struct FrontmostApp: Equatable {
    let bundleID: String
    let name: String
}

/// Follows the frontmost application. Upright itself becoming frontmost (to open Settings or the
/// menu) is ignored, so the previous app's profile stays in effect — and stays editable.
@MainActor
final class FrontmostAppMonitor: ObservableObject {
    @Published private(set) var current: FrontmostApp?

    private let ownBundleID = Bundle.main.bundleIdentifier
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let info = app.flatMap(Self.info(for:))
            Task { @MainActor in self?.apply(info) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func update(_ app: NSRunningApplication?) {
        apply(app.flatMap(Self.info(for:)))
    }

    private func apply(_ app: FrontmostApp?) {
        if let app, app.bundleID == ownBundleID { return }
        if app != current { current = app }
    }

    private nonisolated static func info(for app: NSRunningApplication) -> FrontmostApp? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return FrontmostApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}
