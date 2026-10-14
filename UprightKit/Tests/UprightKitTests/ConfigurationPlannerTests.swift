import XCTest
@testable import UprightKit

// MARK: Upright 2.x, quoted

/// What Upright 2.x's `AppModel.syncDiversion` (Upright/App/AppModel.swift at 9b0c592) asked the
/// connected mouse for, re-derived line by line. The quoted source:
///
///     /// The mappings in effect right now, for the frontmost app.
///     var effectiveMappings: ButtonMappings {
///         profiles.effectiveMappings(forBundleID: frontmostApp?.bundleID)
///     }
///
///     private func syncDiversion() {
///         let trusted = permissions.isAccessibilityTrusted
///         let mappings = effectiveMappings
///         let cids = isRemappingEnabled
///             ? mappings.divertedControls(accessibilityGranted: trusted).union(engine.pressedControls)
///             : []
///         let rawXY = isRemappingEnabled
///             ? mappings.gestureControls(accessibilityGranted: trusted).union(engine.gestureControls)
///             : []
///         updateMovementMonitor()
///         if rawXY != appliedRawXY {
///             appliedRawXY = rawXY
///             devices.setDesiredRawXY(rawXY)
///         }
///         guard cids != appliedDiversion else { return }
///         appliedDiversion = cids
///         devices.setDesiredDiversion(cids)
///     }
///
/// The pointer speed went separately: `devices.setDesiredDPI(settings.preferredDPI)`, whatever
/// the remapping switch says.
private func todaysSyncDiversion(
    profiles: MappingProfiles,
    frontmostBundleID: String?,
    trusted: Bool,
    isRemappingEnabled: Bool,
    pressedControls: Set<UInt16>,
    gestureControls: Set<UInt16>
) -> (cids: Set<UInt16>, rawXY: Set<UInt16>) {
    let mappings = profiles.effectiveMappings(forBundleID: frontmostBundleID)
    let cids = isRemappingEnabled
        ? mappings.divertedControls(accessibilityGranted: trusted).union(pressedControls)
        : []
    let rawXY = isRemappingEnabled
        ? mappings.gestureControls(accessibilityGranted: trusted).union(gestureControls)
        : []
    return (cids, rawXY)
}

/// What those sets became on the wire: 2.x's `MXVerticalController` handed them unchanged to
/// `DeviceSession.applyDiversion(desiredDiversion, rawXY: desiredRawXY)`, quoted:
///
///     let wanted = wanted.union(rawXY)
///     ...
///     for control in snapshot.configurableControls {
///         let divert = wanted.contains(control.cid)
///         // Raw XY bits are only sent to controls that advertise the capability.
///         let raw: Bool? = control.supportsRawXY ? divert && rawXY.contains(control.cid) : nil
///         let target = Reporting(diverted: divert, rawXY: raw ?? false)
///         ...
///         if divert { divertedControls.insert(control.cid) } else { divertedControls.remove(control.cid) }
///         if target.rawXY { rawXYControls.insert(control.cid) } else { rawXYControls.remove(control.cid) }
///     }
///
/// and the speed to `DeviceSession.setDPI(desired)`, which sends `dpi.nearest(to: value)` and
/// does nothing for a mouse without ADJUSTABLE_DPI.
private func todaysWireState(
    cids: Set<UInt16>,
    rawXY: Set<UInt16>,
    preferredDPI: Int?,
    snapshot: DeviceSnapshot
) -> EndpointConfiguration {
    let wanted = cids.union(rawXY)
    var diverted: Set<UInt16> = []
    var raw: Set<UInt16> = []
    for control in snapshot.configurableControls {
        let divert = wanted.contains(control.cid)
        let rawBit: Bool? = control.supportsRawXY ? divert && rawXY.contains(control.cid) : nil
        if divert { diverted.insert(control.cid) }
        if rawBit ?? false { raw.insert(control.cid) }
    }
    let dpi = preferredDPI.flatMap { preferred in snapshot.dpi.map { $0.nearest(to: preferred) } }
    return EndpointConfiguration(divert: diverted, rawXY: raw, dpi: dpi)
}

