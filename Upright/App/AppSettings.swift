import Combine
import Foundation
import os

/// App preferences outside the button mappings, saved to UserDefaults on every change.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let scrollSettings = "scrollSettings"
        static let batteryAlertsEnabled = "batteryAlertsEnabled"
        static let showBatteryInMenuBar = "showBatteryInMenuBar"
        static let preferredDPI = "preferredDPI"
        static let dpiPresets = "dpiPresets"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    static let defaultDPIPresets = [800, 1200, 1600, 2400]

    /// Wheel reversal, speed and smooth scrolling. Default: nothing changed.
    @Published var scrollSettings: ScrollSettings {
        didSet {
            guard scrollSettings != oldValue else { return }
            saveScrollSettings()
        }
    }

    /// Notify at 15% and 5%. Notification permission is requested when this is turned on, or
    /// before the first alert if it was never turned off.
    @Published var batteryAlertsEnabled: Bool {
        didSet { defaults.set(batteryAlertsEnabled, forKey: Key.batteryAlertsEnabled) }
    }

    /// Show "NN%" next to the menu bar icon while a battery level is known.
    @Published var showBatteryInMenuBar: Bool {
        didSet { defaults.set(showBatteryInMenuBar, forKey: Key.showBatteryInMenuBar) }
    }

    /// The pointer speed to apply when the mouse connects; nil leaves the mouse's own setting.
    @Published var preferredDPI: Int? {
        didSet {
            if let preferredDPI, DeviceAction.dpiRange.contains(preferredDPI) {
                defaults.set(preferredDPI, forKey: Key.preferredDPI)
            } else {
                defaults.removeObject(forKey: Key.preferredDPI)
            }
        }
    }

    /// The speeds "Cycle Pointer Speed" steps through, ascending, without duplicates.
    @Published var dpiPresets: [Int] {
        didSet {
            // Assigning inside didSet doesn't re-run the observer.
            let clean = Self.sanitized(dpiPresets)
            if clean != dpiPresets { dpiPresets = clean }
            defaults.set(clean, forKey: Key.dpiPresets)
        }
    }

    /// The first-run window was finished or dismissed. Upgrading users never see it.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "Upright", category: "Settings")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scrollSettings = Self.loadScrollSettings(defaults)
        batteryAlertsEnabled = defaults.object(forKey: Key.batteryAlertsEnabled) as? Bool ?? true
        showBatteryInMenuBar = defaults.object(forKey: Key.showBatteryInMenuBar) as? Bool ?? false
        let dpi = defaults.object(forKey: Key.preferredDPI) as? Int
        preferredDPI = dpi.flatMap { DeviceAction.dpiRange.contains($0) ? $0 : nil }
        let presets = Self.sanitized(defaults.array(forKey: Key.dpiPresets) as? [Int] ?? [])
        dpiPresets = presets.isEmpty ? Self.defaultDPIPresets : presets
        if let completed = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool {
            hasCompletedOnboarding = completed
        } else {
            // Decided once, on the first launch of this version, before the app marks itself launched:
            // anyone who ran an earlier version already has a setup and skips onboarding.
            let isUpgrade = MappingStore(defaults: defaults).hasPriorLaunch
            hasCompletedOnboarding = isUpgrade
            defaults.set(isUpgrade, forKey: Key.hasCompletedOnboarding)
        }
    }

    /// Puts scrolling back to how macOS does it.
    func resetScrollSettings() {
        scrollSettings = .default
    }

    private static func sanitized(_ presets: [Int]) -> [Int] {
        Array(Set(presets.filter { DeviceAction.dpiRange.contains($0) })).sorted()
    }

    private static func loadScrollSettings(_ defaults: UserDefaults) -> ScrollSettings {
        guard let data = defaults.data(forKey: Key.scrollSettings) else { return .default }
        return (try? JSONDecoder().decode(ScrollSettings.self, from: data)) ?? .default
    }

    private func saveScrollSettings() {
        do {
            defaults.set(try JSONEncoder().encode(scrollSettings), forKey: Key.scrollSettings)
        } catch {
            logger.error("Saving scroll settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
