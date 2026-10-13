import XCTest
@testable import UprightKit

final class CatalogTests: XCTestCase {
    // MARK: Models

    func testEveryCatalogPIDUniqueAcrossModels() {
        var owner: [UInt16: ModelKey] = [:]
        for model in DeviceCatalog.models {
            for pid in model.allPIDs {
                if let other = owner[pid] {
                    XCTFail("PID \(String(pid, radix: 16)) is claimed by both \(other) and \(model.key)")
                }
                owner[pid] = model.key
            }
            XCTAssertEqual(Set(model.allPIDs).count, model.allPIDs.count, "\(model.name) repeats a PID")
        }
        XCTAssertEqual(Set(DeviceCatalog.models.map(\.key)).count, DeviceCatalog.models.count, "model keys are unique")
        XCTAssertEqual(Set(DeviceCatalog.models.map(\.name)).count, DeviceCatalog.models.count, "model names are unique")

        // Receivers and gaming mice never collide with a model either.
        for pid in DeviceCatalog.receivers.keys {
            XCTAssertNil(DeviceCatalog.model(forPID: pid), "receiver \(String(pid, radix: 16)) is not a mouse")
        }
        for device in DeviceCatalog.knownUnsupported {
            for pid in device.allPIDs {
                XCTAssertNil(owner[pid], "\(device.name) is not served, but \(String(pid, radix: 16)) belongs to a model")
            }
        }
    }

    func testMXVerticalEntryMatchesShippedBehaviour() throws {
        let model = try XCTUnwrap(DeviceCatalog.model(.mxVertical))
        XCTAssertEqual(DeviceCatalog.models.first?.key, .mxVertical, "the MX Vertical is listed first")
        XCTAssertEqual(model.key.rawValue, "046D:B020")
        XCTAssertEqual(model.name, "MX Vertical")
        XCTAssertEqual(model.usbPIDs, [0xC08A])
        XCTAssertEqual(model.bluetoothPIDs, [0xB020])
        XCTAssertEqual(model.wirelessPIDs, [0x407B])
        XCTAssertEqual(model.verification, .hardware)
        XCTAssertEqual(model.suggested, ButtonMappings.legacyDefaults)
        XCTAssertEqual(model.controlOrder, [0x53, 0x56, 0xFD, 0x52], "Back, Forward, Top Button, Wheel Click")

        for pid: UInt16 in [0xC08A, 0xB020, 0x407B] {
            XCTAssertEqual(DeviceCatalog.model(forPID: pid)?.key, .mxVertical)
        }
        // Each control reads exactly as Upright has always shown it.
        for cid in [KnownControl.back, KnownControl.forward, KnownControl.dpiSwitch, KnownControl.dpiChange, KnownControl.middleClick] {
            XCTAssertEqual(ControlCatalog.text(for: cid, model: .mxVertical), ControlDescriptor(cid: cid).text)
        }
    }

    func testEveryControlOrderCIDIsNamed() {
        for model in DeviceCatalog.models {
            XCTAssertFalse(model.controlOrder.isEmpty, "\(model.name) lists no controls")
            XCTAssertEqual(Set(model.controlOrder).count, model.controlOrder.count, "\(model.name) repeats a control")
            for cid in model.controlOrder {
                XCTAssertNotNil(ControlCatalog.solaarName(for: cid), "\(model.name): 0x\(String(cid, radix: 16)) has no Solaar name")
                XCTAssertNotNil(ControlCatalog.genericText[cid] ?? model.controlText[cid], "\(model.name): 0x\(String(cid, radix: 16)) has no wording")
                XCTAssertFalse(ControlCatalog.neverDivert.contains(cid), "\(model.name) offers a primary click")
                XCTAssertNotEqual(cid, KnownControl.virtualGesture, "\(model.name) offers the virtual gesture control")
                XCTAssertFalse(ControlCatalog.text(for: cid, model: model.key).name.hasPrefix("Button 0x"), "\(model.name): 0x\(String(cid, radix: 16)) falls back")
            }
            for cid in model.controlText.keys {
                XCTAssertNotNil(ControlCatalog.solaarName(for: cid), "\(model.name) overrides an unnamed control")
            }
        }
    }

