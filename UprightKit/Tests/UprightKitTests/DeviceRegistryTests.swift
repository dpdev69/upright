import XCTest
@testable import UprightKit

/// A snapshot of a simulated device as `DeviceSession.start()` reads it at `address`.
private func identified(
    _ profile: SimulatedDeviceProfile,
    connection: ConnectionKind,
    at address: DeviceAddress,
    battery: Int? = nil
) -> DeviceSnapshot {
    DeviceSnapshot(
        name: profile.name,
        connection: connection,
        deviceIndex: address.index,
        protocolVersion: "\(profile.protocolMajor).\(profile.protocolMinor)",
        features: [],
        controls: profile.controls,
        battery: BatteryStatus(percentage: battery ?? profile.batteryLevel, isCharging: false),
        identity: DeviceIdentity(
            name: profile.name,
            kind: profile.kind,
            unitID: profile.unitID,
            serialNumber: profile.serialNumber,
            modelIDs: profile.modelIDs,
            transportPID: address.isDirect ? (connection == .usb ? profile.usbPID : profile.bluetoothPID) : profile.wirelessPID
        ),
        address: address
    )
}

/// A same-shaped stand-in for `EndpointController.State` once W3.1 adds the unsupported case.
private enum PlannedState {
    case probing
    case connected(DeviceSnapshot)
    case failed(String)
    case unsupported(UnsupportedReason, DeviceSnapshot?)
}

private enum LabeledState {
    case unsupported(reason: UnsupportedReason, partial: DeviceSnapshot?)
}

private enum ReasonOnlyState {
    case unsupported(UnsupportedReason)
}

@MainActor
final class DeviceRegistryTests: XCTestCase {
    private let receiver = DeviceAddress(link: 1, index: 1)
    private let receiverSlot2 = DeviceAddress(link: 1, index: 2)
    private let receiverSlot3 = DeviceAddress(link: 1, index: 3)
    private let usb = DeviceAddress(link: 2, index: DeviceAddress.direct)
    private let bluetooth = DeviceAddress(link: 3, index: DeviceAddress.direct)

    private var changes = 0

    private func makeRegistry() -> DeviceRegistry {
        let registry = DeviceRegistry()
        changes = 0
        registry.onChange = { [weak self] in self?.changes += 1 }
        return registry
    }

    private func connect(
        _ registry: DeviceRegistry,
        _ profile: SimulatedDeviceProfile,
        _ connection: ConnectionKind,
        at address: DeviceAddress,
        battery: Int? = nil
    ) {
        registry.update(address, connection: connection, state: .connected(identified(profile, connection: connection, at: address, battery: battery)))
    }

    private func putToSleep(
        _ registry: DeviceRegistry,
        _ profile: SimulatedDeviceProfile,
        _ connection: ConnectionKind,
        at address: DeviceAddress
    ) {
        registry.update(address, connection: connection, state: .asleep(identified(profile, connection: connection, at: address)))
    }

    private func unitID(_ profile: SimulatedDeviceProfile) -> DeviceID {
        identified(profile, connection: .usb, at: usb).identity!.deviceID(at: usb)
    }

    // MARK: Order

