import AppKit
import ServiceManagement

/// "Open at Login" via SMAppService (macOS 13+). No helper app or launch agent needed.
///
/// In Demo Mode (`AppEnvironment.managesLoginItem == false`) it never touches SMAppService: the
/// toggle flips a local, in-memory status so the UI still responds, and the user's real login
/// items are neither read nor changed (DEMO-MODE-SPEC: "no login item changes").
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    /// False in Demo Mode: SMAppService is never called.
    let isManaged: Bool

    /// Login items registered from outside /Applications (a build folder, Downloads, a translocated
    /// copy) break when that copy moves or is deleted, so the UI should warn.
    let isRunningFromApplicationsFolder: Bool

    private var observers: [NSObjectProtocol] = []

    init(environment: AppEnvironment, bundleURL: URL = Bundle.main.bundleURL) {
        isManaged = environment.managesLoginItem
        status = environment.managesLoginItem ? SMAppService.mainApp.status : .notRegistered
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
        guard isManaged else {
            // Demo Mode: pretend, so the toggle animates, but leave the real login item alone.
            status = enabled ? .enabled : .notRegistered
            return
        }
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
        guard isManaged else { return }
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    func openSystemSettings() {
        guard isManaged else { return }
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