    func testControlTextFallbacks() {
        // Unknown control: the hex fallback, on any model.
        let unknown = ControlCatalog.text(for: 0x0777, model: nil)
        XCTAssertEqual(unknown.name, "Button 0x0777")
        XCTAssertEqual(unknown.detail, "Additional programmable control")
        XCTAssertEqual(unknown.symbolName, "button.programmable")
        XCTAssertEqual(ControlCatalog.text(for: 0x0777, model: .mxVertical), unknown)

        // Generic name when the model has no override, or isn't in the catalog at all.
        let tilt = ControlCatalog.text(for: KnownControl.tiltLeft, model: nil)
        XCTAssertEqual(tilt.name, "Tilt Left")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.tiltLeft, model: .mxVertical), tilt)
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.tiltLeft, model: ModelKey(productID: 0x1234)), tilt)
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.tiltLeft, model: ModelKey(name: "Some Mouse")), tilt)

        // The model's own wording beats the generic one.
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.back, model: nil).detail, "Thumb button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.back, model: .mxVertical).detail, "Lower thumb button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.dpiSwitch, model: nil).name, "DPI Switch Button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.dpiSwitch, model: .mxVertical).name, "Top Button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.dpiSwitch, model: DeviceCatalog.lift.key).name, "Top Button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.dpiChange, model: DeviceCatalog.mxErgo.key).name, "Precision Button")
        XCTAssertEqual(ControlCatalog.text(for: KnownControl.dpiChange, model: DeviceCatalog.mxVertical.key).name, "Top Button")

        // ControlDescriptor(cid:model:) goes through the same lookup.
        XCTAssertEqual(ControlDescriptor(cid: KnownControl.tiltLeft, model: nil).name, "Tilt Left")
        XCTAssertEqual(ControlDescriptor(cid: KnownControl.forward, model: DeviceCatalog.mxMaster3S.key).detail, "Thumb button")
        XCTAssertEqual(ControlDescriptor(cid: KnownControl.forward, model: .mxVertical).detail, "Upper thumb button")
        XCTAssertEqual(ControlDescriptor(cid: 0x0777, model: nil).name, "Button 0x0777")
        XCTAssertEqual(ControlDescriptor(cid: KnownControl.tiltLeft, model: nil).hexID, "0x005B")
    }

    func testOldControlDescriptorInitKeepsMXVerticalWording() {
        let expectations: [(UInt16, String, String, String)] = [
            (KnownControl.back, "Back Button", "Lower thumb button", "chevron.backward.circle"),
            (KnownControl.forward, "Forward Button", "Upper thumb button", "chevron.forward.circle"),
            (KnownControl.dpiSwitch, "Top Button", "Pointer-speed (DPI) button behind the wheel", "speedometer"),
            (KnownControl.dpiChange, "Top Button", "Pointer-speed (DPI) button behind the wheel", "speedometer"),
            (KnownControl.middleClick, "Wheel Click", "Press the scroll wheel", "smallcircle.filled.circle"),
            (0x1234, "Control 0x1234", "Additional programmable control", "button.programmable"),
            // Controls the 1.x app never named keep the "Control 0x" wording here, whatever the catalog calls them.
            (KnownControl.tiltLeft, "Control 0x005B", "Additional programmable control", "button.programmable"),
        ]
        for (cid, name, detail, symbol) in expectations {
            let descriptor = ControlDescriptor(cid: cid)
            XCTAssertEqual(descriptor.cid, cid)
            XCTAssertEqual(descriptor.name, name)
            XCTAssertEqual(descriptor.detail, detail)
            XCTAssertEqual(descriptor.symbolName, symbol)
            XCTAssertEqual(descriptor.id, cid)
        }
        XCTAssertEqual(ControlDescriptor(cid: 0x0053).hexID, "0x0053")
    }

    // MARK: Control names

    func testAllSolaarControlNamesAreCovered() {
        let expected: [UInt16] = [
            0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
            0x97, 0xAC, 0xB7, 0xB8, 0xB9, 0xC3, 0xC4, 0xCE, 0xCF, 0xD0, 0xD7, 0xD8, 0xED, 0xFD, 0x102, 0x1A0, 0x1B4,
        ]
        XCTAssertEqual(expected.count, 33)
        XCTAssertEqual(ControlCatalog.namedControls, expected)
        XCTAssertEqual(Set(ControlCatalog.genericText.keys), Set(expected))
        for cid in expected {
            let text = ControlCatalog.text(for: cid, model: nil)
            XCTAssertFalse(text.name.isEmpty)
            XCTAssertFalse(text.detail.isEmpty)
            XCTAssertFalse(text.symbolName.isEmpty)
            XCTAssertFalse(text.name.hasPrefix("Button 0x"), "0x\(String(cid, radix: 16)) uses the fallback")
        }
        let names = expected.map { ControlCatalog.text(for: $0, model: nil).name }
        XCTAssertEqual(Set(names).count, names.count, "generic names are distinct")

        XCTAssertEqual(ControlCatalog.solaarName(for: 0x00C3), "Mouse Gesture Button")
        XCTAssertEqual(ControlCatalog.solaarName(for: 0x00FD), "DPI Switch")
        XCTAssertEqual(ControlCatalog.solaarName(for: 0x01B4), "AI")
        XCTAssertNil(ControlCatalog.solaarName(for: 0x0777))
    }

    func testKnownControlIDsMatchSolaar() {
        XCTAssertEqual(KnownControl.leftClick, 0x50)
        XCTAssertEqual(KnownControl.rightClick, 0x51)
        XCTAssertEqual(KnownControl.middleClick, 0x52)
        XCTAssertEqual(KnownControl.back, 0x53)
        XCTAssertEqual(KnownControl.forward, 0x56)
        XCTAssertEqual(KnownControl.tiltLeft, 0x5B)
        XCTAssertEqual(KnownControl.tiltRight, 0x5D)
        XCTAssertEqual(KnownControl.gestureButton, 0xC3)
        XCTAssertEqual(KnownControl.smartShift, 0xC4)
        XCTAssertEqual(KnownControl.multiPlatformGesture, 0xD0)
        XCTAssertEqual(KnownControl.virtualGesture, 0xD7)
        XCTAssertEqual(KnownControl.dpiChange, 0xED)
        XCTAssertEqual(KnownControl.dpiSwitch, 0xFD)
        XCTAssertEqual(KnownControl.hapticSense, 0x1A0)
        XCTAssertEqual(KnownControl.primaryClicks, [0x50, 0x51])
        XCTAssertEqual(ControlCatalog.neverDivert, [0x50, 0x51])
    }

    // MARK: Model entries

    func testResearchedModelsArePresentWithTheirIDs() throws {
        // (name, canonical key, Bluetooth PIDs, wireless PIDs, USB PIDs)
        let expectations: [(String, UInt16, [UInt16], [UInt16], [UInt16])] = [
            ("MX Master", 0xB012, [0xB012, 0xB01E], [0x4041, 0x4071], []),
            ("MX Master 2S", 0xB019, [0xB019], [0x4069], []),
            ("MX Master 3", 0xB023, [0xB023], [0x4082], []),
            ("MX Master 3 for Business", 0xB028, [0xB028], [0xB028], []),
            ("MX Master 3S", 0xB034, [0xB034], [0xB034], []),
            ("MX Master 4", 0xB042, [0xB042], [], []),
            ("MX Anywhere 2", 0xB013, [0xB013, 0xB018, 0xB01F], [0x404A, 0x4072, 0x4063], []),
            ("MX Anywhere 2S", 0xB01A, [0xB01A], [0x406A], []),
            ("MX Anywhere 3", 0xB025, [0xB025], [0x4090], []),
            ("MX Anywhere 3 for Business", 0xB02D, [0xB02D], [0xB02D], []),
            ("MX Ergo", 0xB01D, [0xB01D], [0x406F], []),
            ("Lift", 0xB031, [0xB031], [0xB031], []),
            ("Lift for Business", 0xB033, [0xB033], [0xB033], []),
            ("M720 Triathlon", 0xB015, [0xB015], [0x405E], []),
            ("M585 / M590", 0xB01B, [0xB01B], [0x406B], []),
            ("Signature M650 L", 0xB02A, [0xB02A], [0xB02A], []),
            ("Signature M550", 0xB02B, [0xB02B], [0xB02B], []),
            ("ERGO M575", 0xB027, [0xB027], [0x4096], []),
            ("Marathon M705", 0x406D, [], [0x406D], []),
            ("Pebble M350", 0xB021, [0xB021], [0x4080], []),
            ("M510 (v2)", 0x4051, [], [0x4051], []),
            ("M185 / M235 / M310", 0x4055, [], [0x4055], []),
        ]
        for (name, key, bluetooth, wireless, usb) in expectations {
            let model = try XCTUnwrap(DeviceCatalog.models.first { $0.name == name }, name)
            XCTAssertEqual(model.key, ModelKey(productID: key), name)
            XCTAssertEqual(model.bluetoothPIDs, bluetooth, name)
            XCTAssertEqual(model.wirelessPIDs, wireless, name)
            XCTAssertEqual(model.usbPIDs, usb, name)
            XCTAssertEqual(DeviceCatalog.model(model.key)?.name, name)
            XCTAssertEqual(model.verification, .publishedDump, "\(name) hasn't been tested on hardware")
            for pid in model.allPIDs {
                XCTAssertEqual(DeviceCatalog.model(forPID: pid)?.key, model.key, "\(name) \(String(pid, radix: 16))")
            }
        }
        XCTAssertEqual(DeviceCatalog.models.count, expectations.count + 1, "every model is covered above, plus the MX Vertical")
    }

    func testModelKeyIsTheCanonicalIDOfEveryEntry() {
        for model in DeviceCatalog.models {
            guard let canonical = model.bluetoothPIDs.first ?? model.wirelessPIDs.first ?? model.usbPIDs.first else {
                XCTFail("\(model.name) has no PID")
                continue
            }
            XCTAssertEqual(model.key, ModelKey(productID: canonical), "\(model.name): first Bluetooth, else wireless, else USB (D5)")
        }
    }

    func testOnlyTheMXVerticalIsVerifiedOnHardware() {
        XCTAssertEqual(DeviceCatalog.models.filter { $0.verification == .hardware }.map(\.key), [.mxVertical])
        XCTAssertTrue(DeviceCatalog.models.dropFirst().allSatisfy { $0.verification == .publishedDump })
        XCTAssertEqual(DeviceModel.Verification.publishedData, .publishedDump)
    }

    func testSuggestedPerModel() throws {
        let navigation: ButtonMappings = ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.forward: .system(.navigateForward),
        ])
        XCTAssertEqual(DeviceCatalog.mxVertical.suggested, .legacyDefaults)

        // Back and Forward navigate; a gesture button opens Mission Control.
        let master = ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.forward: .system(.navigateForward),
            KnownControl.gestureButton: .system(.missionControl),
        ])
        for model in [DeviceCatalog.mxMaster, DeviceCatalog.mxMaster2S, DeviceCatalog.mxMaster3, DeviceCatalog.mxMaster3S, DeviceCatalog.mxMaster4] {
            XCTAssertEqual(model.suggested, master, model.name)
        }
        XCTAssertEqual(DeviceCatalog.m720.suggested, ButtonMappings([
            KnownControl.back: .system(.navigateBack),
            KnownControl.forward: .system(.navigateForward),
            KnownControl.multiPlatformGesture: .system(.missionControl),
        ]))
        for model in [DeviceCatalog.mxAnywhere3, DeviceCatalog.lift, DeviceCatalog.mxErgo, DeviceCatalog.m575] {
            XCTAssertEqual(model.suggested, navigation, model.name)
        }
        // Nothing to suggest without those buttons.
        for model in [DeviceCatalog.m550, DeviceCatalog.pebbleM350, DeviceCatalog.m185] {
            XCTAssertTrue(model.suggested.isEmpty, model.name)
        }
        XCTAssertEqual(DeviceCatalog.suggestedMappings(forControls: []), ButtonMappings())
        XCTAssertEqual(DeviceCatalog.suggestedMappings(forControls: [KnownControl.back]), ButtonMappings([KnownControl.back: .system(.navigateBack)]))
        // The suggestion only ever touches controls the model offers.
        for model in DeviceCatalog.models.dropFirst() {
            XCTAssertTrue(Set(model.suggested.mappedControls.keys).isSubset(of: Set(model.controlOrder)), model.name)
        }
    }

    func testControlsSortInDisplayOrder() {
        let vertical = DeviceCatalog.mxVertical
        XCTAssertEqual(vertical.displayOrder([0x52, 0xFD, 0x56, 0x53]), [0x53, 0x56, 0xFD, 0x52])
        // Controls the model doesn't list follow, by CID.
        XCTAssertEqual(vertical.displayOrder([0x5D, 0x52, 0x5B, 0x53]), [0x53, 0x52, 0x5B, 0x5D])
        XCTAssertEqual(DeviceCatalog.sortedControls([0x52, 0xFD, 0x56, 0x53], for: .mxVertical), [0x53, 0x56, 0xFD, 0x52])
        XCTAssertEqual(DeviceCatalog.sortedControls([0xFD, 0x53, 0x52], for: nil), [0x52, 0x53, 0xFD])
        XCTAssertEqual(DeviceCatalog.sortedControls([0xFD, 0x53, 0x52], for: ModelKey(productID: 0x1234)), [0x52, 0x53, 0xFD])
        XCTAssertEqual(DeviceCatalog.sortedControls([], for: .mxVertical), [])
        XCTAssertEqual(
            DeviceCatalog.mxMaster4.displayOrder([0x52, 0xC4, 0x1A0, 0xC3, 0x56, 0x53]),
            [0x53, 0x56, 0xC3, 0x1A0, 0xC4, 0x52]
        )
    }

    // MARK: Receivers

    func testReceiversFollowTheSupportedList() {
        for pid: UInt16 in [0xC52B, 0xC532] {
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.kind, .unifying)
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.layout, .unifying)
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.family, .unifying)
        }
        XCTAssertEqual(DeviceCatalog.receivers[0xC548]?.kind, .bolt)
        XCTAssertEqual(DeviceCatalog.receivers[0xC548]?.layout, .bolt)
        XCTAssertEqual(DeviceCatalog.receivers[0xC548]?.family, .bolt)

        // Nano receivers pair like Unifying ones.
        let nano: [UInt16] = [0xC52F, 0xC531, 0xC534, 0xC537, 0xC518, 0xC51A, 0xC51B, 0xC521, 0xC525, 0xC526, 0xC52E, 0xC535]
        for pid in nano {
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.kind, .nano, String(pid, radix: 16))
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.layout, .unifying, String(pid, radix: 16))
            XCTAssertEqual(DeviceCatalog.receivers[pid]?.family, .nano, String(pid, radix: 16))
        }
        let served = DeviceCatalog.receivers.values.filter { $0.layout != nil }
        XCTAssertEqual(served.count, 2 + 1 + nano.count)
        XCTAssertTrue(served.allSatisfy { $0.exclusionReason == nil })
        XCTAssertTrue(DeviceCatalog.receivers.allSatisfy { $0.key == $0.value.productID })
    }

    func testLightspeedAnd27MHzReceiversAreNeverOpened() {
        let lightspeed: [UInt16] = [0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D]
        for pid in lightspeed {
            let receiver = DeviceCatalog.receivers[pid]
            XCTAssertNotNil(receiver, String(pid, radix: 16))
            XCTAssertNil(receiver?.layout, String(pid, radix: 16))
            XCTAssertEqual(receiver?.family, .lightspeed)
            XCTAssertEqual(receiver?.exclusionReason, "Lightspeed receiver: not supported (no programmable-button feature on its mice)")
        }
        XCTAssertNil(DeviceCatalog.receivers[0xC517]?.layout)
        XCTAssertEqual(DeviceCatalog.receivers[0xC517]?.family, .legacy27MHz)
        XCTAssertNotNil(DeviceCatalog.receivers[0xC517]?.exclusionReason)
        // Lenovo's 17EF:6042 is not matched.
        XCTAssertNil(DeviceCatalog.receivers[0x6042])
        XCTAssertEqual(DeviceCatalog.receivers.values.filter { $0.layout == nil }.count, lightspeed.count + 1)
    }

    func testGamingMiceAreListedAsKnownUnsupported() {
        XCTAssertEqual(DeviceCatalog.knownUnsupported.count, 9)
        XCTAssertEqual(DeviceCatalog.knownUnsupported(forPID: 0x407F)?.name, "G502 Lightspeed")
        XCTAssertEqual(DeviceCatalog.knownUnsupported(forPID: 0xC094)?.name, "PRO X Wireless")
        XCTAssertEqual(DeviceCatalog.knownUnsupported(forPID: 0xB024)?.name, "G604")
        XCTAssertNil(DeviceCatalog.knownUnsupported(forPID: 0xB020))
        for device in DeviceCatalog.knownUnsupported {
            XCTAssertNil(DeviceCatalog.model(forPID: device.allPIDs.first ?? 0), device.name)
            XCTAssertFalse(device.reason.isEmpty)
        }
    }

    // MARK: Model keys (D5)

    func testModelKeyForIdentityFollowsTheCanonicalRule() {
        func key(_ ids: ModelIDs, transportPID: UInt16? = nil, name: String = "Test Mouse") -> ModelKey {
            DeviceCatalog.modelKey(for: DeviceIdentity(name: name, modelIDs: ids, transportPID: transportPID))
        }

        // The MX Vertical is one model on every transport.
        XCTAssertEqual(key(ModelIDs(bluetoothLE: 0xB020, wireless: 0x407B, usb: 0xC08A)), .mxVertical)
        XCTAssertEqual(key(ModelIDs(usb: 0xC08A)), .mxVertical)
        XCTAssertEqual(key(ModelIDs(wireless: 0x407B)), .mxVertical)
        XCTAssertEqual(key(ModelIDs(bluetooth: 0xB020)), .mxVertical)
        XCTAssertEqual(key(ModelIDs(), transportPID: 0x407B), .mxVertical)
        XCTAssertEqual(key(ModelIDs(), transportPID: 0xC08A), .mxVertical)

        // Catalog aliases resolve to the canonical key.
        XCTAssertEqual(key(ModelIDs(bluetooth: 0xB01E, wireless: 0x4071)), ModelKey(productID: 0xB012))
        XCTAssertEqual(key(ModelIDs(wireless: 0x4071)), ModelKey(productID: 0xB012))
        XCTAssertEqual(key(ModelIDs(), transportPID: 0x4071), ModelKey(productID: 0xB012))
        XCTAssertEqual(key(ModelIDs(wireless: 0x4063)), ModelKey(productID: 0xB013))
        XCTAssertEqual(key(ModelIDs(bluetooth: 0xB01F)), ModelKey(productID: 0xB013))

        // Models the catalog has never seen get the key the catalog would give them: the first of
        // Bluetooth, Bluetooth LE, wireless, USB.
        XCTAssertEqual(key(ModelIDs(bluetooth: 0xAAA1, bluetoothLE: 0xAAA2, wireless: 0xAAA3, usb: 0xAAA4)), ModelKey(productID: 0xAAA1))
        XCTAssertEqual(key(ModelIDs(bluetoothLE: 0xAAA2, wireless: 0xAAA3, usb: 0xAAA4)), ModelKey(productID: 0xAAA2))
        XCTAssertEqual(key(ModelIDs(wireless: 0xAAA3, usb: 0xAAA4)), ModelKey(productID: 0xAAA3))
        XCTAssertEqual(key(ModelIDs(usb: 0xAAA4)), ModelKey(productID: 0xAAA4))
        XCTAssertEqual(key(ModelIDs(usb: 0xAAA4), transportPID: 0xBBB1), ModelKey(productID: 0xAAA4), "0x0003 wins over the transport PID")

        // No 0x0003 model IDs: the transport PID, else the name.
        XCTAssertEqual(key(ModelIDs(), transportPID: 0xBBB1), ModelKey(productID: 0xBBB1))
        XCTAssertEqual(key(ModelIDs(), name: "  Mystery Mouse "), ModelKey(name: "mystery mouse"))
        XCTAssertEqual(key(ModelIDs(), name: "Mystery Mouse").rawValue, "name:mystery mouse")

        // A known ID anywhere in the list picks the catalog model.
        XCTAssertEqual(key(ModelIDs(bluetooth: 0xAAA1, wireless: 0x407B)), .mxVertical)

        // The identity initializer uses the same rule.
        XCTAssertEqual(DeviceIdentity(name: "MX Vertical", modelIDs: ModelIDs(wireless: 0x407B)).model, .mxVertical)
        XCTAssertEqual(DeviceIdentity(name: "Mystery", modelIDs: ModelIDs(usb: 0xAAA4)).model, ModelKey(productID: 0xAAA4))
    }
}
