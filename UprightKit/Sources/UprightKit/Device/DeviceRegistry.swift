import Foundation

// Wave 0 scaffold: final signatures and a minimal single-device implementation (no same-unit
// dedupe, no standby). W2.2 owns this file and implements §B7 / §C step 6.

/// Every endpoint Upright knows about, across all links, with its role.
@MainActor
public final class DeviceRegistry {
    public struct Record: Identifiable, Hashable, Sendable {
        public var address: DeviceAddress
        public var connection: ConnectionKind
        public var state: EndpointController.State
        public var deviceID: DeviceID?
        public var model: ModelKey?
        public var displayName: String
        public var role: Role
        /// First-seen order, stable for the process.
        public var ordinal: Int

        public var id: DeviceAddress { address }

        public init(
            address: DeviceAddress,
            connection: ConnectionKind,
            state: EndpointController.State,
            deviceID: DeviceID? = nil,
            model: ModelKey? = nil,
            displayName: String,
            role: Role,
            ordinal: Int
        ) {
            self.address = address
            self.connection = connection
            self.state = state
            self.deviceID = deviceID
            self.model = model
            self.displayName = displayName
            self.role = role
            self.ordinal = ordinal
        }

        /// The snapshot of a connected or asleep endpoint.
        public var snapshot: DeviceSnapshot? {
            switch state {
            case .connected(let snapshot), .asleep(let snapshot): return snapshot
            default: return nil
            }
        }

        public var isConnected: Bool {
            if case .connected = state { return true }
            return false
        }
    }

    public enum Role: Hashable, Sendable {
        /// Served: its events are handled and its configuration follows the mappings.
        case active
        /// The same unit is active on a better link; kept native, its events dropped.
        case standby(of: DeviceAddress)
        /// Not a supported mouse (terminal).
        case unsupported
        /// Not identified yet.
        case pending
    }

    /// Nicknames, by stable device ID.
    public var nameProvider: ((DeviceID) -> String?)?
    public var onChange: (() -> Void)?

    /// Pointers first by ordinal; unsupported last.
    public private(set) var records: [Record] = []

    private var nextOrdinal = 0

    public init() {}

    public func update(_ a: DeviceAddress, connection: ConnectionKind, state: EndpointController.State) {
        var entry = record(a) ?? Record(
            address: a,
            connection: connection,
            state: state,
            displayName: "",
            role: .pending,
            ordinal: takeOrdinal()
        )
        entry.connection = connection
        entry.state = state
        let snapshot = entry.snapshot
        if let snapshot { entry.displayName = snapshot.name }
        if let id = entry.deviceID, let nickname = nameProvider?(id) { entry.displayName = nickname }
        entry.role = snapshot == nil ? .pending : .active
        if let index = records.firstIndex(where: { $0.address == a }) {
            records[index] = entry
        } else {
            records.append(entry)
        }
        sort()
        onChange?()
    }

    public func remove(_ a: DeviceAddress) {
        guard records.contains(where: { $0.address == a }) else { return }
        records.removeAll { $0.address == a }
        onChange?()
    }

    /// Removes every endpoint of a closed link and returns their addresses.
    @discardableResult
    public func removeLink(_ link: UInt32) -> [DeviceAddress] {
        let removed = records.filter { $0.address.link == link }.map(\.address)
        guard !removed.isEmpty else { return [] }
        records.removeAll { $0.address.link == link }
        onChange?()
        return removed
    }

    public func record(_ a: DeviceAddress) -> Record? {
        records.first { $0.address == a }
    }

    public func addresses(of id: DeviceID) -> [DeviceAddress] {
        records.filter { $0.deviceID == id }.map(\.address)
    }

    /// False for standby, unsupported and pending endpoints.
    public func isActive(_ a: DeviceAddress) -> Bool {
        record(a)?.role == .active
    }

    public var summary: FleetSummary {
        var summary = FleetSummary()
        for record in records {
            switch record.state {
            case .connected(let snapshot):
                summary.anyConnected = true
                summary.anyPresent = true
                summary.connectedCount += 1
                if let battery = snapshot.battery, battery.percentage < (summary.lowestBattery?.status.percentage ?? Int.max) {
                    summary.lowestBattery = (record.address, battery)
                }
            case .asleep:
                summary.anyPresent = true
            case .failed:
                summary.problems.append(record.address)
            default:
                break
            }
        }
        return summary
    }

    /// usb 0 < receivers 1 < bluetooth 2: the better link wins same-unit dedupe.
    public static func linkRank(_ c: ConnectionKind) -> Int {
        switch c {
        case .usb: return 0
        case .unifying, .bolt, .nano: return 1
        case .bluetooth: return 2
        }
    }

    private func takeOrdinal() -> Int {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }

    private func sort() {
        records.sort { lhs, rhs in
            let l = lhs.role == .unsupported ? 1 : 0
            let r = rhs.role == .unsupported ? 1 : 0
            return l == r ? lhs.ordinal < rhs.ordinal : l < r
        }
    }
}

/// The fleet at a glance, for the menu-bar label, scroll gating and alerts.
public struct FleetSummary: Hashable, Sendable {
    public var anyConnected = false
    /// Connected or asleep.
    public var anyPresent = false
    public var connectedCount = 0
    /// The connected mouse with the lowest battery.
    public var lowestBattery: (address: DeviceAddress, status: BatteryStatus)?
    /// Endpoints that need the user's attention (failed); unsupported devices are not problems.
    public var problems: [DeviceAddress] = []

    public init() {}

    public static func == (lhs: FleetSummary, rhs: FleetSummary) -> Bool {
        lhs.anyConnected == rhs.anyConnected
            && lhs.anyPresent == rhs.anyPresent
            && lhs.connectedCount == rhs.connectedCount
            && lhs.lowestBattery?.address == rhs.lowestBattery?.address
            && lhs.lowestBattery?.status == rhs.lowestBattery?.status
            && lhs.problems == rhs.problems
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(anyConnected)
        hasher.combine(anyPresent)
        hasher.combine(connectedCount)
        hasher.combine(lowestBattery?.address)
        hasher.combine(lowestBattery?.status)
        hasher.combine(problems)
    }
}
