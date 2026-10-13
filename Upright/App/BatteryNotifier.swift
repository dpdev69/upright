import Foundation
import UserNotifications
import os

/// Posts a notification when a mouse battery gets low (15%) and again when critical (5%),
/// once each per discharge and per mouse. See `BatteryAlertPolicy` for when it re-arms.
///
/// Every connected mouse has its own policy, keyed by its runtime `DeviceAddress`. A mouse with a
/// stable `DeviceID` also leaves its policy behind when its endpoint goes away (sleep, unplug,
/// re-pair on another slot), so coming back doesn't repeat an alert for the same discharge.
@MainActor
final class BatteryNotifier: NSObject {
    /// Readings are always tracked; notifications are posted only while this is on.
    var isEnabled: Bool

    /// Policies of the endpoints that exist now.
    private var policies: [DeviceAddress: BatteryAlertPolicy] = [:]
    /// The last policy state of every stable unit seen, used to seed a new endpoint of that unit.
    private var remembered: [DeviceID: BatteryAlertPolicy] = [:]
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

    /// Feeds the latest reading of one mouse. `deviceName` is its display name (nickname first)
    /// and goes into the notification text. Nil (no reading) is ignored, so a reconnect doesn't
    /// repeat an alert for the same discharge. A transient or missing `deviceID` is fine: the
    /// policy then lives only as long as the address.
    func update(address: DeviceAddress, deviceID: DeviceID?, deviceName: String, battery: BatteryStatus?) {
        guard let battery else { return }
        let stableID = deviceID.flatMap { $0.isStable ? $0 : nil }
        var policy = policies[address] ?? stableID.flatMap { remembered[$0] } ?? BatteryAlertPolicy()
        let alert = policy.update(battery)
        policies[address] = policy
        if let stableID { remembered[stableID] = policy }
        guard let alert else { return }
        logger.notice("\(deviceName, privacy: .private) battery at \(battery.percentage)%, alert: \(String(describing: alert), privacy: .public)")
        guard isEnabled else { return }
        post(alert, deviceName: deviceName, identifier: Self.notificationIdentifier(address: address, deviceID: stableID))
    }

    /// Drops the policy of an endpoint that went away. A stable unit keeps its remembered state.
    func endpointRemoved(_ address: DeviceAddress) {
        policies[address] = nil
    }

    func endpointsRemoved(_ addresses: [DeviceAddress]) {
        addresses.forEach(endpointRemoved)
    }

    /// Drops the policies of every address not in `live`, for callers that diff the record list
    /// instead of listening for removals.
    func prune(keeping live: Set<DeviceAddress>) {
        policies = policies.filter { live.contains($0.key) }
    }

    /// Compatibility for the single-mouse caller in `AppModel` until it passes addresses.
    func update(battery: BatteryStatus?, deviceName: String) {
        update(address: .unassigned, deviceID: nil, deviceName: deviceName, battery: battery)
    }

    /// `upright.battery.<DeviceID>` for a stable unit, else `upright.battery.<link>.<index>`.
    /// A critical alert replaces the low one of the same mouse in Notification Center.
    static func notificationIdentifier(address: DeviceAddress, deviceID: DeviceID?) -> String {
        if let deviceID, deviceID.isStable { return "upright.battery.\(deviceID.rawValue)" }
        return "upright.battery.\(address.link).\(address.index)"
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

    private func post(_ alert: BatteryAlertPolicy.Alert, deviceName: String, identifier: String) {
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
        content.threadIdentifier = "upright.battery"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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
