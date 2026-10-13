import Foundation

// MARK: Pointer speed (0x2201 ADJUSTABLE_DPI)

/// The sensor resolution of a mouse and what it can be set to.
public struct DPIInfo: Hashable, Sendable {
    public var current: Int
    public var defaultValue: Int
    /// Every supported value, ascending. Empty when the device didn't list them.
    public var supported: [Int]
    /// Set when the device described its values as a range with a fixed step.
    public var step: Int?

    public init(current: Int, defaultValue: Int, supported: [Int], step: Int? = nil) {
        self.current = current
        self.defaultValue = defaultValue
        self.supported = supported
        self.step = step
    }

    public var minimum: Int { supported.first ?? current }
    public var maximum: Int { supported.last ?? current }

    /// The supported value closest to `value` (the lower one on a tie).
    public func nearest(to value: Int) -> Int {
        guard !supported.isEmpty else { return value }
        return supported.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// `count` values spread evenly over the supported list, including both ends.
    public func suggestedPresets(count: Int = 4) -> [Int] {
        guard count > 1, supported.count > count else { return supported }
        let last = Double(supported.count - 1)
        let indices = (0..<count).map { Int((Double($0) * last / Double(count - 1)).rounded()) }
        return Self.uniqueSorted(indices.map { supported[$0] })
    }

    /// The preset after `current`, wrapping around. Presets are snapped to supported values;
    /// an empty list uses `suggestedPresets()`.
    public func nextPreset(after current: Int, presets: [Int] = []) -> Int {
        let candidates = presets.isEmpty ? suggestedPresets() : Self.uniqueSorted(presets.map(nearest(to:)))
        guard let first = candidates.first else { return current }
        return candidates.first { $0 > current } ?? first
    }

    /// Decodes getSensorDpiList values (big-endian UInt16s, ended by 0). A value whose top three
    /// bits are set is a step: `[400, 0xE000 | 50, 4000]` means 400 through 4000 in steps of 50.
    static func parseList(_ bytes: [UInt8]) -> (values: [Int], step: Int?) {
        var values: [Int] = []
        var step: Int?
        var offset = 0
        while offset + 1 < bytes.count {
            let value = bytes.uint16(at: offset)
            if value == 0 { break }
            if value >> 13 == 0b111 {
                let increment = Int(value & 0x1FFF)
                let end = Int(bytes.uint16(at: offset + 2))
                if increment > 0, let start = values.last, end > start {
                    values += stride(from: start + increment, through: end, by: increment)
                    step = increment
                }
                offset += 4
            } else {
                values.append(Int(value))
                offset += 2
            }
        }
        return (uniqueSorted(values), step)
    }

    private static func uniqueSorted(_ values: [Int]) -> [Int] {
        Array(Set(values)).sorted()
    }
}

// MARK: Firmware (0x0003 DEVICE_FW_VERSION)

/// One firmware entity of a device, formatted like Solaar ("RBM 14.00.B0015").
public struct FirmwareInfo: Hashable, Sendable {
    public enum Kind: UInt8, Hashable, Sendable {
        case firmware = 0
        case bootloader = 1
        case hardware = 2
        case other = 3

        public var title: String {
            switch self {
            case .firmware: return NSLocalizedString("Firmware", comment: "Kind of firmware entry")
            case .bootloader: return NSLocalizedString("Bootloader", comment: "Kind of firmware entry")
            case .hardware: return NSLocalizedString("Hardware", comment: "Kind of firmware entry")
            case .other: return NSLocalizedString("Other", comment: "Kind of firmware entry")
            }
        }
    }

    public var kind: Kind
    /// Three-letter prefix such as "RBM"; empty for hardware entries.
    public var name: String
    public var version: String

    public init(kind: Kind, name: String, version: String) {
        self.kind = kind
        self.name = name
        self.version = version
    }

    public var displayString: String { name.isEmpty ? version : "\(name) \(version)" }

    /// getFwInfo reply: [type, prefix (3 ASCII), number (BCD), revision (BCD), build (2, BE), ...].
    init(fwInfoParameters p: [UInt8]) {
        kind = Kind(rawValue: p[0] & 0x0F) ?? .other
        switch kind {
        case .firmware, .bootloader:
            name = String(decoding: p[1...3].filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            version = String(format: "%02X.%02X", p[4], p[5])
            let build = p.uint16(at: 6)
            if build != 0 { version += String(format: ".B%04X", build) }
        case .hardware:
            name = ""
            version = "\(p[1])"
        case .other:
            name = ""
            version = ""
        }
    }
}

// MARK: Easy-Switch (0x1814 CHANGE_HOST, 0x1815 HOSTS_INFO)

/// The device's Easy-Switch channels. Indices are zero-based.
public struct HostInfo: Hashable, Sendable {
    public var count: Int
    public var current: Int
    /// Host names by index, when the device stores them (Bluetooth pairings usually do).
    /// Empty when unknown; `nil` entries are empty or unnamed channels.
    public var names: [String?]

