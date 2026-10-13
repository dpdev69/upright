import Foundation

/// A HID++ 2.0 device reachable through a client at a given device index.
/// Caches feature-ID → feature-index lookups done through the root feature.
@MainActor
public final class HIDPPDevice {
    public let client: HIDPPClient
    public let index: UInt8
    private var featureIndices: [UInt16: UInt8] = [:]

    public init(client: HIDPPClient, index: UInt8) {
        self.client = client
        self.index = index
    }

    // MARK: Root feature (always at index 0)

    /// Root.getProtocolVersion. HID++ 1.0 devices reject it with "invalid sub-ID".
    public func protocolVersion(timeout: TimeInterval? = nil) async throws -> (major: UInt8, minor: UInt8) {
        let ping: UInt8 = 0x5A
        do {
            let reply = try await client.call(deviceIndex: index, featureIndex: 0, function: 1, parameters: [0, 0, ping], timeout: timeout)
            return (reply[0], reply[1])
        } catch HIDPPError.hidpp10(0x01) {
            return (1, 0)
        }
    }

    /// Root.getFeature. Returns nil when the device lacks the feature.
    public func featureIndex(for feature: UInt16) async throws -> UInt8? {
        if feature == HIDPPFeature.root.rawValue { return 0 }
        if let cached = featureIndices[feature] { return cached == 0 ? nil : cached }
        let reply = try await client.call(deviceIndex: index, featureIndex: 0, function: 0, parameters: feature.bigEndianBytes)
        featureIndices[feature] = reply[0]
        return reply[0] == 0 ? nil : reply[0]
    }

    public func featureIndex(for feature: HIDPPFeature) async throws -> UInt8? {
        try await featureIndex(for: feature.rawValue)
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

    /// Battery via Unified Battery (0x1004) or Battery Status (0x1000), whichever exists.
    public func battery() async -> BatteryStatus? {
        if (try? await featureIndex(for: .unifiedBattery)) != nil,
           let reply = try? await call(.unifiedBattery, function: 1) {
            return BatteryStatus(unifiedBatteryParameters: reply)
        }
        if (try? await featureIndex(for: .batteryStatus)) != nil,
           let reply = try? await call(.batteryStatus, function: 0) {
            return BatteryStatus(batteryStatusParameters: reply)
        }
        return nil
    }
}

public struct BatteryStatus: Hashable, Sendable {
    public var percentage: Int
    public var isCharging: Bool

    public init(percentage: Int, isCharging: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
    }

    /// 0x1000 getBatteryLevelStatus / broadcast: [level %, next level %, status].
    init?(batteryStatusParameters p: [UInt8]) {
        guard p.count >= 3, p[0] > 0 else { return nil }
        percentage = Int(min(p[0], 100))
        isCharging = [1, 2, 4].contains(p[2])
    }

    /// 0x1004 getStatus / broadcast: [state of charge %, level flags, charging status, external power].
    init?(unifiedBatteryParameters p: [UInt8]) {
        guard p.count >= 3 else { return nil }
        percentage = Int(min(p[0], 100))
        isCharging = [1, 2].contains(p[2])
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