    func testOrderIsFirstSeenAndStable() async {
        let registry = makeRegistry()
        registry.update(receiver, connection: .unifying, state: .probing)
        registry.update(bluetooth, connection: .bluetooth, state: .probing)
        XCTAssertEqual(registry.records.map(\.address), [receiver, bluetooth])
        XCTAssertEqual(registry.records.map(\.role), [.pending, .pending])
        XCTAssertFalse(registry.isActive(receiver))

        // The Bluetooth mouse answers first; first-seen order still wins.
        connect(registry, DeviceProfiles.mxMaster3S, .bluetooth, at: bluetooth)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        XCTAssertEqual(registry.records.map(\.address), [receiver, bluetooth])
        let ordinals = registry.records.map(\.ordinal)
        XCTAssertEqual(ordinals, ordinals.sorted())
        XCTAssertEqual(Set(ordinals).count, 2)

        // Sleep, battery news and retries don't move anyone.
        putToSleep(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        connect(registry, DeviceProfiles.mxMaster3S, .bluetooth, at: bluetooth, battery: 10)
        registry.update(receiver, connection: .unifying, state: .waitingForDevice)
        XCTAssertEqual(registry.records.map(\.address), [receiver, bluetooth])
        XCTAssertEqual(registry.records.map(\.ordinal), ordinals)

        // The Bluetooth mouse drops off (its HID interface goes away), a Lift arrives, then the
        // Master reconnects on a new link: once identified it is back in its first-seen place.
        registry.removeLink(bluetooth.link)
        let lift = DeviceAddress(link: 4, index: DeviceAddress.direct)
        connect(registry, DeviceProfiles.lift, .bluetooth, at: lift)
        let master = DeviceAddress(link: 5, index: DeviceAddress.direct)
        registry.update(master, connection: .bluetooth, state: .probing)
        XCTAssertEqual(registry.records.map(\.address), [receiver, lift, master])
        connect(registry, DeviceProfiles.mxMaster3S, .bluetooth, at: master)
        XCTAssertEqual(registry.records.map(\.address), [receiver, master, lift])
        XCTAssertEqual(registry.record(master)?.ordinal, ordinals[1])
    }

    // MARK: Same unit (D12)

    func testSameUnitOnUSBAndReceiverPrefersUSB() async {
        let registry = makeRegistry()
        let vertical = unitID(DeviceProfiles.mxVertical)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        XCTAssertEqual(registry.record(receiver)?.role, .active)
        XCTAssertEqual(registry.record(receiver)?.deviceID, vertical)
        XCTAssertEqual(registry.record(receiver)?.model, .mxVertical)

        // The cable goes in: the same unit answers over USB as well.
        connect(registry, DeviceProfiles.mxVertical, .usb, at: usb)
        XCTAssertEqual(registry.record(usb)?.role, .active)
        XCTAssertEqual(registry.record(receiver)?.role, .standby(of: usb))
        XCTAssertTrue(registry.isActive(usb))
        XCTAssertFalse(registry.isActive(receiver))
        XCTAssertEqual(Set(registry.addresses(of: vertical)), [receiver, usb])

        // And over Bluetooth: USB still wins.
        connect(registry, DeviceProfiles.mxVertical, .bluetooth, at: bluetooth)
        XCTAssertEqual(registry.record(bluetooth)?.role, .standby(of: usb))
        XCTAssertEqual(registry.records.filter { $0.role == .active }.map(\.address), [usb])

        // One mouse, one name, one place in the list, counted once.
        XCTAssertEqual(Set(registry.records.map(\.displayName)), ["MX Vertical"])
        XCTAssertEqual(Set(registry.records.map(\.ordinal)).count, 1)
        XCTAssertEqual(registry.records.map(\.address), [receiver, usb, bluetooth])
        XCTAssertEqual(registry.summary.connectedCount, 1)
        XCTAssertEqual(registry.summary.lowestBattery?.address, usb)

        // Receiver beats Bluetooth when there is no cable.
        registry.removeLink(usb.link)
        XCTAssertEqual(registry.record(receiver)?.role, .active)
        XCTAssertEqual(registry.record(bluetooth)?.role, .standby(of: receiver))
    }

    func testStandbyPromotedWhenActiveLeaves() async {
        let registry = makeRegistry()
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        connect(registry, DeviceProfiles.mxVertical, .usb, at: usb)
        XCTAssertFalse(registry.isActive(receiver))

        // The cable comes out: the receiver endpoint is promoted.
        changes = 0
        XCTAssertEqual(registry.removeLink(usb.link), [usb])
        XCTAssertEqual(registry.record(receiver)?.role, .active)
        XCTAssertEqual(changes, 1)

        // The mouse is switched to its Bluetooth channel on this Mac: the receiver slot goes to
        // sleep and the Bluetooth endpoint, the only one answering, is served even though its
        // link ranks lower.
        connect(registry, DeviceProfiles.mxVertical, .bluetooth, at: bluetooth)
        XCTAssertEqual(registry.record(bluetooth)?.role, .standby(of: receiver))
        putToSleep(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        XCTAssertEqual(registry.record(bluetooth)?.role, .active)
        XCTAssertEqual(registry.record(receiver)?.role, .standby(of: bluetooth))
        XCTAssertEqual(registry.summary.connectedCount, 1)

        // Back on the receiver while Bluetooth still answers: the better link takes over again.
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        XCTAssertEqual(registry.record(receiver)?.role, .active)
        XCTAssertEqual(registry.record(bluetooth)?.role, .standby(of: receiver))

        // Removing the active endpoint by address promotes too.
        registry.remove(receiver)
        XCTAssertEqual(registry.record(bluetooth)?.role, .active)
        XCTAssertEqual(registry.records.map(\.address), [bluetooth])
    }

    func testRePairOnSameReceiverPrefersTheAnsweringSlot() async {
        let registry = makeRegistry()
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        // Re-paired into slot 2: the old slot stops answering, the new one identifies as the
        // same unit. The hub retires slot 1; until then slot 2 is the one served.
        registry.update(receiver, connection: .unifying, state: .waitingForDevice)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiverSlot2)
        XCTAssertEqual(registry.record(receiverSlot2)?.role, .active)
        XCTAssertEqual(registry.record(receiver)?.role, .standby(of: receiverSlot2))

        // Both answering on the same link kind: the endpoint seen first wins.
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        XCTAssertEqual(registry.record(receiver)?.role, .active)
        XCTAssertEqual(registry.record(receiverSlot2)?.role, .standby(of: receiver))

        registry.remove(receiver)
        XCTAssertEqual(registry.record(receiverSlot2)?.role, .active)
    }

    func testTransientIDsNeverDeduped() async {
        let registry = makeRegistry()
        let profile = DeviceProfiles.mouseWithoutUnitID
        connect(registry, profile, .unifying, at: receiver)
        connect(registry, profile, .unifying, at: receiverSlot2)
        connect(registry, profile, .usb, at: usb)

        let records = registry.records
        XCTAssertEqual(records.map(\.role), [.active, .active, .active])
        XCTAssertTrue(records.allSatisfy { $0.deviceID?.isStable == false })
        XCTAssertEqual(Set(records.compactMap(\.deviceID)).count, 3)
        XCTAssertEqual(registry.summary.connectedCount, 3)

        let name = DeviceCatalog.model(records[0].model!)?.name ?? profile.name
        XCTAssertEqual(records.map(\.displayName), [name, "\(name) #2", "\(name) #3"])
    }

    // MARK: Unsupported

    func testUnsupportedSortedLastAndNotAProblem() async {
        let registry = makeRegistry()
        // The MX Keys on the shared receiver is seen first, and found not to be a mouse.
        let keyboard = identified(DeviceProfiles.mxKeys, connection: .unifying, at: receiver)
        registry.update(receiver, connection: .unifying, state: .waitingForDevice, snapshot: keyboard, unsupported: .notAPointer(.keyboard))
        // An HID++ 1.0 mouse that says nothing more.
        registry.update(receiverSlot3, connection: .unifying, state: .waitingForDevice, snapshot: nil, unsupported: .hidpp10(major: 1, minor: 0))
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiverSlot2)
        registry.update(usb, connection: .usb, state: .failed("The mouse refused the connection"))

        XCTAssertEqual(registry.records.map(\.address), [receiverSlot2, usb, receiver, receiverSlot3])
        XCTAssertEqual(registry.records.map(\.role), [.active, .pending, .unsupported, .unsupported])
        XCTAssertFalse(registry.isActive(receiver))
        XCTAssertFalse(registry.isActive(receiverSlot3))

        let keys = registry.record(receiver)
        XCTAssertEqual(keys?.displayName, DeviceProfiles.mxKeys.name)
        XCTAssertNotNil(keys?.model)
        XCTAssertNotEqual(keys?.model, .mxVertical)
        let old = registry.record(receiverSlot3)
        XCTAssertNil(old?.deviceID)
        XCTAssertNil(old?.model, "no identity: not mistaken for an MX Vertical")
        XCTAssertEqual(old?.displayName, "Logitech device")

        let summary = registry.summary
        XCTAssertEqual(summary.problems, [usb])
        XCTAssertTrue(summary.anyConnected)
        XCTAssertEqual(summary.connectedCount, 1)
        XCTAssertEqual(summary.lowestBattery?.address, receiverSlot2)

        // An unsupported endpoint never takes part in same-unit dedupe, even with a matching ID.
        let twin = identified(DeviceProfiles.mxVertical, connection: .bluetooth, at: bluetooth)
        registry.update(bluetooth, connection: .bluetooth, state: .waitingForDevice, snapshot: twin, unsupported: .noConfigurableControls)
        XCTAssertEqual(registry.record(receiverSlot2)?.role, .active)
        XCTAssertEqual(registry.record(bluetooth)?.role, .unsupported)
        XCTAssertEqual(registry.records.last?.address, bluetooth)
    }

