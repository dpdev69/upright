import Foundation
import UserNotifications
import os

/// Posts a notification when the mouse battery gets low (15%) and again when critical (5%),
/// once each per discharge. See `BatteryAlertPolicy` for when it re-arms.
@MainActor
final class BatteryNotifier: NSObject {
    /// Readings are always tracked; notifications are posted only while this is on.
    var isEnabled: Bool

    private var policy = BatteryAlertPolicy()
    private var center: UNUserNotificationCenter { .current() }
    private let logger = Logger(subsystem: "Upright", category: "Battery")

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        super.init()
    }

    /// Makes alerts show as banners even while Upright's settings window is in front.
    func start() {
        center.delegate = self
    }

    /// Feeds the latest reading of the connected mouse. Nil (no mouse or no reading) is ignored,
    /// so a reconnect doesn't repeat an alert for the same discharge.
    func update(battery: BatteryStatus?, deviceName: String) {
        guard let battery, let alert = policy.update(battery) else { return }
        logger.notice("Battery at \(battery.percentage)%, alert: \(String(describing: alert), privacy: .public)")
        guard isEnabled else { return }
        post(alert, deviceName: deviceName)
    }

    /// Shows the permission prompt if macOS hasn't asked yet. Call when the user turns alerts on.
    func requestAuthorization() {
        Task { _ = await authorize() }
    }

    private func authorize() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func post(_ alert: BatteryAlertPolicy.Alert, deviceName: String) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .low(let percentage):
            content.title = String(localized: "\(deviceName) battery is low")
            content.body = String(localized: "\(percentage)% left. Charge it soon.")
        case .critical(let percentage):
            content.title = String(localized: "\(deviceName) battery is almost empty")
            content.body = String(localized: "\(percentage)% left. Charge it now to keep using it.")
        }
        content.sound = .default
        // One identifier: a critical alert replaces the low one in Notification Center.
        let request = UNNotificationRequest(identifier: "upright.battery", content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            do {
                try await center.add(request)
            } catch {
                logger.error("Posting battery alert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension BatteryNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
