import Foundation

/// Decides when to warn about the mouse battery: once at the low level and once at the critical
/// level per discharge, re-armed by charging or by the level climbing back above `rearmAbove`.
/// The gap between the thresholds and `rearmAbove` absorbs readings that bounce by a percent or two.
public struct BatteryAlertPolicy: Hashable, Sendable {
    public enum Alert: Hashable, Sendable {
        case low(percentage: Int)
        case critical(percentage: Int)
    }

    public var lowThreshold: Int
    public var criticalThreshold: Int
    public var rearmAbove: Int

    private static let approximateGood = 50

    public private(set) var hasAlertedLow = false
    public private(set) var hasAlertedCritical = false

    public init(lowThreshold: Int = 15, criticalThreshold: Int = 5, rearmAbove: Int = 20) {
        self.lowThreshold = lowThreshold
        self.criticalThreshold = criticalThreshold
        self.rearmAbove = max(rearmAbove, lowThreshold)
    }

    /// Feeds one battery reading; returns the alert to show, if any.
    ///
    /// Approximate readings are coarse device levels (critical 5 / low 20 / good 50 / full 90).
    /// Their "low" level counts as low, since the device itself is saying so, and only "full" or
    /// charging re-arms: voltage-based levels can flicker between low and good.
    public mutating func update(percentage: Int, isCharging: Bool, isApproximate: Bool = false) -> Alert? {
        let rearmLevel = isApproximate ? max(rearmAbove, Self.approximateGood) : rearmAbove
        if isCharging || percentage > rearmLevel {
            hasAlertedLow = false
            hasAlertedCritical = false
            return nil
        }
        if percentage <= criticalThreshold {
            guard !hasAlertedCritical else { return nil }
            hasAlertedCritical = true
            hasAlertedLow = true
            return .critical(percentage: percentage)
        }
        let low = isApproximate ? max(lowThreshold, rearmAbove) : lowThreshold
        if percentage <= low, !hasAlertedLow {
            hasAlertedLow = true
            return .low(percentage: percentage)
        }
        return nil
    }

    public mutating func update(_ status: BatteryStatus) -> Alert? {
        update(percentage: status.percentage, isCharging: status.isCharging, isApproximate: status.isApproximate)
    }
}
