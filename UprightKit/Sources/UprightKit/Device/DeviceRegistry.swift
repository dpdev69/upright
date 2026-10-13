import Foundation

/// Every endpoint Upright knows about, across all links, with its role (§C step 6).
///
/// Identity: a record is keyed by its `DeviceAddress`. Once the endpoint identifies, the record
/// carries its `DeviceID` and `ModelKey`, and keeps them while the mouse sleeps or is retried.
///
/// Same unit on two links (D12): when several served endpoints share a stable `DeviceID`, one
/// is `.active` and the others are `.standby(of:)` it. A connected endpoint beats one that isn't
/// (a mouse switched to its Bluetooth channel leaves its receiver slot asleep), then the better
/// link (`linkRank`: USB, then receiver, then Bluetooth), then the endpoint seen first. When the
/// active endpoint leaves or stops answering, the next one is promoted. Transient IDs are never
/// deduplicated, so two mice that report no unit ID both stay active.
///
/// Order: `ordinal` is first-seen order, kept per unit for the whole process, so a mouse that
/// reconnects on a new link (a Bluetooth reconnect, a USB re-plug) keeps its place.
@MainActor
public final class DeviceRegistry {
    public struct Record: Identifiable, Hashable, Sendable {
        public var address: DeviceAddress
        public var connection: ConnectionKind
        public var state: EndpointController.State
        /// Set once the endpoint identifies; kept while it sleeps or is retried.
        public var deviceID: DeviceID?
        public var model: ModelKey?
        /// The nickname, else the catalog's model name, else the name the device reports.
        /// Already disambiguated: a second unit with the same name gets " #2".
        public var displayName: String
        public var role: Role
        /// First-seen order, stable for the process (per unit once identified).
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

    /// Nicknames, by device ID. Call `refreshNames()` after a nickname changes.
    public var nameProvider: ((DeviceID) -> String?)?
    /// Called after `records` changed (and only then).
    public var onChange: (() -> Void)?

    /// Pointers first by ordinal; unsupported last.
    public private(set) var records: [Record] = []

    /// Endpoint first-seen order: the ordinal of an unidentified endpoint and the final tie-break.
    private var sequence: [DeviceAddress: Int] = [:]
    private var nextSequence = 0
    /// The ordinal of every stable unit seen in this process.
    private var unitOrdinals: [DeviceID: Int] = [:]
    /// Display names before nicknames and numbering.
    private var baseNames: [DeviceAddress: String] = [:]
    private var unsupported: Set<DeviceAddress> = []

    public init() {}

    // MARK: Updates

    public func update(_ a: DeviceAddress, connection: ConnectionKind, state: EndpointController.State) {
        let observed = Self.observe(state)
        update(a, connection: connection, state: state, snapshot: observed.snapshot, unsupported: observed.unsupported)
    }

    /// `update` with the state already decoded: the snapshot (or partial snapshot) it carries,
    /// and whether it is the terminal unsupported verdict.
    func update(
        _ a: DeviceAddress,
        connection: ConnectionKind,
        state: EndpointController.State,
        snapshot: DeviceSnapshot?,
        unsupported reason: UnsupportedReason?
    ) {
        commit {
            let index: Int
            if let existing = records.firstIndex(where: { $0.address == a }) {
                index = existing
            } else {
                let seen = takeSequence()
                sequence[a] = seen
                records.append(Record(address: a, connection: connection, state: state, displayName: "", role: .pending, ordinal: seen))
                index = records.count - 1
            }
            records[index].connection = connection
            records[index].state = state
            if reason != nil { unsupported.insert(a) } else { unsupported.remove(a) }

            guard let snapshot else { return }
            // A partial snapshot without identity says nothing about the model; the compat
            // `modelKey` (MX Vertical) only stands in for legacy fixtures of served mice.
            let model = snapshot.identity?.model ?? (reason == nil ? snapshot.modelKey : nil)
            let id = snapshot.identity?.deviceID(at: a) ?? (reason == nil ? DeviceID.transient(a) : nil)
            records[index].model = model
            records[index].deviceID = id
            baseNames[a] = Self.baseName(model: model, reported: snapshot.name)
            // A unit seen before in this process gets its old place back.
            var ordinal = sequence[a] ?? records[index].ordinal
            if let id, id.isStable {
                ordinal = unitOrdinals[id] ?? ordinal
                unitOrdinals[id] = ordinal
            }
            records[index].ordinal = ordinal
        }
    }

