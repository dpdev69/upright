import Combine
import SwiftUI

/// App-wide state: the user's mappings, the remapping switch, and the services that act on them.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private static let remappingEnabledKey = "remappingEnabled"

    @Published var mappings: ButtonMappings {
        didSet {
            mappings.save(to: defaults)
            engine.mappings = mappings
            syncDiversion()
        }
    }

    @Published var isRemappingEnabled: Bool {
        didSet {
            defaults.set(isRemappingEnabled, forKey: Self.remappingEnabledKey)
            engine.isEnabled = isRemappingEnabled
            syncDiversion()
        }
    }

    @Published var selectedPane: SettingsPane = .buttons

    let devices: DeviceManager
    let permissions: PermissionsMonitor
    let loginItem: LoginItemController

    private let engine: RemapEngine
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mappings = ButtonMappings.load(from: defaults)
        let enabled = defaults.object(forKey: Self.remappingEnabledKey) as? Bool ?? true
        self.mappings = mappings
        self.isRemappingEnabled = enabled
        devices = DeviceManager()
        permissions = PermissionsMonitor()
        loginItem = LoginItemController()
        engine = RemapEngine(mappings: mappings, performer: SystemActionPerformer())
        engine.isEnabled = enabled
    }

    func start() {
        guard !started else { return }
        started = true

        devices.onButtonEvent = { [weak self] event in self?.engine.handle(event) }
        permissions.$isAccessibilityTrusted
            .removeDuplicates()
            .sink { [weak self] _ in
                // The publisher fires before the property updates; read the new value on the next turn.
                Task { @MainActor in self?.syncDiversion() }
            }
            .store(in: &cancellables)

        permissions.$inputMonitoring
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                guard status == .granted else { return }
                Task { @MainActor in self?.devices.reconnect() }
            }
            .store(in: &cancellables)

        syncDiversion()
        devices.start()
    }

    func binding(for cid: UInt16) -> Binding<ButtonAction> {
        Binding(
            get: { self.mappings[cid] },
            set: { self.mappings[cid] = $0 }
        )
    }

    func restoreDefaultMappings() {
        mappings = .defaults
    }

    /// True when at least one mapping needs Accessibility to post events.
    var needsAccessibility: Bool {
        mappings.mappedControls.values.contains { $0.requiresAccessibility }
    }

    var isMissingAccessibility: Bool {
        needsAccessibility && !permissions.isAccessibilityTrusted
    }

    private func syncDiversion() {
        let cids = isRemappingEnabled
            ? mappings.divertedControls(accessibilityGranted: permissions.isAccessibilityTrusted)
            : []
        devices.setDesiredDiversion(cids)
    }
}
