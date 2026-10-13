import Foundation

/// A HID++ 2.0 device reachable through a client at a given device index.
/// Caches feature-ID → feature-index (and version) lookups done through the root feature.
@MainActor
public final class HIDPPDevice {
    public let client: HIDPPClient
    public let index: UInt8
    private var featureIndices: [UInt16: UInt8] = [:]
    private var featureVersions: [UInt16: UInt8] = [:]

    public init(client: HIDPPClient, index: UInt8) {
        self.client = client
        self.index = index
    }

    // MARK: Root feature (always at index 0)

    /// Root.getProtocolVersion. HID++ 1.0 devices reject it with "invalid sub-ID".
    /// The reply echoes a ping byte; a mismatch means a late reply to an earlier ping, so ask again.
    public func protocolVersion(timeout: TimeInterval? = nil) async throws -> (major: UInt8, minor: UInt8) {
        for _ in 0..<2 {
            let ping = Self.nextPing()
            do {
                let reply = try await client.call(deviceIndex: index, featureIndex: 0, function: 1, parameters: [0, 0, ping], timeout: timeout)
                if reply[2] == ping { return (reply[0], reply[1]) }
            } catch HIDPPError.hidpp10(0x01) {
                return (1, 0)
            }
        }
        throw HIDPPError.malformedResponse
    }

    private static var lastPing: UInt8 = 0x59

    private static func nextPing() -> UInt8 {
        lastPing = lastPing == 0xFF ? 1 : lastPing + 1
        return lastPing
    }

    /// Root.getFeature: [index, type, version]. Returns nil when the device lacks the feature.
    public func featureIndex(for feature: UInt16) async throws -> UInt8? {
        if feature == HIDPPFeature.root.rawValue { return 0 }
        if let cached = featureIndices[feature] { return cached == 0 ? nil : cached }
        let reply = try await client.call(deviceIndex: index, featureIndex: 0, function: 0, parameters: feature.bigEndianBytes)
        featureIndices[feature] = reply[0]
        if reply[0] != 0 { featureVersions[feature] = reply[2] }
        return reply[0] == 0 ? nil : reply[0]
    }

    public func featureIndex(for feature: HIDPPFeature) async throws -> UInt8? {
        try await featureIndex(for: feature.rawValue)
    }

    /// The feature's version, from the feature table if it was read, else Root.getFeature.
    /// Nil when the device lacks the feature.
    public func featureVersion(for feature: HIDPPFeature) async throws -> UInt8? {
        guard try await featureIndex(for: feature) != nil else { return nil }
        return featureVersions[feature.rawValue] ?? 0
    }

    /// Calls `function` on `feature`, resolving its index first.
    public func call(_ feature: HIDPPFeature, function: UInt8, parameters: [UInt8] = []) async throws -> [UInt8] {
        guard let featureIndex = try await featureIndex(for: feature) else {
            throw HIDPPError.featureNotSupported(feature.rawValue)
        }
        return try await client.call(deviceIndex: index, featureIndex: featureIndex, function: function, parameters: parameters)
    }

    // MARK: Common features

    /// Feature Set (0x0001): the full feature table, root included.
    public func featureTable() async throws -> [FeatureEntry] {
        guard let setIndex = try await featureIndex(for: .featureSet) else { return [] }
        let count = try await client.call(deviceIndex: index, featureIndex: setIndex, function: 0)[0]
        var entries = [FeatureEntry(index: 0, featureID: 0, version: 0, flags: 0)]
        if count > 0 {
            for i in 1...count {
                let reply = try await client.call(deviceIndex: index, featureIndex: setIndex, function: 1, parameters: [i])
                let id = reply.uint16(at: 0)
                entries.append(FeatureEntry(index: i, featureID: id, version: reply[3], flags: reply[2]))
                featureIndices[id] = i
                featureVersions[id] = reply[3]
            }
        }
        return entries
    }