    public func remove(_ a: DeviceAddress) {
        guard records.contains(where: { $0.address == a }) else { return }
        commit { forget([a]) }
    }

    /// Removes every endpoint of a closed link and returns their addresses.
    @discardableResult
    public func removeLink(_ link: UInt32) -> [DeviceAddress] {
        let removed = records.filter { $0.address.link == link }.map(\.address)
        guard !removed.isEmpty else { return [] }
        commit { forget(removed) }
        return removed
    }

    /// Re-reads nicknames from `nameProvider`.
    public func refreshNames() {
        commit {}
    }

    // MARK: Queries

    public func record(_ a: DeviceAddress) -> Record? {
        records.first { $0.address == a }
    }

    /// Every endpoint that identified as this unit, in `records` order.
    public func addresses(of id: DeviceID) -> [DeviceAddress] {
        records.filter { $0.deviceID == id }.map(\.address)
    }

    /// False for standby, unsupported and pending endpoints.
    public func isActive(_ a: DeviceAddress) -> Bool {
        record(a)?.role == .active
    }

    /// The role an endpoint would get if it connected now with `snapshot`, for
    /// `HIDPPLink.configurationProvider`: the hub asks for a configuration before the
    /// endpoint's `.connected` update reaches the registry. Changes nothing.
    public func prospectiveRole(_ a: DeviceAddress, snapshot: DeviceSnapshot) -> Role {
        var facts = records.filter { $0.address != a }.map(fact(for:))
        facts.append(Fact(
            address: a,
            connection: snapshot.connection,
            deviceID: snapshot.identity?.deviceID(at: a) ?? .transient(a),
            isConnected: true,
            isUnsupported: false,
            sequence: sequence[a] ?? nextSequence
        ))
        return Self.roles(for: facts)[a] ?? .pending
    }