// MARK: Fixtures

private func dpiInfo(_ profile: SimulatedDeviceProfile) -> DPIInfo? {
    let supported = profile.supportedDPI
    guard !supported.isEmpty else { return nil }
    return DPIInfo(current: profile.defaultDPI ?? supported[0], defaultValue: profile.defaultDPI ?? supported[0], supported: supported)
}

/// A connected snapshot of a simulated mouse, as `DeviceSession.start()` reads it.
private func snapshot(_ profile: SimulatedDeviceProfile, connection: ConnectionKind = .unifying, index: UInt8 = 1) -> DeviceSnapshot {
    DeviceSnapshot(
        name: profile.name,
        connection: connection,
        deviceIndex: index,
        protocolVersion: "\(profile.protocolMajor).\(profile.protocolMinor)",
        features: [],
        controls: profile.controls,
        battery: BatteryStatus(percentage: profile.batteryLevel, isCharging: false),
        dpi: dpiInfo(profile),
        identity: DeviceIdentity(
            name: profile.name,
            kind: profile.kind,
            unitID: profile.unitID,
            serialNumber: profile.serialNumber,
            modelIDs: profile.modelIDs,
            transportPID: profile.wirelessPID
        ),
        address: DeviceAddress(link: 1, index: index)
    )
}

private let combo = KeyCombo(keyCode: KeyCode.t, modifiers: [.command, .shift], keyLabel: "T")
private let safari = "com.apple.Safari"
private let xcode = "com.apple.dt.Xcode"
private let mixedCase = "com.Example.MixedCase"

/// Setups a 2.x user could have had: fresh, the 1.x defaults, per-app profiles (one disabled),
/// every action kind with gestures, Accessibility-only actions, and junk an import could carry
/// (primary clicks, the virtual gesture button, other models' controls).
private var fixtures: [(name: String, profiles: MappingProfiles)] {
    var withApps = MappingProfiles(global: .legacyDefaults)
    withApps.upsert(AppProfile(bundleID: safari, displayName: "Safari", overrides: [
        KnownControl.back: .system(.previousTab),
        KnownControl.dpiSwitch: .deviceDefault,
    ]))
    withApps.upsert(AppProfile(bundleID: xcode, displayName: "Xcode", isEnabled: false, overrides: [
        KnownControl.back: .system(.undo),
    ]))

    let gestures = GestureSet(
        tap: .system(.missionControl),
        up: .keyCombo(KeyCombo(keyCode: KeyCode.c, modifiers: [.command, .option])),
        down: .launchApp(AppReference(bundleID: "com.apple.Terminal", displayName: "Terminal")),
        left: .openURL(URL(string: "https://example.com/left")!),
        right: .runShortcut("Make GIF")
    )
    var everyKind = MappingProfiles(global: ButtonMappings([
        KnownControl.back: .system(.navigateBack),
        KnownControl.forward: .keyCombo(combo),
        KnownControl.middleClick: .disabled,
        KnownControl.dpiSwitch: .gestures(gestures),
        KnownControl.gestureButton: .device(.cycleDPI),
        KnownControl.smartShift: .device(.setDPI(1200)),
        KnownControl.tiltLeft: .device(.switchHost(2)),
        KnownControl.tiltRight: .launchApp(AppReference(bundleID: safari, displayName: "Safari")),
        KnownControl.multiPlatformGesture: .openURL(URL(string: "mailto:me@example.com")!),
        KnownControl.dpiChange: .runShortcut("Toggle Focus"),
        0x0100: .system(.volumeUp),
    ]))
    everyKind.upsert(AppProfile(bundleID: safari, displayName: "Safari", overrides: [
        KnownControl.back: .system(.previousTab),
        KnownControl.dpiSwitch: .deviceDefault,
        KnownControl.forward: .gestures(GestureSet(up: .system(.nextTab), down: .deviceDefault)),
    ]))
    everyKind.upsert(AppProfile(bundleID: mixedCase, displayName: "Mixed", overrides: [
        KnownControl.middleClick: .system(.copy),
        KnownControl.gestureButton: .deviceDefault,
    ]))

    let accessibilityOnly = MappingProfiles(global: ButtonMappings([
        KnownControl.back: .keyCombo(combo),
        KnownControl.forward: .system(.playPause),
        KnownControl.middleClick: .system(.middleClick),
        KnownControl.dpiSwitch: .gestures(GestureSet(up: .keyCombo(combo))),
    ]))

    var junk = MappingProfiles(global: ButtonMappings([
        KnownControl.leftClick: .system(.copy),
        KnownControl.rightClick: .gestures(.standard),
        KnownControl.virtualGesture: .system(.missionControl),
        KnownControl.middleClick: .gestures(.standard),
        KnownControl.back: .gestures(GestureSet(tap: .system(.navigateBack))),
        KnownControl.gestureButton: .gestures(.standard),
    ]))
    junk.upsert(AppProfile(bundleID: safari, displayName: "Safari", overrides: [
        KnownControl.middleClick: .deviceDefault,
        KnownControl.forward: .gestures(.standard),
    ]))

    return [
        ("fresh", MappingProfiles()),
        ("legacy defaults", MappingProfiles(global: .legacyDefaults)),
        ("per-app profiles", withApps),
        ("every kind", everyKind),
        ("accessibility only", accessibilityOnly),
        ("junk", junk),
    ]
}