    func testUnsupportedStateIsRecognizedByShape() async {
        let partial = identified(DeviceProfiles.mxKeys, connection: .bolt, at: receiver)
        let withPartial = DeviceRegistry.unsupportedPayload(of: PlannedState.unsupported(.notAPointer(.keyboard), partial))
        XCTAssertEqual(withPartial?.reason, .notAPointer(.keyboard))
        XCTAssertEqual(withPartial?.partial, partial)

        let bare = DeviceRegistry.unsupportedPayload(of: PlannedState.unsupported(.hidpp10(major: 1, minor: 0), nil))
        XCTAssertEqual(bare?.reason, .hidpp10(major: 1, minor: 0))
        XCTAssertNil(bare?.partial ?? nil)

        XCTAssertEqual(DeviceRegistry.unsupportedPayload(of: LabeledState.unsupported(reason: .noReprogControls, partial: partial))?.partial, partial)
        XCTAssertEqual(DeviceRegistry.unsupportedPayload(of: ReasonOnlyState.unsupported(.noConfigurableControls))?.reason, .noConfigurableControls)

        XCTAssertNil(DeviceRegistry.unsupportedPayload(of: PlannedState.probing))
        XCTAssertNil(DeviceRegistry.unsupportedPayload(of: PlannedState.connected(partial)))
        XCTAssertNil(DeviceRegistry.unsupportedPayload(of: PlannedState.failed("unsupported")))
        let today: [EndpointController.State] = [.probing, .waitingForDevice, .connected(partial), .asleep(partial), .failed("unsupported")]
        for state in today {
            XCTAssertNil(DeviceRegistry.unsupportedPayload(of: state), "\(state)")
        }
        XCTAssertNil(DeviceRegistry.unsupportedPayload(of: "unsupported"))
    }