    public var summary: FleetSummary {
        var summary = FleetSummary()
        for record in records where record.role != .unsupported {
            switch record.state {
            case .connected(let snapshot):
                summary.anyConnected = true
                summary.anyPresent = true
                // A standby endpoint is another link to a unit already counted.
                if case .standby = record.role { continue }
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
    public nonisolated static func linkRank(_ c: ConnectionKind) -> Int {
        switch c {
        case .usb: return 0
        case .unifying, .bolt, .nano: return 1
        case .bluetooth: return 2
        }
    }

    // MARK: Roles

    private struct Fact {
        var address: DeviceAddress
        var connection: ConnectionKind
        var deviceID: DeviceID?
        var isConnected: Bool
        var isUnsupported: Bool
        var sequence: Int
    }

    private func fact(for record: Record) -> Fact {
        Fact(
            address: record.address,
            connection: record.connection,
            deviceID: record.deviceID,
            isConnected: record.isConnected,
            isUnsupported: unsupported.contains(record.address),
            sequence: sequence[record.address] ?? record.ordinal
        )
    }

    private static func roles(for facts: [Fact]) -> [DeviceAddress: Role] {
        // Connected first, then the better link, then the endpoint seen first.
        func preferred(_ lhs: Fact, _ rhs: Fact) -> Bool {
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            let l = linkRank(lhs.connection), r = linkRank(rhs.connection)
            return l != r ? l < r : lhs.sequence < rhs.sequence
        }
        var winners: [DeviceID: Fact] = [:]
        for fact in facts where !fact.isUnsupported {
            guard let id = fact.deviceID, id.isStable else { continue }
            if let current = winners[id], !preferred(fact, current) { continue }
            winners[id] = fact
        }
        var roles: [DeviceAddress: Role] = [:]
        for fact in facts {
            if fact.isUnsupported {
                roles[fact.address] = .unsupported
            } else if let id = fact.deviceID {
                if id.isStable, let winner = winners[id], winner.address != fact.address {
                    roles[fact.address] = .standby(of: winner.address)
                } else {
                    roles[fact.address] = .active
                }
            } else {
                roles[fact.address] = .pending
            }
        }
        return roles
    }

    // MARK: Bookkeeping

    /// Runs a mutation, then recomputes roles, names and order, and reports a change if any.
    private func commit(_ mutation: () -> Void) {
        let before = records
        mutation()
        let roles = Self.roles(for: records.map(fact(for:)))
        for index in records.indices {
            records[index].role = roles[records[index].address] ?? .pending
        }
        assignDisplayNames()
        records.sort { lhs, rhs in
            let l = lhs.role == .unsupported, r = rhs.role == .unsupported
            if l != r { return r }
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            return (sequence[lhs.address] ?? 0) < (sequence[rhs.address] ?? 0)
        }
        if records != before { onChange?() }
    }

    private func forget(_ addresses: [DeviceAddress]) {
        let gone = Set(addresses)
        records.removeAll { gone.contains($0.address) }
        for address in gone {
            sequence[address] = nil
            baseNames[address] = nil
            unsupported.remove(address)
        }
    }

    /// Nickname, else base name; then " #2", " #3"… for further units sharing a name, in
    /// first-seen order. Two links to one unit share its number.
    private func assignDisplayNames() {
        var names: [DeviceAddress: String] = [:]
        for record in records {
            let nickname = record.deviceID
                .flatMap { nameProvider?($0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            names[record.address] = nickname.flatMap { $0.isEmpty ? nil : $0 }
                ?? baseNames[record.address]
                ?? Self.placeholderName
        }

        func unit(_ record: Record) -> String {
            if let id = record.deviceID, id.isStable { return id.rawValue }
            return "@" + record.address.description
        }
        var unitsByName: [String: [String: (Int, Int)]] = [:]
        for record in records {
            let name = names[record.address] ?? Self.placeholderName
            let rank = (record.ordinal, sequence[record.address] ?? record.ordinal)
            if let known = unitsByName[name]?[unit(record)], known <= rank { continue }
            unitsByName[name, default: [:]][unit(record)] = rank
        }
        for index in records.indices {
            let record = records[index]
            let name = names[record.address] ?? Self.placeholderName
            let units = (unitsByName[name] ?? [:]).sorted { $0.value < $1.value }.map(\.key)
            let number = (units.firstIndex(of: unit(record)) ?? 0) + 1
            records[index].displayName = number == 1
                ? name
                : String(format: NSLocalizedString("%@ #%lld", comment: "A second mouse with the same name; %@ is the name, %lld its number"), name, Int64(number))
        }
    }

    private func takeSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    // MARK: Decoding states

    private static let placeholderName = NSLocalizedString("Logitech device", comment: "A device that hasn't said what it is yet")

    private static func baseName(model: ModelKey?, reported: String) -> String {
        if let model, let catalog = DeviceCatalog.model(model) { return catalog.name }
        let trimmed = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholderName : trimmed
    }

    private static func observe(_ state: EndpointController.State) -> (snapshot: DeviceSnapshot?, unsupported: UnsupportedReason?) {
        if case .connected(let snapshot) = state { return (snapshot, nil) }
        if case .asleep(let snapshot) = state { return (snapshot, nil) }
        if let payload = unsupportedPayload(of: state) { return (payload.partial, payload.reason) }
        return (nil, nil)
    }

    /// The reason and partial snapshot of a terminal `.unsupported(UnsupportedReason,
    /// DeviceSnapshot?)` state (§B4).
    ///
    /// That case arrives with the hub (W3.1). Until then the registry recognizes it by its name
    /// and payload types, so it handles the verdict the moment the case exists; afterwards this
    /// is equivalent to `if case .unsupported(let reason, let partial) = state`, which should
    /// replace it.
    nonisolated static func unsupportedPayload(of state: Any) -> (reason: UnsupportedReason, partial: DeviceSnapshot?)? {
        let mirror = Mirror(reflecting: state)
        guard mirror.displayStyle == .enum, let payload = mirror.children.first, payload.label == "unsupported" else {
            return nil
        }
        if let reason = payload.value as? UnsupportedReason { return (reason, nil) }
        let values = Mirror(reflecting: payload.value).children.map(\.value)
        guard let reason = values.first as? UnsupportedReason else { return nil }
        return (reason, values.dropFirst().first.flatMap { $0 as? DeviceSnapshot })
    }
}

/// The fleet at a glance, for the menu-bar label, scroll gating and alerts. Unsupported
/// endpoints never count.
public struct FleetSummary: Hashable, Sendable {
    public var anyConnected = false
    /// Connected or asleep.
    public var anyPresent = false
    /// Connected units (a standby link to a unit already counted isn't counted again).
    public var connectedCount = 0
    /// The connected mouse with the lowest battery (the first one on a tie).
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
