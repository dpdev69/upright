import XCTest
@testable import UprightKit

/// D9 (which interfaces get opened), the keyboard-range exclusion, and the twin rules.
final class InterfaceClassifierTests: XCTestCase {
    // MARK: Fixtures

    private func descriptor(
        _ pid: Int,
        transport: String = "",
        page: Int = 0,
        usage: Int = 0,
        location: Int = 0,
        serial: String = "",
        registry: UInt64 = 0,
        vendor: Int = 0x046D
    ) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(
            vendorID: vendor,
            productID: pid,
            transport: transport,
            usagePage: page,
            usage: usage,
            locationID: location,
            serial: serial,
            registryID: registry,
            productName: "Test"
        )
    }

    private func classify(_ pid: Int, transport: String = "", page: Int = 0xFF00, usage: Int = 1) -> InterfaceClass {
        InterfaceClassifier.classify(descriptor(pid, transport: transport, page: page, usage: usage))
    }

    private func assertIgnored(_ class_: InterfaceClass, containing text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ignored(let reason) = class_ else {
            XCTFail("expected .ignored, got \(class_)", file: file, line: line)
            return
        }
        if let text {
            XCTAssertTrue(reason.lowercased().contains(text.lowercased()), "reason \"\(reason)\" should mention \"\(text)\"", file: file, line: line)
        }
    }

    // MARK: Receivers

    func testUnifyingBoltNanoAccepted() {
        XCTAssertEqual(classify(0xC52B, transport: "USB"), .receiver(.unifying, .unifying))
        XCTAssertEqual(classify(0xC532, transport: "USB"), .receiver(.unifying, .unifying))
        XCTAssertEqual(classify(0xC548, transport: "USB"), .receiver(.bolt, .bolt))

        // Nano receivers use the Unifying pairing layout (D8).
        let nano = [0xC52F, 0xC531, 0xC534, 0xC537, 0xC518, 0xC51A, 0xC51B, 0xC521, 0xC525, 0xC526, 0xC52E, 0xC535]
        for pid in nano {
            XCTAssertEqual(classify(pid, transport: "USB"), .receiver(.nano, .unifying), String(pid, radix: 16))
        }

        // Both HID++ vendor pages are accepted, and so is a descriptor with no usage information.
        XCTAssertEqual(classify(0xC52B, page: 0xFF43), .receiver(.unifying, .unifying))
        XCTAssertEqual(InterfaceClassifier.classify(descriptor(0xC52B)), .receiver(.unifying, .unifying))
        XCTAssertEqual(InterfaceClass.receiver(.bolt, .bolt).transportKind, .receiver(.bolt))
    }

    func testReceiverKeyboardAndMouseInterfacesAreNotOpened() {
        // The generic Logitech mouse matching also matches a receiver's boot-mouse interface.
        // Only the vendor-page interface carries HID++.
        assertIgnored(classify(0xC52B, transport: "USB", page: 0x01, usage: 0x02), containing: "HID++")
        assertIgnored(classify(0xC548, transport: "USB", page: 0x01, usage: 0x06), containing: "HID++")
        assertIgnored(classify(0xC52B, transport: "USB", page: 0x0C, usage: 0x01))
    }

    func testReceiverOnABluetoothOrVirtualTransportIsIgnored() {
        assertIgnored(classify(0xC52B, transport: "Bluetooth"))
        assertIgnored(classify(0xC52B, transport: "Virtual"))
    }

    func testLightspeedAnd27MHzIgnored() {
        let lightspeed = [0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D]
        for pid in lightspeed {
            let result = classify(pid, transport: "USB")
            assertIgnored(result, containing: "Lightspeed")
            XCTAssertNil(result.transportKind)
        }
        assertIgnored(classify(0xC539, transport: "USB"), containing: "programmable-button")
        assertIgnored(classify(0xC517, transport: "USB"), containing: "27 MHz")

        // The exclusion does not depend on the interface: the mouse interface is skipped too.
        assertIgnored(classify(0xC539, transport: "USB", page: 0x01, usage: 0x02), containing: "Lightspeed")

        // Lenovo's Nano clone (17EF:6042) is not matched: the vendor is not Logitech.
        assertIgnored(InterfaceClassifier.classify(descriptor(0x6042, transport: "USB", page: 0xFF00, vendor: 0x17EF)), containing: "Logitech")

        // An unlisted receiver PID is not guessed at.
        assertIgnored(classify(0xC5F0, transport: "USB"), containing: "receiver")
    }

    func testEveryCatalogReceiverWithoutALayoutIsIgnored() {
        for receiver in DeviceCatalog.receivers.values where receiver.layout == nil {
            assertIgnored(classify(Int(receiver.productID), transport: "USB"))
        }
        // And no catalog receiver may ever open a Lightspeed or 27 MHz PID.
        let excluded = InterfaceClassifier.lightspeedReceiverPIDs.union(InterfaceClassifier.legacyReceiverPIDs)
        for pid in excluded {
            assertIgnored(classify(Int(pid), transport: "USB"))
        }
    }

    // MARK: Direct mice

    func testDirectMouseRangesAcceptedKeyboardRangesIgnored() {
        // USB mice C07D...C094.
        for pid in [0xC07D, 0xC08A, 0xC094] {
            XCTAssertEqual(classify(pid, transport: "USB", page: 0xFF00), .direct(.usb), String(pid, radix: 16))
        }
        assertIgnored(classify(0xC07C, transport: "USB"), containing: "not a supported mouse")
        assertIgnored(classify(0xC077, transport: "USB", page: 0x01, usage: 0x02), containing: "not a supported mouse")
        assertIgnored(classify(0xC095, transport: "USB"), containing: "not a supported mouse")

        // USB keyboards C32B...C344 are excluded, and the gap just outside is not a mouse either.
        for pid in [0xC32B, 0xC330, 0xC344] {
            assertIgnored(classify(pid, transport: "USB"), containing: "keyboard")
        }
        assertIgnored(classify(0xC32A, transport: "USB"), containing: "not a supported mouse")
        assertIgnored(classify(0xC345, transport: "USB"), containing: "not a supported mouse")

        // Bluetooth mice B012...B0FF, over classic Bluetooth and Bluetooth LE.
        for pid in [0xB012, 0xB034, 0xB0FF] {
            XCTAssertEqual(classify(pid, transport: "Bluetooth Low Energy", page: 0x01, usage: 0x02), .direct(.bluetooth), String(pid, radix: 16))
            XCTAssertEqual(classify(pid, transport: "Bluetooth", page: 0xFF43), .direct(.bluetooth), String(pid, radix: 16))
        }
        assertIgnored(classify(0xB011, transport: "Bluetooth"), containing: "not a supported mouse")
        assertIgnored(classify(0xB100, transport: "Bluetooth"), containing: "not a supported mouse")

        // Bluetooth keyboards B317...B3FF.
        for pid in [0xB317, 0xB350, 0xB3FF] {
            assertIgnored(classify(pid, transport: "Bluetooth Low Energy", page: 0xFF43), containing: "keyboard")
        }
        assertIgnored(classify(0xB316, transport: "Bluetooth Low Energy"), containing: "not a supported mouse")

        XCTAssertEqual(InterfaceClass.direct(.bluetooth).transportKind, .direct(.bluetooth))
        XCTAssertNil(InterfaceClass.direct(.usb).ignoredReason)
        XCTAssertEqual(InterfaceClass.ignored("x").ignoredReason, "x")
    }

    func testMXVerticalIsStillServedOverEveryDirectTransport() {
        XCTAssertEqual(classify(0xC08A, transport: "USB"), .direct(.usb))
        XCTAssertEqual(classify(0xC08A, transport: "USB", page: 0x01, usage: 0x02), .direct(.usb))
        XCTAssertEqual(classify(0xB020, transport: "Bluetooth Low Energy", page: 0x01, usage: 0x02), .direct(.bluetooth))
        // The 0x407B wireless PID only appears behind a receiver; it is not an IOKit product ID.
        assertIgnored(classify(0x407B, transport: "USB"))
    }

    func testEveryCatalogUSBAndBluetoothPIDIsAcceptedOnItsTransport() {
        // The catalog is verified mouse data and wins over the generic ranges.
        for model in DeviceCatalog.models {
            for pid in model.usbPIDs {
                XCTAssertEqual(classify(Int(pid), transport: "USB", page: 0xFF00), .direct(.usb), "\(model.name) USB \(pid)")
                XCTAssertEqual(classify(Int(pid), page: 0xFF00), .direct(.usb), "\(model.name) USB \(pid) without a transport string")
            }
            for pid in model.bluetoothPIDs {
                XCTAssertEqual(classify(Int(pid), transport: "Bluetooth Low Energy", page: 0x01, usage: 0x02), .direct(.bluetooth), "\(model.name) BT \(pid)")
                XCTAssertEqual(classify(Int(pid), page: 0x01, usage: 0x02), .direct(.bluetooth), "\(model.name) BT \(pid) without a transport string")
            }
        }
    }

    func testTransportStringDecidesTheConnectionAndMismatchesAreIgnored() {
        XCTAssertEqual(classify(0xB020, transport: "Bluetooth"), .direct(.bluetooth))
        XCTAssertEqual(classify(0xB020, transport: "Bluetooth Low Energy"), .direct(.bluetooth))
        XCTAssertEqual(classify(0xB020, transport: " bluetooth low energy "), .direct(.bluetooth))
        XCTAssertEqual(classify(0xC08A, transport: "USB"), .direct(.usb))

        // A USB PID on a Bluetooth transport (and the reverse) is not a device we know.
        assertIgnored(classify(0xC08A, transport: "Bluetooth Low Energy"))
        assertIgnored(classify(0xB020, transport: "USB"))

        // Transports that are neither (a virtual HID device claiming Logitech's IDs, an internal bus).
        assertIgnored(classify(0xC08A, transport: "Virtual"), containing: "transport")
        assertIgnored(classify(0xB020, transport: "SPI"), containing: "transport")

        // No transport string: the PID decides.
        XCTAssertEqual(classify(0xC08A), .direct(.usb))
        XCTAssertEqual(classify(0xB020), .direct(.bluetooth))
        XCTAssertEqual(classify(0xB034), .direct(.bluetooth))
        XCTAssertEqual(classify(0xC084), .direct(.usb))
        assertIgnored(classify(0xC32B))
    }

    func testVendorsOtherThanLogitechAreIgnored() {
        for vendor in [0x05AC, 0x17EF, 0x1532, 0] {
            assertIgnored(InterfaceClassifier.classify(descriptor(0xC52B, vendor: vendor)), containing: "Logitech")
            assertIgnored(InterfaceClassifier.classify(descriptor(0xB020, vendor: vendor)), containing: "Logitech")
            assertIgnored(InterfaceClassifier.classify(descriptor(0xC08A, vendor: vendor)), containing: "Logitech")
        }
        assertIgnored(InterfaceClassifier.classify(descriptor(-1)), containing: "invalid")
        assertIgnored(InterfaceClassifier.classify(descriptor(0x1_0000)), containing: "invalid")
    }

    func testMatchCriteriaCoverVendorPagesAndGenericMouseWithoutProductIDs() {
        let criteria = InterfaceClassifier.matchCriteria
        XCTAssertTrue(criteria.allSatisfy { $0.vendorID == 0x046D })
        XCTAssertTrue(criteria.contains(HIDMatchCriterion(vendorID: 0x046D, usagePage: 0xFF00)))
        XCTAssertTrue(criteria.contains(HIDMatchCriterion(vendorID: 0x046D, usagePage: 0xFF43)))
        XCTAssertTrue(criteria.contains(HIDMatchCriterion(vendorID: 0x046D, usagePage: 0x01, usage: 0x02)))
        XCTAssertEqual(criteria.count, 3)
    }

    // MARK: Identity

    func testIdentityKeyFallsBackFromSerialToLocationToRegistryID() {
        let withSerial = descriptor(0xB020, page: 1, usage: 2, location: 0x1234, serial: "ABC123", registry: 77)
        XCTAssertEqual(InterfaceClassifier.identityKey(withSerial), "046D:B020:0001:0002:s:ABC123")

        let withLocation = descriptor(0xB020, page: 1, usage: 2, location: 0x1234, registry: 77)
        XCTAssertEqual(InterfaceClassifier.identityKey(withLocation), "046D:B020:0001:0002:l:1234")

        let bare = descriptor(0xB020, page: 1, usage: 2, registry: 0x4D)
        XCTAssertEqual(InterfaceClassifier.identityKey(bare), "046D:B020:0001:0002:r:4d")

        // A whitespace-only serial counts as none.
        let blank = descriptor(0xB020, page: 1, usage: 2, location: 0x1234, serial: "  ")
        XCTAssertEqual(InterfaceClassifier.identityKey(blank), InterfaceClassifier.identityKey(withLocation))

        // Interfaces of one device differ by page and usage, so they are never one identity.
        let vendor = descriptor(0xB020, page: 0xFF43, usage: 1, location: 0x1234, serial: "ABC123")
        XCTAssertNotEqual(InterfaceClassifier.identityKey(vendor), InterfaceClassifier.identityKey(withSerial))
    }

    func testBLETwinsWithEmptySerialStaySeparateByRegistryID() {
        // Two identical BLE mice that report neither a serial nor a location.
        let a = descriptor(0xB034, transport: "Bluetooth Low Energy", page: 1, usage: 2, registry: 0x1000_0AAA)
        let b = descriptor(0xB034, transport: "Bluetooth Low Energy", page: 1, usage: 2, registry: 0x1000_0BBB)
        XCTAssertNotEqual(InterfaceClassifier.identityKey(a), InterfaceClassifier.identityKey(b))

        // Without a location there is no way to call them twins, so both are opened.
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: b, open: ["a": a]), [])
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: a, open: ["b": b]), [])
        XCTAssertFalse(InterfaceClassifier.isSamePhysicalDevice(a, b))

        // The same interface seen twice keeps one identity.
        XCTAssertEqual(InterfaceClassifier.identityKey(a), InterfaceClassifier.identityKey(a))

        // Two BLE mice with different serials are separate even if a location were shared.
        let c = descriptor(0xB034, transport: "Bluetooth Low Energy", page: 1, usage: 2, location: 0x55, serial: "mouse-1")
        let d = descriptor(0xB034, transport: "Bluetooth Low Energy", page: 1, usage: 2, location: 0x55, serial: "mouse-2")
        XCTAssertNotEqual(InterfaceClassifier.identityKey(c), InterfaceClassifier.identityKey(d))
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: d, open: ["c": c]), [])
    }

    // MARK: Twins

    func testTwinInterfacesOfOneDeviceCollapse() {
        let mouse = descriptor(0xC08A, transport: "USB", page: 0x01, usage: 0x02, location: 0x1400_0000)
        let vendor = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 1, location: 0x1400_0000)
        let otherVendor = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 4, location: 0x1400_0000)

        // Nothing open: open it.
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: mouse, open: [Int: HIDInterfaceDescriptor]()), [])
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: vendor, open: [Int: HIDInterfaceDescriptor]()), [])

        // The mouse interface is open and the vendor interface arrives: the vendor one wins.
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: vendor, open: [7: mouse]), [7])

        // The vendor interface is open and the mouse interface arrives: leave it alone.
        XCTAssertNil(InterfaceClassifier.twinsToReplace(adding: mouse, open: [7: vendor]))

        // Two vendor interfaces of one device: the first one stays.
        XCTAssertNil(InterfaceClassifier.twinsToReplace(adding: otherVendor, open: [7: vendor]))

        // Two plain mouse interfaces of one device: the first one stays.
        XCTAssertNil(InterfaceClassifier.twinsToReplace(adding: mouse, open: [7: mouse]))

        // A vendor interface supersedes every open non-vendor twin, and only those.
        let others = descriptor(0xB020, transport: "Bluetooth", page: 0x01, usage: 0x02, location: 0x99)
        let superseded = InterfaceClassifier.twinsToReplace(adding: vendor, open: [1: mouse, 2: mouse, 3: others])
        XCTAssertEqual(Set(superseded ?? []), Set<Int>([1, 2]))
    }

    func testDifferentDevicesAreNeverTwins() {
        let a = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 1, location: 0x1400_0000, serial: "A")
        // Another location.
        let elsewhere = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 1, location: 0x1500_0000, serial: "A")
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: elsewhere, open: [1: a]), [])
        // Another product at the same location.
        let otherProduct = descriptor(0xC52B, transport: "USB", page: 0xFF00, usage: 1, location: 0x1400_0000)
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: otherProduct, open: [1: a]), [])
        // The same model and location but contradicting serials.
        let otherSerial = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 1, location: 0x1400_0000, serial: "B")
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: otherSerial, open: [1: a]), [])
        // A missing serial on either side is no contradiction.
        let noSerial = descriptor(0xC08A, transport: "USB", page: 0x01, usage: 0x02, location: 0x1400_0000)
        XCTAssertNil(InterfaceClassifier.twinsToReplace(adding: noSerial, open: [1: a]))
        // A zero location never matches, even against an identical descriptor.
        let noLocation = descriptor(0xC08A, transport: "USB", page: 0xFF00, usage: 1)
        XCTAssertEqual(InterfaceClassifier.twinsToReplace(adding: noLocation, open: [1: noLocation]), [])
    }

    // MARK: Descriptor

    func testDescriptorSummaryAndUsageHelpers() {
        let d = HIDInterfaceDescriptor(vendorID: 0x046D, productID: 0xB020, transport: "Bluetooth Low Energy", usagePage: 1, usage: 2, productName: "MX Vertical")
        XCTAssertEqual(d.summary, "MX Vertical [046D:B020] via Bluetooth Low Energy, usage 0001:0002")
        XCTAssertEqual(HIDInterfaceDescriptor(vendorID: 0x046D, productID: 0xC52B).summary, "Logitech device [046D:C52B], usage 0000:0000")
        XCTAssertTrue(HIDInterfaceDescriptor(vendorID: 1, productID: 2).hasUnknownUsage)
        XCTAssertFalse(d.hasUnknownUsage)
        XCTAssertTrue(descriptor(1, page: 0xFF00).isVendorHIDPP)
        XCTAssertTrue(descriptor(1, page: 0xFF43).isVendorHIDPP)
        XCTAssertFalse(descriptor(1, page: 0x01, usage: 0x02).isVendorHIDPP)
    }
}