    /// Device Name (0x0005): getDeviceNameCount, then getDeviceName in 16-byte chunks.
    public func name() async throws -> String {
        let length = Int(try await call(.deviceName, function: 0)[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            let chunk = try await call(.deviceName, function: 1, parameters: [UInt8(bytes.count)])
            let take = min(chunk.count, length - bytes.count)
            if take <= 0 { break }
            bytes += chunk.prefix(take)
        }
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Battery via Unified Battery (0x1004), Battery Status (0x1000) or Battery Voltage (0x1001),
    /// the first that exists. `previous` fills in the level when a charging 0x1000 device reports level 0.
    public func battery(previous: BatteryStatus? = nil) async -> BatteryStatus? {
        if (try? await featureIndex(for: .unifiedBattery)) != nil {
            // getCapabilities: [supported level flags, flags]; flags bit 1 = state of charge (%) supported.
            let capabilities = try? await call(.unifiedBattery, function: 0)
            let reportsPercentage = capabilities.map { $0[1] & 0x02 != 0 } ?? true
            if let reply = try? await call(.unifiedBattery, function: 1) {
                return BatteryStatus(unifiedBatteryParameters: reply, reportsPercentage: reportsPercentage)
            }
        }
        if (try? await featureIndex(for: .batteryStatus)) != nil,
           let reply = try? await call(.batteryStatus, function: 0) {
            return BatteryStatus(batteryStatusParameters: reply, previous: previous)
        }
        if (try? await featureIndex(for: .batteryVoltage)) != nil,
           let reply = try? await call(.batteryVoltage, function: 0) {
            return BatteryStatus(batteryVoltageParameters: reply)
        }
        return nil
    }
}

public struct BatteryStatus: Hashable, Sendable {
    public var percentage: Int
    /// Charging, or full while on external power.
    public var isCharging: Bool
    /// The device reports only a coarse level (critical / low / good / full), not a percentage.
    public var isApproximate: Bool

    public init(percentage: Int, isCharging: Bool, isApproximate: Bool = false) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isApproximate = isApproximate
    }

    /// 0x1000 getBatteryLevelStatus / broadcast: [level %, next level %, status].
    /// Status: 0 discharging, 1 recharging, 2 almost full, 3 full (on power), 4 slow recharge, 5-7 errors.
    /// Some devices report level 0 while charging; the previous level is kept then.
    init?(batteryStatusParameters p: [UInt8], previous: BatteryStatus? = nil) {
        guard p.count >= 3 else { return nil }
        isCharging = [1, 2, 3, 4].contains(p[2])
        isApproximate = false
        if p[0] > 0 {
            percentage = Int(min(p[0], 100))
        } else if p[2] == 3 {
            percentage = 100
        } else if let previous, isCharging {
            percentage = previous.percentage
            isApproximate = previous.isApproximate
        } else {
            return nil
        }
    }

    /// 0x1004 getStatus / broadcast: [state of charge %, level flags, charging status, external power].
    /// Level flags: 1 critical, 2 low, 4 good, 8 full. Charging status: 0 discharging, 1 charging,
    /// 2 slow charging, 3 complete (full, on power), 4 error.
    init?(unifiedBatteryParameters p: [UInt8], reportsPercentage: Bool = true) {
        guard p.count >= 3 else { return nil }
        isCharging = [1, 2, 3].contains(p[2])
        if reportsPercentage, p[0] > 0 {
            percentage = Int(min(p[0], 100))
            isApproximate = false
        } else if let level = Self.percentage(forLevelFlags: p[1]) {
            percentage = level
            isApproximate = true
        } else if p[2] == 3 {
            percentage = 100
            isApproximate = true
        } else if reportsPercentage {
            percentage = 0
            isApproximate = false
        } else {
            return nil
        }
    }

    /// 0x1001 getBatteryVoltage / broadcast: [millivolts (2, big-endian), flags]. Flags bit 7 = on
    /// external power; then bits 0-1 give the charge state (0 charging, 1 full, 2 not charging).
    /// The level is estimated from the voltage, so it is marked approximate.
    init?(batteryVoltageParameters p: [UInt8]) {
        guard p.count >= 3 else { return nil }
        let millivolts = Int(p.uint16(at: 0))
        let flags = p[2]
        isCharging = flags & 0x80 != 0
        isApproximate = true
        if millivolts > 0 {
            percentage = Self.percentage(forMillivolts: millivolts)
        } else if isCharging, flags & 0x03 == 0x01 {
            percentage = 100
        } else {
            return nil
        }
    }

    /// Lithium-ion discharge curve, linearly interpolated (Solaar's
    /// `estimate_battery_level_percentage` table).
    static func percentage(forMillivolts millivolts: Int) -> Int {
        let curve: [(millivolts: Int, percentage: Int)] = [
            (4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60), (3811, 50),
            (3778, 40), (3751, 30), (3717, 20), (3671, 10), (3646, 5), (3579, 2), (3500, 0),
        ]
        guard let highest = curve.first, let lowest = curve.last else { return 0 }
        if millivolts >= highest.millivolts { return highest.percentage }
        if millivolts <= lowest.millivolts { return lowest.percentage }
        for (high, low) in zip(curve, curve.dropFirst()) where millivolts >= low.millivolts {
            let fraction = Double(millivolts - low.millivolts) / Double(high.millivolts - low.millivolts)
            return Int((Double(low.percentage) + fraction * Double(high.percentage - low.percentage)).rounded())
        }
        return 0
    }

    /// Representative percentages for 0x1004 level flags (the values Solaar uses).
    static func percentage(forLevelFlags flags: UInt8) -> Int? {
        if flags & 0x08 != 0 { return 90 }
        if flags & 0x04 != 0 { return 50 }
        if flags & 0x02 != 0 { return 20 }
        if flags & 0x01 != 0 { return 5 }
        return nil
    }

    public var symbolName: String {
        if isCharging { return "battery.100.bolt" }
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
