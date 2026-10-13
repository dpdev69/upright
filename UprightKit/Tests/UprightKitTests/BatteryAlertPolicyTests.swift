import XCTest
@testable import UprightKit

final class BatteryAlertPolicyTests: XCTestCase {
    private func feed(_ policy: inout BatteryAlertPolicy, _ levels: [Int], charging: Bool = false, approximate: Bool = false) -> [BatteryAlertPolicy.Alert] {
        levels.compactMap { policy.update(percentage: $0, isCharging: charging, isApproximate: approximate) }
    }

    func testAlertsOnceAtLowAndOnceAtCritical() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [40, 20, 16, 15, 14, 15, 13, 6, 5, 4, 5, 3, 1]), [.low(percentage: 15), .critical(percentage: 5)])
    }

    func testBouncingAroundThresholdDoesNotRepeat() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [15, 16, 15, 17, 14, 19, 15, 20, 15]), [.low(percentage: 15)])
    }

    func testRisingAboveRearmLevelRearms() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [15, 21, 15]), [.low(percentage: 15), .low(percentage: 15)])
    }

    func testChargingRearms() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [14, 5]), [.low(percentage: 14), .critical(percentage: 5)])
        XCTAssertNil(policy.update(percentage: 6, isCharging: true))
        XCTAssertFalse(policy.hasAlertedLow)
        XCTAssertEqual(feed(&policy, [12, 4]), [.low(percentage: 12), .critical(percentage: 4)])
    }

    func testStartingCriticalSkipsLowAlert() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [3, 10, 2]), [.critical(percentage: 3)])
    }

    func testNoAlertWhileCharging() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(feed(&policy, [10, 3], charging: true), [])
    }

    func testApproximateLevels() {
        var policy = BatteryAlertPolicy()
        // Device flags: good (50) → low (20), flickering back to good, then critical (5).
        XCTAssertEqual(feed(&policy, [50, 20], approximate: true), [.low(percentage: 20)])
        XCTAssertEqual(feed(&policy, [50, 20, 50, 5, 20, 5], approximate: true), [.critical(percentage: 5)])
        // Only "full" (or charging) re-arms.
        XCTAssertEqual(feed(&policy, [90, 20], approximate: true), [.low(percentage: 20)])
    }

    func testBatteryStatusOverload() {
        var policy = BatteryAlertPolicy()
        XCTAssertEqual(policy.update(BatteryStatus(percentage: 9, isCharging: false)), .low(percentage: 9))
    }
}