    // MARK: Summary

    func testSummaryLowestBatteryAndAnyPresent() async {
        let registry = makeRegistry()
        XCTAssertEqual(registry.summary, FleetSummary())
        XCTAssertFalse(registry.summary.anyPresent)

        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver, battery: 50)
        connect(registry, DeviceProfiles.mxMaster3S, .bolt, at: usb, battery: 25)
        var summary = registry.summary
        XCTAssertTrue(summary.anyConnected)
        XCTAssertTrue(summary.anyPresent)
        XCTAssertEqual(summary.connectedCount, 2)
        XCTAssertEqual(summary.lowestBattery?.address, usb)
        XCTAssertEqual(summary.lowestBattery?.status.percentage, 25)

        // A standby link to the Master isn't another mouse, whatever it reports.
        connect(registry, DeviceProfiles.mxMaster3S, .bluetooth, at: bluetooth, battery: 5)
        XCTAssertEqual(registry.record(bluetooth)?.role, .standby(of: usb))
        summary = registry.summary
        XCTAssertEqual(summary.connectedCount, 2)
        XCTAssertEqual(summary.lowestBattery?.address, usb)
        registry.removeLink(bluetooth.link)

        // Only connected mice count for the battery; asleep ones still count as present.
        putToSleep(registry, DeviceProfiles.mxMaster3S, .bolt, at: usb)
        summary = registry.summary
        XCTAssertEqual(summary.lowestBattery?.address, receiver)
        XCTAssertEqual(summary.connectedCount, 1)

