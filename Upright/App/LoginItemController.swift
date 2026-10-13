import AppKit
import ServiceManagement

/// "Open at Login" via SMAppService (macOS 13+). No helper app or launch agent needed.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    /// Login items registered from outside /Applications (a build folder, Downloads, a translocated
    /// copy) break when that copy moves or is deleted, so the UI should warn.
    let isRunningFromApplicationsFolder: Bool

    private var observers: [NSObjectProtocol] = []

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isRunningFromApplicationsFolder = Self.isInApplicationsFolder(bundleURL)
        // The user can change this in System Settings while Upright is running.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return false }
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return folders.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