/// Every subset of `elements`.
private func subsets(of elements: [UInt16]) -> [Set<UInt16>] {
    (0..<(1 << elements.count)).map { mask in
        Set(elements.indices.filter { mask & (1 << $0) != 0 }.map { elements[$0] })
    }
}

final class ConfigurationPlannerTests: XCTestCase {
    func testMatchesTodaysSyncDiversionForMXVertical() {
        let vertical = snapshot(DeviceProfiles.mxVertical)
        XCTAssertEqual(vertical.modelKey, .mxVertical)
        XCTAssertEqual(Set(vertical.configurableControls.map(\.cid)), [0x52, 0x53, 0x56, 0xFD])

        let bundles: [String?] = [nil, safari, xcode, mixedCase, mixedCase.lowercased(), "com.example.unknown"]
        // What the engine can hold: the Vertical's buttons plus one it doesn't have.
        let holdable: [UInt16] = [0x52, 0x53, 0x56, 0xFD, 0xC3]
        var compared = 0
        for (name, profiles) in fixtures {
            // v2 data lands in the MX Vertical's model section (D6); the planner reads it from there.
            let library = MappingLibrary(migrating: profiles)
            for bundleID in bundles {
                let mappings = library.effectiveMappings(model: vertical.modelKey, bundleID: bundleID)
                XCTAssertEqual(mappings, profiles.effectiveMappings(forBundleID: bundleID), name)
                for trusted in [false, true] {
                    let gestureMapped = mappings.gestureControls(accessibilityGranted: trusted)
                    for enabled in [false, true] {
                        for held in subsets(of: holdable) {
                            // The engine's gestures are held controls; two sets that aren't
                            // check the planner doesn't rely on that.
                            let gestureSets: Set<Set<UInt16>> = [[], held, held.intersection(gestureMapped), [0xFD], [0x52, 0xC3]]
                            for gesturesHeld in gestureSets {
                                let today = todaysSyncDiversion(
                                    profiles: profiles,
                                    frontmostBundleID: bundleID,
                                    trusted: trusted,
                                    isRemappingEnabled: enabled,
                                    pressedControls: held,
                                    gestureControls: gesturesHeld
                                )
                                let expected = todaysWireState(cids: today.cids, rawXY: today.rawXY, preferredDPI: nil, snapshot: vertical)
                                let inputs = ConfigurationInputs(
                                    remappingEnabled: enabled,
                                    accessibilityGranted: trusted,
                                    held: held,
                                    gesturesHeld: gesturesHeld
                                )
                                let planned = ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: inputs)
                                let context = "\(name) / \(bundleID ?? "nil") / trusted \(trusted) / enabled \(enabled) / held \(held.sorted()) / gestures \(gesturesHeld.sorted())"
                                XCTAssertEqual(planned, expected, context)
                                XCTAssertEqual(
                                    ConfigurationPlanner.configuration(mappings: mappings, controls: vertical.controls, dpi: vertical.dpi, inputs: inputs),
                                    planned,
                                    context
                                )
                                // Nothing outside 2.x's own request ever gets diverted.
                                XCTAssertTrue(planned.divert.isSubset(of: today.cids.union(today.rawXY)), context)
                                XCTAssertTrue(planned.rawXY.isSubset(of: today.rawXY), context)
                                compared += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 10000)

        // The pointer speed: 2.x applied the preference with the mouse's nearest supported value,
        // with remapping on or off.
        for preferred in [nil, 400, 1000, 1225, 1234, 4000, 9000] as [Int?] {
            for enabled in [false, true] {
                let expected = todaysWireState(cids: [], rawXY: [], preferredDPI: preferred, snapshot: vertical)
                let planned = ConfigurationPlanner.configuration(
                    mappings: .defaults,
                    snapshot: vertical,
                    inputs: ConfigurationInputs(remappingEnabled: enabled, preferredDPI: preferred)
                )
                XCTAssertEqual(planned, expected, "\(preferred.map { "\($0)" } ?? "nil") DPI")
            }
        }
    }

    func testNewModelIsNative() {
        let library = MappingLibrary(migrating: MappingProfiles(global: .legacyDefaults))
        for profile in [DeviceProfiles.mxMaster3S, DeviceProfiles.lift, DeviceProfiles.m720, DeviceProfiles.mxErgo] {
            let mouse = snapshot(profile, connection: .bolt)
            XCTAssertNotEqual(mouse.modelKey, .mxVertical, profile.name)
            for bundleID in [nil, safari] as [String?] {
                let mappings = library.effectiveMappings(model: mouse.modelKey, bundleID: bundleID)
                for trusted in [false, true] {
                    let inputs = ConfigurationInputs(accessibilityGranted: trusted)
                    XCTAssertEqual(ConfigurationPlanner.configuration(mappings: mappings, snapshot: mouse, inputs: inputs), .native, profile.name)
                }
            }
        }
        // The MX Vertical in the same library keeps its setup.
        let vertical = snapshot(DeviceProfiles.mxVertical)
        let mappings = library.effectiveMappings(model: vertical.modelKey, bundleID: nil)
        XCTAssertEqual(ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: .init(accessibilityGranted: true)).divert, [0x53, 0x56, 0xFD])
    }

    func testRemapDisabledKeepsOnlyHeldUntilRelease() {
        let vertical = snapshot(DeviceProfiles.mxVertical)
        let gestures = ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.dpiSwitch: .gestures(GestureSet(up: .system(.missionControl))),
        ])
        var inputs = ConfigurationInputs(accessibilityGranted: true, deviceRemapEnabled: false, preferredDPI: 1600)

        // "Remap this mouse" off while Back and the gesture button are held: both stay diverted
        // (the gesture keeps its raw movement) so their releases arrive; nothing else is.
        inputs.held = [KnownControl.back, KnownControl.dpiSwitch]
        inputs.gesturesHeld = [KnownControl.dpiSwitch]
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: gestures, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(divert: [KnownControl.back, KnownControl.dpiSwitch], rawXY: [KnownControl.dpiSwitch], dpi: 1600)
        )

        // Back released, the gesture still going.
        inputs.held = [KnownControl.dpiSwitch]
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: gestures, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(divert: [KnownControl.dpiSwitch], rawXY: [KnownControl.dpiSwitch], dpi: 1600)
        )