        putToSleep(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        summary = registry.summary
        XCTAssertFalse(summary.anyConnected)
        XCTAssertTrue(summary.anyPresent)
        XCTAssertEqual(summary.connectedCount, 0)
        XCTAssertNil(summary.lowestBattery)

        // Waiting without a session is neither connected nor present (2.x: "has a snapshot").
        registry.update(receiver, connection: .unifying, state: .waitingForDevice)
        registry.update(usb, connection: .bolt, state: .waitingForDevice)
        XCTAssertFalse(registry.summary.anyPresent)
        XCTAssertTrue(registry.summary.problems.isEmpty)

        // A tie goes to the mouse listed first.
        connect(registry, DeviceProfiles.mxMaster3S, .bolt, at: usb, battery: 40)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver, battery: 40)
        XCTAssertEqual(registry.summary.lowestBattery?.address, receiver)
    }

    // MARK: Removal

    func testRemoveLinkRemovesAllItsEndpoints() async {
        let registry = makeRegistry()
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        connect(registry, DeviceProfiles.mxMaster3, .unifying, at: receiverSlot2)
        registry.update(receiverSlot3, connection: .unifying, state: .probing)
        connect(registry, DeviceProfiles.lift, .bluetooth, at: bluetooth)

        changes = 0
        XCTAssertEqual(registry.removeLink(receiver.link), [receiver, receiverSlot2, receiverSlot3])
        XCTAssertEqual(registry.records.map(\.address), [bluetooth])
        XCTAssertEqual(changes, 1)

        XCTAssertEqual(registry.removeLink(receiver.link), [])
        registry.remove(receiver)
        registry.remove(DeviceAddress(link: 9, index: 1))
        XCTAssertEqual(changes, 1)
        XCTAssertNil(registry.record(receiverSlot2))
        XCTAssertTrue(registry.addresses(of: unitID(DeviceProfiles.mxVertical)).isEmpty)
    }

    // MARK: Identity, names, notifications

    func testIdentityKeptWhileAsleepOrRetried() async {
        let registry = makeRegistry()
        let vertical = unitID(DeviceProfiles.mxVertical)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        for state in [EndpointController.State.waitingForDevice, .probing, .failed("Disconnected")] {
            registry.update(receiver, connection: .unifying, state: state)
            let record = registry.record(receiver)
            XCTAssertEqual(record?.state, state)
            XCTAssertEqual(record?.deviceID, vertical, "\(state)")
            XCTAssertEqual(record?.model, .mxVertical, "\(state)")
            XCTAssertEqual(record?.displayName, "MX Vertical", "\(state)")
            XCTAssertEqual(record?.role, .active, "\(state)")
            XCTAssertNil(record?.snapshot)
        }
        XCTAssertEqual(registry.summary.problems, [receiver])

        // Another device in the slot (the hub normally removes the old one first) takes over the record.
        connect(registry, DeviceProfiles.mxMaster3, .unifying, at: receiver)
        XCTAssertEqual(registry.record(receiver)?.deviceID, unitID(DeviceProfiles.mxMaster3))
        XCTAssertNotEqual(registry.record(receiver)?.model, .mxVertical)
    }

    func testLegacySnapshotWithoutIdentityIsATransientMXVertical() async {
        let registry = makeRegistry()
        var legacy = identified(DeviceProfiles.mxVertical, connection: .bluetooth, at: bluetooth)
        legacy.identity = nil
        registry.update(bluetooth, connection: .bluetooth, state: .connected(legacy))
        let record = registry.record(bluetooth)
        XCTAssertEqual(record?.model, .mxVertical)
        XCTAssertEqual(record?.deviceID, .transient(bluetooth))
        XCTAssertEqual(record?.role, .active)
    }

    func testProspectiveRoleForConnectingEndpoint() async {
        let registry = makeRegistry()
        let vertical = identified(DeviceProfiles.mxVertical, connection: .unifying, at: receiver)
        XCTAssertEqual(registry.prospectiveRole(receiver, snapshot: vertical), .active)
        XCTAssertTrue(registry.records.isEmpty)
        XCTAssertEqual(changes, 0)

        // Probing at that address already: still the one to serve.
        registry.update(receiver, connection: .unifying, state: .probing)
        XCTAssertEqual(registry.prospectiveRole(receiver, snapshot: vertical), .active)

        // With the same unit on USB, the receiver endpoint would be a standby.
        connect(registry, DeviceProfiles.mxVertical, .usb, at: usb)
        XCTAssertEqual(registry.prospectiveRole(receiver, snapshot: vertical), .standby(of: usb))

        // Asking changes nothing.
        changes = 0
        let before = registry.records
        let cable = identified(DeviceProfiles.mxVertical, connection: .usb, at: usb)
        XCTAssertEqual(registry.prospectiveRole(usb, snapshot: cable), .active)
        XCTAssertEqual(registry.records, before)
        XCTAssertEqual(changes, 0)

        // A better link connecting would take over from an active receiver endpoint.
        registry.removeLink(usb.link)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        let newCable = DeviceAddress(link: 7, index: DeviceAddress.direct)
        XCTAssertEqual(registry.prospectiveRole(newCable, snapshot: identified(DeviceProfiles.mxVertical, connection: .usb, at: newCable)), .active)
        XCTAssertEqual(registry.record(receiver)?.role, .active)

        // Mice without a unit ID never wait for one another.
        connect(registry, DeviceProfiles.mouseWithoutUnitID, .unifying, at: receiverSlot2)
        let other = identified(DeviceProfiles.mouseWithoutUnitID, connection: .usb, at: usb)
        XCTAssertEqual(registry.prospectiveRole(usb, snapshot: other), .active)
    }

    func testNicknamesAndDuplicateNames() async {
        let registry = makeRegistry()
        let first = unitID(DeviceProfiles.mxVertical)
        let second = unitID(DeviceProfiles.mxVerticalSecondUnit)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver)
        connect(registry, DeviceProfiles.mxVerticalSecondUnit, .unifying, at: receiverSlot2)
        // The catalog's model name, not the long name the mouse reports.
        XCTAssertEqual(registry.records.map(\.displayName), ["MX Vertical", "MX Vertical #2"])

        // A model the catalog doesn't know keeps the name it reports.
        var prototype = DeviceProfiles.mxMaster3S.named("Prototype Mouse")
        prototype.modelIDs = ModelIDs(bluetoothLE: 0xABCD)
        connect(registry, prototype, .bluetooth, at: bluetooth)
        XCTAssertNil(DeviceCatalog.model(ModelKey(productID: 0xABCD)))
        XCTAssertEqual(registry.record(bluetooth)?.displayName, "Prototype Mouse")

        // Nicknames, read again on request; blank ones are ignored.
        var nicknames: [DeviceID: String] = [second: "Desk", first: "   "]
        registry.nameProvider = { nicknames[$0] }
        changes = 0
        registry.refreshNames()
        XCTAssertEqual(registry.records.map(\.displayName), ["MX Vertical", "Desk", "Prototype Mouse"])
        XCTAssertEqual(changes, 1)
        registry.refreshNames()
        XCTAssertEqual(changes, 1)

        // Without nicknames, numbers follow the units. Both leave with their receiver; the second
        // comes back first and is just "MX Vertical"; when the first one returns on another link
        // it takes its first-seen place and the plain name again.
        nicknames = [:]
        registry.refreshNames()
        registry.removeLink(receiver.link)
        connect(registry, DeviceProfiles.mxVerticalSecondUnit, .unifying, at: DeviceAddress(link: 4, index: 2))
        XCTAssertEqual(registry.records.first?.displayName, "MX Vertical")
        let back = DeviceAddress(link: 5, index: DeviceAddress.direct)
        connect(registry, DeviceProfiles.mxVertical, .usb, at: back)
        XCTAssertEqual(registry.records.map(\.address), [back, DeviceAddress(link: 4, index: 2), bluetooth])
        XCTAssertEqual(registry.records.map(\.displayName), ["MX Vertical", "MX Vertical #2", "Prototype Mouse"])
    }

    func testOnChangeOnlyWhenRecordsChange() async {
        let registry = makeRegistry()
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver, battery: 50)
        XCTAssertEqual(changes, 1)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver, battery: 50)
        XCTAssertEqual(changes, 1)
        connect(registry, DeviceProfiles.mxVertical, .unifying, at: receiver, battery: 45)
        XCTAssertEqual(changes, 2)
        registry.refreshNames()
        XCTAssertEqual(changes, 2)
    }

    func testLinkRank() async {
        XCTAssertLessThan(DeviceRegistry.linkRank(.usb), DeviceRegistry.linkRank(.unifying))
        XCTAssertEqual(DeviceRegistry.linkRank(.unifying), DeviceRegistry.linkRank(.bolt))
        XCTAssertEqual(DeviceRegistry.linkRank(.bolt), DeviceRegistry.linkRank(.nano))
        XCTAssertLessThan(DeviceRegistry.linkRank(.nano), DeviceRegistry.linkRank(.bluetooth))
    }
}
