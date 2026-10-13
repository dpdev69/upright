import Foundation

/// Capability flags from REPROG_CONTROLS_V4.getCidInfo (byte 4).
public struct ControlFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let mouseButton = ControlFlags(rawValue: 0x01)
    public static let fnKey = ControlFlags(rawValue: 0x02)
    public static let nonStandard = ControlFlags(rawValue: 0x04)
    public static let fnSensitive = ControlFlags(rawValue: 0x08)
    public static let reprogrammable = ControlFlags(rawValue: 0x10)
    public static let divertable = ControlFlags(rawValue: 0x20)
    public static let persistentlyDivertable = ControlFlags(rawValue: 0x40)
    public static let virtual = ControlFlags(rawValue: 0x80)

    public var names: [String] {
        let all: [(ControlFlags, String)] = [
            (.mouseButton, "mouse"), (.fnKey, "fn"), (.nonStandard, "nonstandard"), (.fnSensitive, "fn-sensitive"),
            (.reprogrammable, "reprogrammable"), (.divertable, "divertable"),
            (.persistentlyDivertable, "persistent"), (.virtual, "virtual"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

/// One entry of the device's control table (a physical or virtual button).
public struct ControlInfo: Hashable, Sendable, Identifiable {
    public var cid: UInt16
    public var taskID: UInt16
    public var flags: ControlFlags
    public var position: UInt8
    public var group: UInt8
    public var groupMask: UInt8
    public var additionalFlags: UInt8

    public var id: UInt16 { cid }

    public init(cid: UInt16, taskID: UInt16, flags: ControlFlags, position: UInt8 = 0, group: UInt8 = 0, groupMask: UInt8 = 0, additionalFlags: UInt8 = 0) {
        self.cid = cid
        self.taskID = taskID
        self.flags = flags
        self.position = position
        self.group = group
        self.groupMask = groupMask
        self.additionalFlags = additionalFlags
    }

    /// getCidInfo reply: [cid(2), tid(2), flags, pos, group, gmask, additional flags].
    init(cidInfoParameters p: [UInt8]) {
        self.init(
            cid: p.uint16(at: 0),
            taskID: p.uint16(at: 2),
            flags: ControlFlags(rawValue: p[4]),
            position: p[5],
            group: p[6],
            groupMask: p[7],
            additionalFlags: p[8]
        )
    }

    /// Additional flags bit 0 (Solaar's KEY_FLAG.raw_XY): the control can report raw pointer
    /// movement while held instead of moving the cursor.
    public var supportsRawXY: Bool { additionalFlags & 0x01 != 0 }

    /// Controls Upright offers for remapping: physical, divertable, and not a primary click.
    public var isConfigurable: Bool {
        flags.contains(.divertable) && !flags.contains(.virtual) && !KnownControl.primaryClicks.contains(cid)
    }
}

/// Reporting flags for getCidReporting / setCidReporting (Solaar's MAPPING_FLAG). Each "valid"
/// bit (the flag shifted left by one) tells the device that the flag next to it should be applied.
public struct ReportingFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let diverted = ReportingFlags(rawValue: 0x01)
    public static let divertedValid = ReportingFlags(rawValue: 0x02)
    public static let persistentlyDiverted = ReportingFlags(rawValue: 0x04)
    public static let persistentlyDivertedValid = ReportingFlags(rawValue: 0x08)
    public static let rawXYDiverted = ReportingFlags(rawValue: 0x10)
    public static let rawXYDivertedValid = ReportingFlags(rawValue: 0x20)
}

/// Typed wrapper for feature 0x1B04 REPROG_CONTROLS_V4.
///
/// Functions: 0 getCount, 1 getCidInfo(index), 2 getCidReporting(cid), 3 setCidReporting(cid, flags, remap).
/// Events: 0 divertedButtonsEvent (up to four currently pressed CIDs), 1 divertedRawMouseXYEvent (dx, dy).
@MainActor
public struct ReprogControls {
    public let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    public func count() async throws -> Int {
        Int(try await device.call(.reprogControlsV4, function: 0)[0])
    }

    public func controlInfo(at index: Int) async throws -> ControlInfo {
        ControlInfo(cidInfoParameters: try await device.call(.reprogControlsV4, function: 1, parameters: [UInt8(index)]))
    }

    public func allControls() async throws -> [ControlInfo] {
        let total = try await count()
        var controls: [ControlInfo] = []
        for index in 0..<total {
            controls.append(try await controlInfo(at: index))
        }
        return controls
    }

    public func reporting(for cid: UInt16) async throws -> ReportingFlags {
        let reply = try await device.call(.reprogControlsV4, function: 2, parameters: cid.bigEndianBytes)
        return ReportingFlags(rawValue: reply[2])
    }

    /// Temporarily diverts (or un-diverts) a control. Temporary diversion lasts until the mouse
    /// powers off or reconnects. If Upright crashes, diverted buttons do nothing until then
    /// (or until Upright relaunches, which re-applies the configuration with `force`).
    public func setDiverted(_ diverted: Bool, cid: UInt16) async throws {
        try await setReporting(cid: cid, diverted: diverted, rawXY: nil)
    }

    /// Sets diversion and, unless `rawXY` is nil, raw XY reporting. Raw XY only takes effect on a
    /// diverted control; while it is on, the held button reports movement instead of moving the pointer.
    public func setReporting(cid: UInt16, diverted: Bool, rawXY: Bool?) async throws {
        let flags = Self.reportingFlags(diverted: diverted, rawXY: rawXY)
        _ = try await device.call(.reprogControlsV4, function: 3, parameters: cid.bigEndianBytes + [flags.rawValue, 0, 0])
    }

    public nonisolated static func reportingFlags(diverted: Bool, rawXY: Bool?) -> ReportingFlags {
        var flags: ReportingFlags = diverted ? [.diverted, .divertedValid] : [.divertedValid]
        if let rawXY {
            flags.insert(.rawXYDivertedValid)
            if rawXY && diverted { flags.insert(.rawXYDiverted) }
        }
        return flags
    }

    /// The set-reporting message, for fire-and-forget use when the app is quitting.
    /// `clearRawXY` also turns raw XY reporting off.
    public nonisolated static func undivertMessage(deviceIndex: UInt8, featureIndex: UInt8, cid: UInt16, softwareID: UInt8, clearRawXY: Bool = false) -> HIDPPMessage {
        .request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: 3,
            softwareID: softwareID,
            parameters: cid.bigEndianBytes + [reportingFlags(diverted: false, rawXY: clearRawXY ? false : nil).rawValue, 0, 0]
        )
    }

    /// Decodes divertedButtonsEvent parameters into the list of currently pressed CIDs.
    public nonisolated static func pressedControls(fromEventParameters p: [UInt8]) -> [UInt16] {
        stride(from: 0, to: min(p.count, 8), by: 2)
            .map { p.uint16(at: $0) }
            .filter { $0 != 0 }
    }

    /// Decodes divertedRawMouseXYEvent parameters: dx, dy as signed big-endian 16-bit values.
    public nonisolated static func rawXYDelta(fromEventParameters p: [UInt8]) -> (dx: Int, dy: Int) {
        (Int(Int16(bitPattern: p.uint16(at: 0))), Int(Int16(bitPattern: p.uint16(at: 2))))
    }
}