        // Everything released: native buttons; the pointer speed is not remapping and stays.
        inputs.held = []
        inputs.gesturesHeld = []
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: gestures, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(dpi: 1600)
        )

        // Turned back on: the mappings return.
        inputs.deviceRemapEnabled = true
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: gestures, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(divert: [KnownControl.back, KnownControl.dpiSwitch], rawXY: [KnownControl.dpiSwitch], dpi: 1600)
        )

        // The app-wide switch off hands everything back at once, held buttons included (2.x).
        inputs.remappingEnabled = false
        inputs.held = [KnownControl.back]
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: gestures, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(dpi: 1600)
        )
    }

    func testStandbyIsNative() {
        let vertical = snapshot(DeviceProfiles.mxVertical, connection: .bluetooth, index: 0xFF)
        let mappings = ButtonMappings.legacyDefaults
        var inputs = ConfigurationInputs(accessibilityGranted: true, isActive: false, preferredDPI: 1600)
        XCTAssertEqual(ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: inputs), .native)
        XCTAssertEqual(ConfigurationPlanner.configuration(mappings: mappings, controls: vertical.controls, inputs: inputs), .native)

        // Demoted while Forward is held: only Forward stays diverted until it is released.
        inputs.held = [KnownControl.forward]
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(divert: [KnownControl.forward])
        )

        // Promoted: the full setup and the pointer speed.
        inputs.held = []
        inputs.isActive = true
        XCTAssertEqual(
            ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: inputs),
            EndpointConfiguration(divert: [KnownControl.back, KnownControl.forward, KnownControl.dpiSwitch], dpi: 1600)
        )
    }

    func testHeldKeepAliveIsPerDevice() {
        // Back is mapped globally, but the new frontmost app leaves it to the mouse.
        var profiles = MappingProfiles(global: .legacyDefaults)
        profiles.upsert(AppProfile(bundleID: safari, displayName: "Safari", overrides: [KnownControl.back: .deviceDefault]))
        let library = MappingLibrary(migrating: profiles)
        let a = snapshot(DeviceProfiles.mxVertical, connection: .usb, index: 0xFF)
        let b = snapshot(DeviceProfiles.mxVerticalSecondUnit, connection: .unifying, index: 2)
        XCTAssertEqual(a.modelKey, b.modelKey)
        let mappings = library.effectiveMappings(model: a.modelKey, bundleID: safari)

        // A still holds Back from before the switch; B holds nothing.
        let configA = ConfigurationPlanner.configuration(mappings: mappings, snapshot: a, inputs: ConfigurationInputs(accessibilityGranted: true, held: [KnownControl.back]))
        let configB = ConfigurationPlanner.configuration(mappings: mappings, snapshot: b, inputs: ConfigurationInputs(accessibilityGranted: true))
        XCTAssertEqual(configA.divert, [KnownControl.back, KnownControl.forward, KnownControl.dpiSwitch])
        XCTAssertEqual(configB.divert, [KnownControl.forward, KnownControl.dpiSwitch])

        // A releases Back: A follows the app too.
        XCTAssertEqual(ConfigurationPlanner.configuration(mappings: mappings, snapshot: a, inputs: ConfigurationInputs(accessibilityGranted: true)), configB)
    }

    func testRawXYOnlyForCapableControls() {
        // The Vertical's own table, except that the top button can't report raw movement.
        var vertical = snapshot(DeviceProfiles.mxVertical)
        vertical.controls = vertical.controls.map { control in
            var control = control
            if control.cid == KnownControl.dpiSwitch { control.additionalFlags &= ~UInt8(0x01) }
            return control
        }
        let mappings = ButtonMappings([
            KnownControl.middleClick: .gestures(.standard),
            KnownControl.dpiSwitch: .gestures(.standard),
            KnownControl.back: .system(.navigateBack),
        ])
        let config = ConfigurationPlanner.configuration(mappings: mappings, snapshot: vertical, inputs: ConfigurationInputs(accessibilityGranted: true))
        XCTAssertEqual(config.divert, [KnownControl.middleClick, KnownControl.dpiSwitch, KnownControl.back])
        XCTAssertEqual(config.rawXY, [KnownControl.middleClick])

        // A held gesture on a control without raw XY is still only diverted.
        let held = ConfigurationPlanner.configuration(
            mappings: .defaults,
            snapshot: vertical,
            inputs: ConfigurationInputs(held: [KnownControl.dpiSwitch, KnownControl.middleClick], gesturesHeld: [KnownControl.dpiSwitch, KnownControl.middleClick])
        )
        XCTAssertEqual(held.divert, [KnownControl.dpiSwitch, KnownControl.middleClick])
        XCTAssertEqual(held.rawXY, [KnownControl.middleClick])

        // Raw XY is always a subset of the diverted controls.
        XCTAssertTrue(config.rawXY.isSubset(of: config.divert))
    }

    func testNeverDivertPrimaryClicksEvenIfFlaggedDivertable() {
        // The M185 flags Left and Right divertable; an imported setup maps them.
        let m185 = snapshot(DeviceProfiles.m185, connection: .nano)
        XCTAssertTrue(m185.controls.contains { $0.cid == KnownControl.leftClick && $0.flags.contains(.divertable) })
        let mappings = ButtonMappings([
            KnownControl.leftClick: .system(.copy),
            KnownControl.rightClick: .gestures(.standard),
            KnownControl.middleClick: .system(.missionControl),
        ])
        let inputs = ConfigurationInputs(
            accessibilityGranted: true,
            held: [KnownControl.leftClick, KnownControl.rightClick],
            gesturesHeld: [KnownControl.rightClick]
        )
        let config = ConfigurationPlanner.configuration(mappings: mappings, snapshot: m185, inputs: inputs)
        XCTAssertEqual(config, EndpointConfiguration(divert: [KnownControl.middleClick]))

        // Even a table that claims Left is a plain configurable button can't get it diverted.
        let claimed = [ControlInfo(cid: KnownControl.leftClick, taskID: 0, flags: [.mouseButton, .reprogrammable, .divertable], additionalFlags: 0x01)]
        let forced = ConfigurationPlanner.configuration(mappings: mappings, controls: claimed, inputs: inputs)
        XCTAssertEqual(forced, .native)

        // The virtual gesture button (0xD7) and controls the mouse doesn't have aren't diverted either.
        let vertical = snapshot(DeviceProfiles.mxVertical)
        let foreign = ButtonMappings([
            KnownControl.virtualGesture: .system(.missionControl),
            KnownControl.gestureButton: .system(.missionControl),
            KnownControl.smartShift: .gestures(.standard),
        ])
        XCTAssertEqual(ConfigurationPlanner.configuration(mappings: foreign, snapshot: vertical, inputs: .init()), .native)
    }

    func testDPISnappedToDeviceList() {
        let vertical = snapshot(DeviceProfiles.mxVertical)
        XCTAssertEqual(vertical.dpi?.minimum, 400)
        XCTAssertEqual(vertical.dpi?.maximum, 4000)
        func dpi(_ preferred: Int?, _ device: DeviceSnapshot) -> Int? {
            ConfigurationPlanner.configuration(mappings: .defaults, snapshot: device, inputs: ConfigurationInputs(preferredDPI: preferred)).dpi
        }
        XCTAssertEqual(dpi(1234, vertical), 1250)
        XCTAssertEqual(dpi(1225, vertical), 1200, "a tie takes the lower value")
        XCTAssertEqual(dpi(100, vertical), 400)
        XCTAssertEqual(dpi(9000, vertical), 4000)
        XCTAssertNil(dpi(nil, vertical), "no preference leaves the mouse's own speed")

        // Each device snaps to its own list.
        let master = snapshot(DeviceProfiles.mxMaster3S, connection: .bolt)
        XCTAssertEqual(dpi(9000, master), 8000)
        XCTAssertEqual(dpi(100, master), 200)

        // No ADJUSTABLE_DPI: no speed at all.
        let m185 = snapshot(DeviceProfiles.m185, connection: .nano)
        XCTAssertNil(m185.dpi)
        XCTAssertNil(dpi(1200, m185))

        // Without a list (controls only) the preference passes through; the mouse snaps it.
        let passed = ConfigurationPlanner.configuration(mappings: .defaults, controls: vertical.controls, inputs: ConfigurationInputs(preferredDPI: 1234))
        XCTAssertEqual(passed.dpi, 1234)
        let listed = ConfigurationPlanner.configuration(mappings: .defaults, controls: vertical.controls, dpi: vertical.dpi, inputs: ConfigurationInputs(preferredDPI: 1234))
        XCTAssertEqual(listed.dpi, 1250)
    }
}