    public init(count: Int, current: Int, names: [String?] = []) {
        self.count = count
        self.current = current
        self.names = names
    }

    public func name(at index: Int) -> String? {
        names.indices.contains(index) ? names[index] : nil
    }
}

/// Typed wrappers for the features above. Every call throws the device's errors as is.
@MainActor
public struct DeviceFeatures {
    public let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    // MARK: 0x2201

    /// getSensorDpiList (fn 1) and getSensorDpi (fn 2) for sensor 0.
    public func dpi() async throws -> DPIInfo {
        let list = try await device.call(.adjustableDPI, function: 1, parameters: [0])
        let parsed = DPIInfo.parseList(Array(list.dropFirst()))
        let reply = try await device.call(.adjustableDPI, function: 2, parameters: [0])
        let current = Int(reply.uint16(at: 1))
        let defaultValue = Int(reply.uint16(at: 3))
        return DPIInfo(current: current == 0 ? defaultValue : current, defaultValue: defaultValue, supported: parsed.values, step: parsed.step)
    }

    /// getSensorDpi (fn 2): the current resolution of sensor 0.
    public func currentDPI() async throws -> Int {
        let reply = try await device.call(.adjustableDPI, function: 2, parameters: [0])
        let current = Int(reply.uint16(at: 1))
        return current == 0 ? Int(reply.uint16(at: 3)) : current
    }

    /// setSensorDpi (fn 3) for sensor 0. Not persisted by every device.
    public func setDPI(_ value: Int) async throws {
        let clamped = UInt16(clamping: max(0, value))
        _ = try await device.call(.adjustableDPI, function: 3, parameters: [0] + clamped.bigEndianBytes)
    }

    // MARK: 0x0003

    /// Every firmware entity (getEntityCount, then getFwInfo per entity).
    public func firmware() async throws -> [FirmwareInfo] {
        let count = Int(try await device.call(.deviceFirmwareVersion, function: 0)[0])
        var entries: [FirmwareInfo] = []
        for entity in 0..<min(count, 16) {
            let reply = try await device.call(.deviceFirmwareVersion, function: 1, parameters: [UInt8(entity)])
            entries.append(FirmwareInfo(fwInfoParameters: reply))
        }
        return entries
    }

    /// getDeviceSerialNumber (fn 2), added in version 4 of 0x0003. Returns nil when empty.
    public func serialNumber() async throws -> String? {
        let reply = try await device.call(.deviceFirmwareVersion, function: 2)
        let serial = String(decoding: reply.prefix(12).filter { (0x21...0x7E).contains($0) }, as: UTF8.self)
        return serial.isEmpty ? nil : serial
    }

    // MARK: 0x1814 / 0x1815

    /// getHostInfo (fn 0): [host count, current host, ...].
    public func hosts() async throws -> HostInfo {
        let reply = try await device.call(.changeHost, function: 0)
        return HostInfo(count: Int(reply[0]), current: Int(reply[1]))
    }

    /// Host names from HOSTS_INFO: getFeatureInfo (fn 0) for the capability flag, getHostInfo
    /// (fn 1) per host for its status and name length, getHostFriendlyName (fn 3) in 14-byte pages.
    public func hostNames(count: Int) async throws -> [String?] {
        let info = try await device.call(.hostsInfo, function: 0)
        guard info[0] & 0x01 != 0 else { return [] }
        var names: [String?] = []
        for host in 0..<min(count, 8) {
            let hostInfo = try await device.call(.hostsInfo, function: 1, parameters: [UInt8(host)])
            let paired = hostInfo[1] != 0
            let length = Int(hostInfo[4])
            guard paired, length > 0 else {
                names.append(nil)
                continue
            }
            var bytes: [UInt8] = []
            while bytes.count < length {
                let page = try await device.call(.hostsInfo, function: 3, parameters: [UInt8(host), UInt8(bytes.count)])
                let chunk = page.dropFirst(2).prefix(min(14, length - bytes.count))
                if chunk.isEmpty { break }
                bytes += chunk
            }
            let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            names.append(name.isEmpty ? nil : name)
        }
        return names
    }

    /// setCurrentHost (fn 1), sent without waiting: the device leaves right away and never answers.
    public nonisolated static func changeHostMessage(deviceIndex: UInt8, featureIndex: UInt8, host: Int, softwareID: UInt8) -> HIDPPMessage {
        .request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: 1, softwareID: softwareID, parameters: [UInt8(clamping: host)])
    }
}
