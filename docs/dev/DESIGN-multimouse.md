# Upright: final multi-mouse and multi-model design

Status: final architecture for implementation. The project is read-only for this document; nothing in the repo was changed.
Inputs: three candidate designs (minimal, robust, ux), the four-layer assumption inventory, and `scratchpad/research/devices.verified.json`. Facts checked against the Solaar clone in `scratchpad/research/Solaar`:
- HID++ 2.0 `DEVICE_KIND`: keyboard 0, remote 1, numpad 2, mouse 3, touchpad 4, trackball 5, presenter 6, receiver 7.
- HID++ 1.0 kind nibble: unknown 0, keyboard 1, mouse 2, numpad 3, presenter 4, remote 7, trackball 8, touchpad 9.
- 0x41 kind = `data[0] & 0x0F`.
- 0x0003 fn0 ids: unit = bytes[1..4], transport bits = byte[6] (bt 0x01, btle 0x02, wpid 0x04, usb 0x08), model PIDs packed in bytes[7..12] in that bit order.
- Test baseline is 163 tests: Controller 29, DeviceFeature 24, Gesture 23, MappingPersistence 22, Mapping 19, ScrollTransform 17, HIDPPMessage 12, Profile 9, BatteryAlertPolicy 8.

---

## Scorecard

Scores are 0–10. "Overall" is the unweighted mean.

| Criterion | minimal | robust | ux |
|---|---|---|---|
| Correctness with several mice at once | 7: per-slot child keeps the proven state machine and dedupes by unit. Routing and diversion planning stay in the untested app target. Global request gate. | 9: per-slot everything, same-unit standby, per-slot echo, read-modify-write of receiver flags, undivert on retire, seeded fuzz test. | 8: address routing is always unique, config is pulled before the first diversion (no race), dedupe with promotion. Parallel per-slot probing on real receivers is unverified. |
| Migration safety for MX Vertical users | 9: v2 goes to the MX Vertical model, backup copied, same key. Writing v3 under the old key name confuses downgrades. | 8: exact equivalence proof by golden test. Three-scope precedence (allMice/model/unit × base/app) is easy to get subtly wrong. | 9: new v3 key, v2 never written, upgrade-without-data path kept. Slug keys need a re-keying step once the catalog learns a model. |
| Implementation risk and size | 8: smallest. Reuses `MXVerticalController` as a per-slot child. | 5: largest. Rewrites the controller into Link/Slot, adds registry, preferences, planner, three-scope mappings, renames in wave 0. | 6: medium. Renames the controller, Wave 0 touches DeviceSession and DeviceManager, final integration agent "owns all files". |
| UX clarity | 6: device picker, but no per-mouse enable or nickname, thin onboarding. | 7: complete, but the All mice / model / unit scope picker is a concept most users don't need. | 9: Mice pane, new-model banner, "Untested model" badge, "Copy device report", Remap-this-mouse, Forget, per-model Buttons picker. |
| Testability | 6: DeviceDirectory is pure, but planner and routing stay in AppModel and can't be tested on Linux. | 10: registry, planner and end-to-end routing all in the Kit, with fake links. | 9: registry and planner in the Kit, simulator v2, end-to-end via real controllers. |
| **Overall** | **7.2** | **7.8** | **8.2** |

**Base:** the ux design, for its routing model, pull-based configuration, Kit-hosted registry and planner, per-model mappings, and UI.

**Grafts:**
- From minimal: the low-risk controller topology (hub plus per-endpoint child that reuses today's state machine), the transport request gate, and the backup-before-first-v3-save.
- From robust: PID-canonical model keys from 0x0003 (no re-keying ever), same-unit standby across links, read-modify-write of receiver notification flags once per link, per-slot echo suppression, retire-on-identity re-pair, `DevicePreferences`, the end-to-end fuzz test, and keyboard-range exclusion at classification.

---

## (A) Decisions and rationale

Each conflict between the three designs is resolved explicitly; the losing options are named.

**D1. Topology: a hub per HID interface plus an endpoint controller per mouse.** *(minimal; rejects the robust rewrite and the ux single-class InterfaceController)*
- New `HIDPPLink` (hub, one per opened IOHIDDevice) owns the `HIDPPClient`, the `ReceiverDirectory` (pairing table, 0x40/0x41, notification flags, announcements) and routing by device index.
- Each served mouse is one `EndpointController` child: receiver slot 1…6, or 0xFF for a direct link. This is today's `MXVerticalController` with receiver discovery removed. It keeps the existing probe/connect/configure/retry/backoff/reconfigure-debounce/battery/DPI-reconcile/Easy-Switch logic, now scoped to one index, together with its own timers, retry counter, echo bookkeeping, op coalescing and restore list.
- The class is renamed `EndpointController`, with `public typealias MXVerticalController = EndpointController` kept for one release. The file is renamed only in the final wave, together with pbxproj, to avoid churn across waves.
- The direct-link init `MXVerticalController(transport:kind:)` is kept: it builds a private one-endpoint hub, so the direct-link tests run unchanged.
- *Why:* the state machine is the part the user has tested on hardware ("reconnects pretty fast"). Moving it intact into a per-slot child keeps that behaviour and confines the new code to discovery and routing.

**D2. Support is decided by capability, never by name or PID.** *(all three agree)*
An endpoint is served if all of these hold:
1. It answers as HID++ ≥ 2.0.
2. It is a pointer. The 0x41 or pairing kind nibble (HID++ 1.0 kinds 2 mouse, 8 trackball, 9 touchpad, 0 unknown) may pre-filter. The 0x0005 fn2 kind (3 mouse, 5 trackball, 4 touchpad) is authoritative when present. With neither available, a control carrying the `mse` flag (0x01) counts.
3. It has 0x1B04 with at least one configurable control.

Anything else ends in a terminal `.unsupported(reason, partialSnapshot)`: no retry, no writes, never diverted.
- Touchpads (for example T650) pass the pointer gate, but have no divertable 0x1B04 controls in practice, so they end `.unsupported(.noConfigurableControls)`.
- Keyboards (MX Keys has 0x1B04) are rejected by kind. This is the anti-hijack gate.
- `HIDPPError.notMXVertical` is replaced by `.unsupportedDevice(UnsupportedReason)`.

**D3. Runtime routing key is `DeviceAddress`; persistence key is `DeviceID`.** *(ux address plus robust unit identity; rejects the minimal `DeviceID(transport,index)` as a persisted key and the robust use of `DeviceID` for routing)*
- `DeviceAddress(link: UInt32, index: UInt8)` is always unique among live endpoints and exists before identification. Button events, pointer deltas, engine state, diversion caches and device actions all use it.
- `DeviceID` (unit-based, §D) keys persisted per-mouse preferences and same-unit dedupe. It never routes events, so two units with colliding or zero unit IDs can never cross-talk.

**D4. Mappings are per model, not per unit, with no "all mice" layer in v3.** *(minimal and ux; rejects robust's three-scope precedence)*
- Each `ModelKey` holds today's v2 shape: a global table plus per-app profiles. Per-app profiles work unchanged inside each model.
- Two identical mice share one setup, which is what nearly everyone wants. The key survives transport and slot changes, and is portable in exports.
- The schema reserves a `devices` section (decoded, preserved, unused) for a later per-unit override, so no v4 is needed for it.
- A Buttons-pane action "Copy setup from…" and "Use this setup for all my mice" covers the all-mice case without a precedence model.

**D5. ModelKey is PID-canonical from 0x0003.** *(robust; rejects the slug keys of minimal and ux, which need re-keying)*
- `ModelKey("046D:XXXX")`, where XXXX is the first present of bt, btle, wpid, usb in the 0x0003 model-ID list. This is the same on every transport: MX Vertical reports 407B/C08A/B020 and gets `046D:B020`.
- If 0x0003 is missing or has no model IDs: use the transport PID (the receiver's wpid or the IOHID PID), mapped through catalog aliases to the canonical key. Otherwise `046D:<pid>`. Last resort: `name:<lowercased name>`.
- Unknown models therefore get the same key that the catalog will later give them, so no re-keying step exists.
- Export files carry a `name` beside every key, so they stay readable.
- `ModelKey.mxVertical = "046D:B020"`.

**D6. v2 to v3 migration goes into the MX Vertical model; the new key is `mappingProfiles.v3`.** *(ux and robust key handling plus the minimal backup)*
- Only an MX Vertical could have produced v2 data, so placing v2 in `models[046D:B020]` reproduces today's behaviour exactly.
- Every other model starts native: nothing is diverted, so a new mouse is never hijacked.
- After migration the v2 key is never written or deleted, so a downgrade reads the user's last v2 state.
- A one-time byte copy `mappingProfiles.v2.preV3Backup` is written before the first v3 save.
- Details in §E.

**D7. Per-device runtime state.** Diversion, raw XY, DPI (including adopting a speed set on the mouse), held buttons, gestures, gesture threshold and source, battery-alert policy, Easy-Switch and DPI actions, recovery, access-denied, and the Remap-this-mouse switch are all per device.
- The cross-controller DPI broadcast is removed.
- `connectedController` is deleted.

**D8. Receivers.**
- Supported:
  - Unifying C52B and C532.
  - Bolt C548, with its own pairing layout.
  - Nano C52F, C531, C534, C537, C518, C51A, C51B, C521, C525, C526, C52E, C535 (vendor 046D), using the Unifying register layout. *Why:* the verified DB has 40xx HID++ 2.0 mice with 0x1B04 behind C534 and C52F (M185 family, M705), and Solaar uses the same 0x20+(n−1) layout for Nano.
- **Lightspeed** (C539, C53A, C53D, C53F, C541, C545, C547, C54D) is never opened. Every one of the 9 G and PRO mice in the verified DB lacks 0x1B04; their buttons live in 0x8100 onboard profiles. C53A also carries a PowerPlay chip in slot 7, and G HUB owns these receivers. They are logged once as "Lightspeed receiver: not supported (no programmable-button feature on its mice)". Re-enabling one is a one-line table change if a probe dump ever shows 0x1B04.
- 27 MHz (C517) and pre-Unifying HID++ 1.0 receivers are excluded.
- Lenovo 17EF:6042 is not matched. That would be the first non-046D match, for a low-value Nano clone; it is noted as a future addition.
- Slots 1…6 are always scanned. `maxSlots` is never used as a bound, per the C53A note.

**D9. Direct (USB or Bluetooth) acceptance.**
- An interface qualifies if its PID is in the catalog, or falls in Solaar's receiverless mouse ranges: USB C07D–C094, Bluetooth B012–B0FF.
- Keyboard ranges USB C32B–C344 and Bluetooth B317–B3FF are excluded at classification, so keyboards are never opened. This avoids Input Monitoring prompts and conflicts with Options+.
- The transport comes from the IOHID `Transport` string ("USB", "Bluetooth", "Bluetooth Low Energy").
- The matching dictionary drops the MX Vertical PIDs and adds a generic vendor 046D, GenericDesktop/Mouse entry beside the existing 0xFF00/0xFF43 vendor pages.

**D10. Wire concurrency: one request in flight per transport, with two priority lanes.** *(minimal gate plus a lane; rejects ux's parallel per-slot probing)*
- `HIDPPClient` gets a FIFO gate. Interactive requests (setCidReporting, DPI set, host switch) jump ahead of background requests (probe, feature table, battery, info).
- Head-of-line delay is bounded by one request timeout. One mouse sees today's wire pattern unchanged.
- Per-endpoint op queues sit above the gate, so a sleeping slot's probe interleaves request by request with other slots and never blocks them for a whole `start()`.
- Coalescing keys become `(index, kind)`.
- *Why:* whether real receivers tolerate concurrent requests to different slots is unverified. The gate costs at most ~1 s latency in the worst case and can be relaxed later behind `ControllerTuning.maxInFlight`.

**D11. Receiver-wide setup happens once per link.** Register 0x00 notification flags use read-modify-write (set bits 0x01 wireless and 0x08 software-present in byte 1, keep others), at link start and on Mac wake, never on per-slot reconfigure. The 0x02 announcement request is sent only when the pairing table is unreadable. Echo suppression is per slot.

**D12. Same physical unit on two links at once** (cable plus wireless; a receiver plus Bluetooth twin).
- When two live endpoints identify with the same stable `DeviceID`, the registry keeps one active, preferring USB, then receiver, then Bluetooth, then first seen.
- The other becomes `.standby`: native configuration (undiverted), events dropped. It is promoted when the active one leaves.
- **Re-pair on the same receiver:** a link-up on a new slot is always a new endpoint. If its stable `DeviceID` equals an endpoint on another slot of the same hub, the old endpoint is retired: fire-and-forget undivert, release holds, `onEndpointRemoved`. The old "the current session didn't answer" heuristic and the "staying on the first MX Vertical" rule are deleted.

**D13. Multi-device decision logic lives in UprightKit.** `DeviceRegistry`, `ConfigurationPlanner`, `InterfaceClassifier`, `DevicePreferences`, `DeviceCatalog` and `ControlCatalog` are all Foundation-only and tested on Linux. The app target becomes IOKit and AppKit glue plus SwiftUI.

**D14. Scroll keeps today's semantics.** The tap is active while any supported mouse is connected or asleep. That is today's "has a snapshot" rule, so existing users see no change. Copy says it affects all mouse wheels. The Swift name becomes `onlyWhileMouseConnected` and the Codable key stays `onlyWhileMXVerticalConnected`. *(rejects ux's "connected only")*

**D15. Additive, defaulted APIs.**
- `ButtonEvent(cid:phase:)` still compiles (`source` defaults to `.unassigned`).
- `RemapEngine.mappings`, `onDeviceAction` and `pressedControls` stay as compatibility shims.
- The 163 tests remain the regression suite. Only the tests listed in §G-3, which encode single-session or MX-only behaviour, are inverted.

**D16. Raw-XY quirk.** When the 0x1B04 version is ≥ 5, `DeviceSession` drops the first raw-XY report after each press of a raw-XY control. This follows the Solaar note; it is hardware-unverified and isolated to one function.

**D17. DPI.**
- Only 0x2201 is supported for speed. Devices with only 0x2202 or 0x2205 (for example the M720) show no DPI UI, and their DPI actions are hidden. This is a known limitation in the README.
- Global `dpiPresets` stay as the seed list and are snapped per device at apply time.
- 0x1001 battery voltage is added as a read-only battery source (Solaar voltage table).

---

## (B) Core types and signatures

K = `UprightKit/Sources/UprightKit/`. Everything new is `Sendable`, and `@MainActor` where it holds callbacks. No tuple dictionary keys.

### B1. Identity: `K/Device/DeviceIdentity.swift` (new, complete in Wave 0)

```swift
public struct DeviceAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var link: UInt32            // per opened IOHIDDevice, monotonic, never reused in a process
    public var index: UInt8            // 1...6 receiver slot, 0xFF direct
    public static let unassigned = DeviceAddress(link: 0, index: 0xFF)
    public static let direct: UInt8 = 0xFF
}

public struct ModelKey: RawRepresentable, Hashable, Codable, Comparable, Sendable {
    public var rawValue: String                  // "046D:B020" | "name:<lowercased>"
    public init?(rawValue: String)
    public init(productID: UInt16)               // "046D:%04X"
    public static let mxVertical = ModelKey(productID: 0xB020)
}

public struct ModelIDs: Hashable, Sendable {     // parsed 0x0003 fn0 model PIDs
    public var bluetooth, bluetoothLE, wireless, usb: UInt16?
    public var canonical: UInt16? { bluetooth ?? bluetoothLE ?? wireless ?? usb }
}

public struct DeviceID: RawRepresentable, Hashable, Codable, Comparable, Sendable {
    // "u:<model>:<unitID 8 hex>" | "s:<model>:<serial>" | "t:<link>.<index>" (transient, never persisted)
    public var rawValue: String
    public var isStable: Bool { !rawValue.hasPrefix("t:") }
}

public enum DeviceKind: Hashable, Sendable {
    case keyboard, remote, numpad, mouse, touchpad, trackball, presenter, receiver, other(UInt8), unknown
    public init(hidpp20 value: UInt8)            // 0x0005 fn2: 0 kb,1 remote,2 numpad,3 mouse,4 touchpad,5 trackball,6 presenter,7 receiver
    public init(hidpp10Nibble value: UInt8)      // pairing/0x41: 0 unknown,1 kb,2 mouse,3 numpad,4 presenter,7 remote,8 trackball,9 touchpad
    public var isPointer: Bool                   // mouse, trackball, touchpad
    public var isDefinitelyNotPointer: Bool      // keyboard, numpad, presenter, remote, receiver
}

public struct DeviceIdentity: Hashable, Sendable {
    public var name: String
    public var kind: DeviceKind
    public var unitID: UInt32?                   // nil when absent or zero
    public var serialNumber: String?
    public var modelIDs: ModelIDs
    public var extendedModelID: UInt8?
    public var transportPID: UInt16?             // wpid on a receiver, IOHID PID on a direct link
    public var model: ModelKey                   // via DeviceCatalog.modelKey(for:)
    public func deviceID(at address: DeviceAddress) -> DeviceID
    public static func parseFirmwareIDs(_ reply: [UInt8]) -> (unitID: UInt32?, modelIDs: ModelIDs, extendedModelID: UInt8?)?
}

public enum UnsupportedReason: Hashable, Sendable {
    case hidpp10(major: UInt8, minor: UInt8), notAPointer(DeviceKind), noReprogControls, noConfigurableControls
    public var message: String                    // localized, user-facing
}
```

### B2. Events: `K/Device/ButtonStateTracker.swift`

```swift
public struct ButtonEvent: Hashable, Sendable {
    public var cid: UInt16; public var phase: Phase
    public var source: DeviceAddress = .unassigned       // stamped by EndpointController
}
public struct PointerDelta: Hashable, Sendable {
    public var source: DeviceAddress; public var dx: Int; public var dy: Int
}
```

### B3. Session and snapshot: `K/Device/DeviceSession.swift`

Every `DeviceSnapshot` addition has a default, so existing call sites compile:
```swift
public var identity: DeviceIdentity?          // nil only in legacy test fixtures
public var address: DeviceAddress = .unassigned
public var reprogVersion: UInt8 = 0
public var modelKey: ModelKey { identity?.model ?? .mxVertical }   // compat for fixtures
```
- `start()` is read-only, in this order: protocol, feature table, name, 0x0005 kind, 0x0003 identity (fn0 plus serial), then the 0x1B04 check and controls, then battery (0x1004, 0x1000 or 0x1001), DPI (0x2201), hosts (0x1814).
- It throws `HIDPPError.unsupportedDevice(UnsupportedReason, partial: DeviceSnapshot?)` when the device fails the gate.
- Name fallback: the IOHID product string, else "Logitech mouse".
- `restoreMessages()` is kept. It is used on every drop or retire while the device may still be reachable.

### B4. Hub and endpoint

`K/Device/HIDPPLink.swift` (new):
```swift
@MainActor public final class HIDPPLink {
    public init(transport: HIDPPTransport, kind: TransportKind, link: UInt32, tuning: ControllerTuning = .init())
    public private(set) var endpoints: [UInt8: EndpointController]           // sorted access via `orderedEndpoints`
    public var configurationProvider: (@MainActor (DeviceAddress, DeviceSnapshot) -> EndpointConfiguration)?
    public var onEndpointChange: ((DeviceAddress, EndpointController.State) -> Void)?
    public var onEndpointRemoved: ((DeviceAddress, RemovalReason) -> Void)?   // .unpaired, .retired(movedTo:), .replaced, .transportClosed
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    public var onPointerDelta: ((PointerDelta) -> Void)?
    public var onDeviceDPIChange: ((DeviceAddress, Int?) -> Void)?           // native change on THAT mouse only
    public var onLog: ((DeviceAddress?, String) -> Void)?
    public func start(); func refresh(index: UInt8? = nil); func shutdown()  // shutdown restores every endpoint
    public func setConfiguration(_ c: EndpointConfiguration, at index: UInt8)
    public func cycleDPI(at: UInt8, presets: [Int]); func setDPI(_: Int?, at: UInt8); func switchToHost(_: Int, at: UInt8)
    public func refreshDeviceInfo(at: UInt8?); func reconnect(index: UInt8?)
    public func waitUntilIdle() async                                         // tests
}
```

`K/Device/ReceiverDirectory.swift` (new, value-level parsing plus the receiver ops used by `HIDPPLink`):
```swift
public enum PairingLayout: Sendable { case unifying /* 0x20+(n-1), Nano too */, bolt /* 0x50+n */ }
public struct PairingRecord: Hashable, Sendable { public var slot: UInt8; public var wirelessPID: UInt16; public var kind: DeviceKind }
public enum ReceiverDirectory {
    public static func parsePairing(_ reply: [UInt8], slot: UInt8, layout: PairingLayout) -> PairingRecord?
    public static func parseConnection(_ m: HIDPPMessage) -> (slot: UInt8, wirelessPID: UInt16, kind: DeviceKind, linkUp: Bool)?  // 0x41
    public static func isUnpair(_ m: HIDPPMessage) -> UInt8?                   // 0x40 with unpair bit → slot
    public static func mergedNotificationFlags(current: [UInt8]) -> [UInt8]   // read-modify-write of register 0x00
}
```
Layouts:
- Unifying/Nano: wpid = bytes[3..4] big-endian, kind = byte[7] & 0x0F.
- Bolt: wpid = b[3]<<8 | b[2], kind = b[1] & 0x0F.
- 0x41: wpid = d[2]<<8 | d[1], online = !(d[0] & 0x40), kind = d[0] & 0x0F.

`K/Device/MXVerticalController.swift` keeps its file name until the final wave. Its class becomes `EndpointController`, with `public typealias MXVerticalController = EndpointController`:
```swift
public enum State { case probing, waitingForDevice, connected(DeviceSnapshot), asleep(DeviceSnapshot),
                    unsupported(UnsupportedReason, DeviceSnapshot?), failed(String) }
init(client: HIDPPClient, kind: TransportKind, address: DeviceAddress, hub: EndpointHub)  // used by HIDPPLink
public convenience init(transport: HIDPPTransport, kind: TransportKind)                  // direct only; legacy tests
public let address: DeviceAddress
var retriesWhileWaiting: Bool                       // hub: true when slot is in pairing table or notifications are off
func receive(_ m: HIDPPMessage); func linkChanged(up: Bool, announcementEcho: Bool); func retire(); func transportDidClose()
// Legacy surface kept on the direct convenience path: state, snapshot, setDesiredDiversion/RawXY/DPI, onLog, onPointerDelta, onButtonEvent
```

`EndpointConfiguration` (in `K/Device/DeviceIdentity.swift`):
```swift
public struct EndpointConfiguration: Hashable, Sendable {
    public var divert: Set<UInt16> = []; public var rawXY: Set<UInt16> = []; public var dpi: Int? = nil
    public static let native = EndpointConfiguration()
}
```

### B5. Catalog: `K/Device/DeviceCatalog.swift` and `K/Device/ControlCatalog.swift` (new; KnownControl and ControlDescriptor move here)

```swift
public struct DeviceModel: Hashable, Sendable, Identifiable {
    public var key: ModelKey; public var name: String
    public var usbPIDs, bluetoothPIDs, wirelessPIDs: [UInt16]       // first wireless/bt may alias to key
    public var controlOrder: [UInt16]                               // display order
    public var controlText: [UInt16: ControlText]                   // per-model wording overrides
    public var suggested: ButtonMappings                            // onboarding template
    public var verification: Verification                           // .hardware (MX Vertical) | .publishedDump | .unverified
    public var id: ModelKey { key }
}
public struct ReceiverModel: Hashable, Sendable { public var productID: UInt16; public var kind: ConnectionKind; public var layout: PairingLayout?  /* nil = excluded */ }
public enum DeviceCatalog {
    public static let vendorID: Int = 0x046D
    public static let models: [DeviceModel]
    public static let receivers: [UInt16: ReceiverModel]
    public static func model(_ key: ModelKey) -> DeviceModel?
    public static func model(forPID pid: UInt16) -> DeviceModel?
    public static func modelKey(for identity: DeviceIdentity) -> ModelKey   // canonical rule from D5, plus aliases
}
public struct ControlText: Hashable, Sendable { public var name, detail, symbolName: String }
public enum ControlCatalog {
    public static func text(for cid: UInt16, model: ModelKey?) -> ControlText   // model override → 33 Solaar names → "Button 0x%04X"
    public static let neverDivert: Set<UInt16> = [0x50, 0x51]
}
extension ControlDescriptor { public init(cid: UInt16, model: ModelKey? = nil) }   // old init(cid:) = MX Vertical wording
// KnownControl gains: gestureButton 0xC3, smartShift 0xC4, tiltLeft 0x5B, tiltRight 0x5D,
//   multiPlatformGesture 0xD0, virtualGesture 0xD7, hapticSense 0x1A0.
// ConnectionKind gains .nano (exhaustive switches updated).
```

### B6. Classification: `K/Device/InterfaceClassifier.swift` (new, Linux-safe)

```swift
public struct HIDInterfaceDescriptor: Hashable, Sendable {
    public var vendorID, productID: Int; public var transport: String; public var usagePage, usage: Int
    public var locationID: Int; public var serial: String; public var registryID: UInt64; public var productName: String
}
public enum InterfaceClass: Hashable, Sendable {
    case receiver(ConnectionKind, PairingLayout), direct(ConnectionKind), ignored(String)
}
public enum InterfaceClassifier {
    public static func classify(_ d: HIDInterfaceDescriptor) -> InterfaceClass
    public static func identityKey(_ d: HIDInterfaceDescriptor) -> String   // vendor:product:page:usage + (serial | location | registryID)
    public static func twinsToReplace<K: Hashable>(adding d: HIDInterfaceDescriptor, open: [K: HIDInterfaceDescriptor]) -> [K]?
}
```
`MXVertical.classify` forwards here until it is removed in the final wave. `HIDInterfaceInfo` in `IOKitHID.swift` builds an `HIDInterfaceDescriptor`, using `IORegistryEntryGetRegistryEntryID` on the device service.

### B7. Registry and planner: `K/Device/DeviceRegistry.swift` and `K/Device/ConfigurationPlanner.swift` (new)

```swift
@MainActor public final class DeviceRegistry {
    public struct Record: Identifiable, Hashable, Sendable {
        public var address: DeviceAddress; public var connection: ConnectionKind
        public var state: EndpointController.State
        public var deviceID: DeviceID?; public var model: ModelKey?; public var displayName: String
        public var role: Role                    // .active | .standby(of: DeviceAddress) | .unsupported | .pending
        public var ordinal: Int                  // first-seen order, stable for the process
        public var id: DeviceAddress { address }
    }
    public enum Role: Hashable, Sendable { case active, standby(of: DeviceAddress), unsupported, pending }
    public var nameProvider: ((DeviceID) -> String?)?            // nicknames
    public var onChange: (() -> Void)?
    public private(set) var records: [Record]                     // pointers first by ordinal; unsupported last
    public func update(_ a: DeviceAddress, connection: ConnectionKind, state: EndpointController.State)
    public func remove(_ a: DeviceAddress); func removeLink(_ link: UInt32) -> [DeviceAddress]
    public func record(_ a: DeviceAddress) -> Record?
    public func addresses(of id: DeviceID) -> [DeviceAddress]
    public func isActive(_ a: DeviceAddress) -> Bool              // false for standby/unsupported/pending
    public var summary: FleetSummary                              // anyConnected, anyPresent (connected||asleep), connectedCount,
                                                                  // lowestBattery: (DeviceAddress, BatteryStatus)?, problems: [DeviceAddress]
    public static func linkRank(_ c: ConnectionKind) -> Int       // usb 0 < unifying/bolt/nano 1 < bluetooth 2
}

public struct ConfigurationInputs: Hashable, Sendable {
    public var remappingEnabled, accessibilityGranted, deviceRemapEnabled, isActive: Bool
    public var preferredDPI: Int?
    public var held: Set<UInt16>; public var gesturesHeld: Set<UInt16>
}
public enum ConfigurationPlanner {
    public static func configuration(mappings: ButtonMappings, controls: [ControlInfo], inputs: ConfigurationInputs) -> EndpointConfiguration
    // !isActive || !deviceRemapEnabled → divert only `held` (keep-alive until release), else divertedControls ∪ held ∪ gesturesHeld,
    // ∩ that device's configurable controls; rawXY = gesture controls ∩ supportsRawXY; dpi = preferredDPI snapped to the device list.
}
```

### B8. Engine: `K/Mapping/RemapEngine.swift` (additions; existing API kept)

```swift
public struct ControlKey: Hashable, Sendable { public var source: DeviceAddress; public var cid: UInt16 }
// held: [ControlKey: ActionEffect]; gestures: [ControlKey: GestureState]; pressed: Set<ControlKey>
public var mappingsProvider: (@MainActor (DeviceAddress) -> ButtonMappings)?     // nil → `mappings` (compat)
public var rawThresholdProvider: (@MainActor (DeviceAddress) -> Double)?         // captured into GestureState at press
public var gestureSourceFor: (@MainActor (DeviceAddress, UInt16) -> PointerDeltaSource)?
public var onSourcedDeviceAction: ((DeviceAction, DeviceAddress) -> Void)?       // compat onDeviceAction still fires if set
public func pressedControls(for: DeviceAddress) -> Set<UInt16>
public func gestureControls(for: DeviceAddress) -> Set<UInt16>
public func handlePointerDelta(_ d: PointerDelta)                                // raw: only gestures with key.source == d.source
public func handleCursorDelta(dx: Int, dy: Int)                                  // cursor-source gestures (unattributable; documented)
public func releaseAll(source: DeviceAddress)
public var pressedControls: Set<UInt16> { get }                                  // compat union
```
The lost-release heuristic (a repeated press releases the previous one) applies per `ControlKey`.

### B9. Mappings: `K/Mapping/MappingProfiles.swift` (v3) and the new `K/Mapping/MappingLibrary.swift`

```swift
// MappingProfiles keeps its v2 shape (global + apps) and its tolerant decoder; it is the per-model payload.
public struct MappingLibrary: Codable, Hashable, Sendable {
    public static let schemaVersion = 3
    public var models: [ModelKey: MappingProfiles]
    public var modelNames: [ModelKey: String]                    // display, written to exports
    public var reservedDevices: [String: JSONValue]              // "devices" section: preserved, unused
    public var unknownTopLevel: [String: JSONValue]              // forward-compat preservation
    public init(migrating v2: MappingProfiles)                   // → [.mxVertical: v2]
    public subscript(model: ModelKey) -> MappingProfiles { get set }   // empty default
    public func effectiveMappings(model: ModelKey?, bundleID: String?) -> ButtonMappings   // nil/unknown → empty
    public var allActiveActions: [ButtonAction]                  // union over models (needsAccessibility)
}
// JSONValue: small Codable enum in MappingLibrary.swift (no new dependency).
```

`MappingStore` changes:
- `profilesKey = "mappingProfiles.v3"`, `v2Key = "mappingProfiles.v2"`, `preV3BackupKey = "mappingProfiles.v2.preV3Backup"`.
- `load() -> (MappingLibrary, LoadReport)`
- `save(_ MappingLibrary)`
- `export(_:) -> Data`
- `prepareImport(_ data: Data, targetModel: ModelKey) -> ImportPreview`
- `ReviewItem` gains `model: ModelKey` and `modelName`.

`ButtonMappings.suggested(for model: ModelKey, controls: [UInt16]) -> ButtonMappings`:
- MX Vertical returns `legacyDefaults`.
- Models with 0x53/0x56 get Back → Cmd+[ and Forward → Cmd+].
- A gesture button (0xC3 or 0xD0), if present, gets Mission Control.
- Otherwise the result is empty.

### B10. Per-device preferences: `K/Device/DevicePreferences.swift` (new)

```swift
public struct DevicePreferences: Codable, Hashable, Sendable {
    public var nickname: String?; public var remapEnabled = true; public var preferredDPI: Int?
    public var lastName: String?; public var lastModel: ModelKey?; public var lastControls: [UInt16] = []
    public var lastConnection: String?; public var lastSeen: Date?
}
public struct DevicePreferencesStore: Codable, Hashable, Sendable {      // UserDefaults key "devicePreferences.v1"
    public var models: [ModelKey: DevicePreferences]                     // seeds (preferredDPI) for first-seen units
    public var devices: [DeviceID: DevicePreferences]                    // only stable IDs are stored
    public func preferences(for id: DeviceID, model: ModelKey) -> DevicePreferences   // device ?? model seed ?? default
    public mutating func record(_ id: DeviceID, snapshot: DeviceSnapshot)            // lastName/controls/seen
    public mutating func migrateLegacy(preferredDPI: Int?)                           // → models[.mxVertical].preferredDPI, once
    public mutating func forget(_ id: DeviceID)
}
```

### B11. App-layer contracts (DeviceManager and AppModel; frozen at the start of Wave 4)

```swift
// Upright/App/DeviceManager.swift
@Published private(set) var records: [DeviceRegistry.Record]
@Published private(set) var summary: FleetSummary
@Published private(set) var blockedInterfaces: [String]                  // names of interfaces macOS refused
var needsInputMonitoring: Bool { !blockedInterfaces.isEmpty }
func snapshot(_ a: DeviceAddress) -> DeviceSnapshot?
func controls(for model: ModelKey, address: DeviceAddress?) -> [ControlDescriptor]  // live → prefs.lastControls → catalog
func perform(_ action: DeviceAction, on a: DeviceAddress, presets: [Int])
func setDPI(_ dpi: Int?, on a: DeviceAddress); func switchToHost(_ host: Int, on a: DeviceAddress)
func setConfiguration(_ c: EndpointConfiguration, for a: DeviceAddress)
func reconnect(_ a: DeviceAddress?)                                      // nil = Reconnect All (today's restart)
func refreshDeviceInfo(_ a: DeviceAddress?)
var configurationProvider: (@MainActor (DeviceAddress, DeviceSnapshot) -> EndpointConfiguration)?
var onButtonEvent: ((ButtonEvent) -> Void)?; var onPointerDelta: ((PointerDelta) -> Void)?
var onEndpointsRemoved: (([DeviceAddress]) -> Void)?; var onDeviceDPIChange: ((DeviceAddress, Int?) -> Void)?
// Compat until Wave 5 views land: status, snapshot, controls, isConnected → primary record (first active connected by ordinal).

// Upright/App/AppModel.swift
@Published var selectedDevice: DeviceAddress?     // Mice pane / menu target
@Published var selectedModel: ModelKey            // Buttons pane target; defaults to selected device's model, else .mxVertical
var focusedDevice: DeviceAddress?                 // last device that sent a press
var knownModels: [ModelKey]                       // connected ∪ remembered ∪ library keys, ordered
func binding(for cid: UInt16, model: ModelKey) -> Binding<ButtonAction>
func overrideBinding(for cid: UInt16, model: ModelKey, bundleID: String) -> Binding<ButtonAction?>
func copySetup(from: ModelKey, to: ModelKey); func applySetupToAllModels(from: ModelKey)
func preferences(_ id: DeviceID) -> Binding<DevicePreferences>; func forget(_ id: DeviceID)
struct PressedControl { var cid: UInt16; var source: DeviceAddress; var date: Date }
// binding(for:) / overrideBinding(for:bundleID:) without model → selectedModel (compat)
```

---

## (C) Data flow

1. **Match.** `HIDDeviceMonitor` matches vendor pages 0xFF00 and 0xFF43, plus {vendor 046D, GenericDesktop 0x01, Mouse 0x02}. Each match becomes an `HIDInterfaceDescriptor`, which is passed to `InterfaceClassifier.classify`.
   - Receiver PIDs come from the catalog. Lightspeed and 27 MHz give `.ignored`, logged once.
   - Direct devices are accepted by catalog PID or mouse PID range; keyboard ranges are ignored.
   - Twins are deduped by `identityKey`, whose fallback is serial, then locationID, then registryID, so two BLE mice never collapse.
   - Every skipped interface gets one log line.
2. **Attach.** `DeviceManager.attach` assigns `link = nextLink++`, opens the transport, creates `HIDPPLink` and wires its callbacks into `DeviceRegistry` and the app.
   - A refused open is recorded as blocked for that interface only.
   - `accessDenied` is no longer reset by a later successful attach.
3. **Hub start.**
   - *Direct link:* one endpoint at 0xFF. Its retry and backoff behaviour is exactly today's.
   - *Receiver:*
     - (a) Read register 0x00 and write back the merged flags.
     - (b) Read pairing records for slots 1…6 with the layout for this receiver.
     - (c) Spawn an `EndpointController` for each occupied slot whose kind is not `isDefinitelyNotPointer`. Its `retriesWhileWaiting` is true.
     - (d) If the pairing table can't be read: request 0x02 announcements and spawn on each link-up. If those don't arrive within `announcementWait`, ping slots 1…6 once each through the gate.
   - Probing never stops at the first success.
4. **Hub routing.**
   - **0x41 for slot n:**
     - No endpoint: spawn one, unless n is excluded for (n, wpid).
     - Endpoint exists and the wpid is nonzero and differs from the endpoint's: the device was replaced. Retire the old endpoint with undivert and spawn a new one.
     - Otherwise: `endpoint.linkChanged(up:announcementEcho:)`. The echo flag is per slot: the announcement was requested less than 2 s ago and this slot was configured after the request.
   - **0x40 unpair for slot n:** remove the endpoint (`.unpaired`) and clear (n, *) from the exclusion list.
   - **Any other message:** delivered to `endpoints[deviceIndex]`. A message from an unknown slot 1…6 with software ID 0 spawns an endpoint, so a missed 0x41 self-heals. Messages for 0xFF go to the direct endpoint.
   - The exclusion list is keyed (slot, wpid). It is filled by `.unsupported` results and cleared by 0x40 or a different wpid.
5. **Endpoint connect.**
   - `DeviceSession.start()` (read-only) produces a snapshot with identity, or throws `.unsupportedDevice`, which is terminal.
   - The hub runs the retire check: same stable `DeviceID` on another slot of this hub means the old slot is retired.
   - The hub calls `configurationProvider(address, snapshot)` synchronously on the main actor. The answer comes from AppModel through `ConfigurationPlanner`, using that model's effective mappings for the frontmost app, that device's preferences, its held set (empty) and whether the registry marks it active. If the provider is nil, `.native` is used.
   - The configuration is applied inside the same connect operation. Diversion therefore never precedes identification, so no event is ever anonymous.
   - Then `.connected`, then `onEndpointChange`, then `registry.update`.
6. **Registry.**
   - Attaches the `DeviceID` and `ModelKey`, assigns the ordinal, and computes the role.
   - If the stable `DeviceID` is already active on another link, the one with the better `linkRank` wins (USB, then receiver, then Bluetooth), with ties going to the earlier ordinal. The loser becomes `.standby`, and AppModel pushes it `.native` (keeping held buttons only until they are released).
   - `onChange` reaches the published records in DeviceManager.
7. **Events.**
   - The endpoint stamps `ButtonEvent.source` and `PointerDelta.source` with its address.
   - DeviceManager drops events whose `registry.isActive(source)` is false.
   - `AppModel.handle(event)` records `focusedDevice` and `lastPressedControl`, then calls `engine.handle(event)`.
   - Inside the engine:
     - `mappingsProvider(source)` resolves to `library.effectiveMappings(model: registry.record(source)?.model, bundleID: frontmost)`.
     - On press, the effect is snapshotted into `held[ControlKey]`. `gestureSourceFor(source, cid)` reads that device's own `ControlInfo.supportsRawXY`. `rawThresholdProvider(source)` uses that device's `dpi.current`. Both are captured per gesture.
     - Raw deltas reach only gestures with the same source. Cursor deltas (PointerMovementMonitor) reach only cursor-source gestures.
8. **Actions.** `engine.onSourcedDeviceAction(action, source)` → `DeviceManager.perform(action, on: source, presets:)` → `link.cycleDPI(at: source.index, …)`. UI actions pass `selectedDevice` or the row's address.
9. **Resync.** On an app switch, mapping edit, Accessibility change, remap toggle, preference change or release, AppModel recomputes the configuration of each record through `ConfigurationPlanner`. It uses that device's `engine.pressedControls(for:)` and `gestureControls(for:)`. A configuration differing from `appliedConfig[address]` is sent through `setConfiguration`.
10. **DPI.**
    - A native change on a mouse fires `onDeviceDPIChange(address, dpi)`. If the record has a stable ID, the value is stored in `prefs.devices[id].preferredDPI`. Nothing is broadcast.
    - On first identification of a stable ID with no stored preferences, the model seed applies. For the MX Vertical that is the migrated legacy `preferredDPI`; for other models it is nil, meaning the mouse keeps its own speed.
11. **Teardown.**
    - Retiring or removing an endpoint releases its tracker (stamped releases), sends fire-and-forget `restoreMessages()` when it may still be reachable, and calls `onEndpointRemoved`.
    - The app then runs `engine.releaseAll(source:)`, removes the record, drops the battery policy for that address, and promotes any standby endpoint of the same unit.
    - Closing a transport removes all of that link's endpoints.
    - `shutdown()` restores every endpoint on every link.
12. **Recovery.**
    - Per link: the failure counter and recovery task are stored in the entry. Recovery re-matches only that IOHIDDevice and is gated on that link's own state.
    - "Reconnect" targets one device: `link.reconnect(index:)`.
    - "Reconnect All" keeps today's full restart.
    - `.unsupported` never triggers recovery.

---

## (D) Identity strategy

| Key | Built from | Purpose | Lifetime |
|---|---|---|---|
| `DeviceAddress(link, index)` | monotonic link number + slot/0xFF | event routing, engine state, applied-config cache, actions, battery policy, UI selection | one connection of one interface; a new address after a re-pair or a transport change |
| `DeviceID` | `u:<ModelKey>:<unitID>` from 0x0003 fn0 bytes 1–4 (nonzero); else `s:<ModelKey>:<serial>` (0x0003 v4+ serial, then Unifying extended pairing 0xB5 sub 0x30+n−1 bytes 1–4); else `t:<link>.<index>` | per-unit preferences (nickname, DPI, remap-enabled, last controls), same-unit dedupe, re-pair detection, notification text | permanent for stable IDs; transient IDs are never persisted and fall back to model seeds |
| `ModelKey` | canonical 0x0003 model PID (bt ≻ btle ≻ wpid ≻ usb); else transport PID through catalog aliases; else `name:` | mappings, catalog lookup, control names, suggested setup | permanent; the same for every transport |
| IOKit identity key | vendor:product:page:usage + serial, else locationID, else registry entry ID | twin-interface dedupe at match time only | one IOHIDDevice |

Rules:
- Two identical mice have different unit IDs, so they get two records, two preference sets, and independent held, gesture and DPI state. They share the model's mappings (D4).
- If a firmware reports no unit ID and no serial, both mice still work (addresses are unique). Their preferences fall back to the model seed, and the Mice pane shows "Settings for this mouse can't be remembered" under the device.
- Unit-ID equality across transports is asserted by Solaar, but is hardware-unverified for the MX Vertical. §I includes a probe step to confirm it. If it turns out false, the only effect is that same-unit dedupe doesn't trigger; nothing breaks.

---

## (E) Schema v3 and migration rules

Stored payload (key `mappingProfiles.v3`) and export format:
```json
{
  "schemaVersion": 3,
  "models": {
    "046D:B020": { "name": "MX Vertical", "global": { "actions": { "83": {…} }, "gestures": {…} }, "apps": [ … ] },
    "046D:B034": { "name": "MX Master 3S", "global": { "actions": {} }, "apps": [] }
  },
  "devices": {},
  "global": { … }, "apps": [ … ]
}
```
- The top-level `global` and `apps` keys appear **only in exported files**. They mirror `046D:B020` so that a 2.x build importing a v3 file still gets the MX Vertical setup. On read they are ignored whenever `models` is present.
- CID keys stay decimal strings, read by the existing `ActionTable` decoder.
- Inner payloads are `MappingProfiles` encoded without `schemaVersion`, plus `name`.

**Load order** (`MappingStore.load`), first match wins:
1. `mappingProfiles.v3` present: decode the `MappingLibrary`. Unknown models, `devices` and unknown top-level keys are preserved. A `schemaVersion` greater than 3 gives today's "newer version" note plus the raw backup, and decoding continues tolerantly.
2. Else `mappingProfiles.v2` present: decode with today's tolerant v2 path (corrupt-entry skipping and backups unchanged), then `MappingLibrary(migrating:)` puts it in `models[046D:B020]`. Write the v2 bytes once to `mappingProfiles.v2.preV3Backup`, then save v3.
3. Else the 1.x `legacyKey` is present: today's v1 migration exactly, placed in `models[046D:B020]`.
4. Else `priorLaunchKeys` show an upgrade without saved data: `legacyDefaults` go in `models[046D:B020]` (today's `testUpgradeWithoutSavedDataKeepsOldDefaults` behaviour).
5. Else (fresh install): an empty library. Every model is native.

**Invariants:**
- After step 2, `mappingProfiles.v2` is never written or deleted, so a downgrade reads the last v2 state. Edits made in v3 are not visible to a downgraded build; the CHANGELOG says so.
- **Exact behaviour for existing users.** For every v2 fixture f and every bundle ID b: `library.effectiveMappings(model: .mxVertical, bundleID: b) == f.effectiveMappings(forBundleID: b)`, and the planner's diversion and raw-XY sets for an MX Vertical snapshot equal today's `syncDiversion` output. These are golden tests.
- `needsAccessibility` uses `allActiveActions` across every model, a superset of today's, which is equal for a single-model library.
- **Legacy `preferredDPI`** (AppSettings key `preferredDPI`) is copied once into `DevicePreferencesStore.models[046D:B020].preferredDPI`. The legacy key is left in place for downgrade. The first MX Vertical identified with no device entry inherits that value, so it is today's behaviour.
- **`dpiPresets`** stay global and unchanged.
- **Scroll.** The Codable key `onlyWhileMXVerticalConnected` is unchanged.

**Import:**
- A v3 file merges per model: each model section replaces that model's profiles after review. Sections for models not owned are kept, shown as "Not connected", and imported.
- A v2 or v1 file is reviewed as "Made for MX Vertical". It gets a target-model picker (default: the selected model, else MX Vertical) and is imported into that one model.
- `ReviewItem` shows the model name.
- Validation is unchanged: the primary-click guard covers `ControlCatalog.neverDivert`, plus any control a connected device flags as `mse` and non-divertable.

**Export** writes model sections, names and the compatibility mirror. It never writes `DevicePreferences` (per Mac) or the `devices` section.

---

## (F) UI changes per view

| View or file | Change |
|---|---|
| `UprightApp.swift` (menu-bar label) | Filled when `summary.anyConnected`. "NN%" shows the lowest battery among connected mice, with a red tint at or below the critical level. The accessibility label lists every mouse: "Upright, MX Vertical connected 80 %, MX Master 3S asleep". |
| `MenuBarView.swift` | One row per pointer record in ordinal order: nickname or name, connection glyph (USB, Unifying, Bolt, Nano, Bluetooth), battery, state. Clicking a row opens Settings › Mice with it selected. The button summary is for `focusedDevice`, else the first connected. DPI presets and Easy-Switch act on that same device, with its name in the section header. "Reconnect Mouse" becomes "Reconnect All Mice". A new-model banner reads "New: MX Master 3S. Its buttons work as usual. Set up…". Connection hints add Bolt and Nano. |
| `SettingsView.swift` | The sidebar entry "Device" becomes "Mice". The other panes are unchanged. |
| `DevicePane.swift` → Mice pane | List and detail layout. The list has three sections: connected, then remembered offline (from `DevicePreferencesStore`), then a collapsed "Other Logitech devices" section with the unsupported reason ("no programmable buttons", "HID++ 1.0 device", "keyboard"). Duplicate names get "#2". The detail keeps today's header, battery and info rows, and adds: a nickname field; "Remap this mouse" (`remapEnabled`); Reconnect for this mouse; Forget (for offline mice); an "Untested model" badge when `verification != .hardware`; "Copy device report" (feature table, control table with cid, tid, flags and raw-XY, identity, connection) for GitHub issues. The failed-details block is per device. The Activity log prefixes each line with the device label ("MX Master 3S · Bolt slot 2") and has a device filter. |
| `PointerSpeedSection.swift` | Bound to the selected device's DPI and `DPIInfo`. Hidden when the device has no 0x2201. "Use Suggested" writes the global presets from the selected device. "Let the Mouse Decide" clears only this device's preference. |
| `Components.swift` (DeviceHeader, BatteryLabel, ConnectionHint) | Take a `Record` or snapshot parameter. Copy is model-neutral. The Input Monitoring callout is driven by `needsInputMonitoring` and names the blocked interface. |
| `ButtonsPane.swift` | A "Configure: [MX Vertical ▾]" model picker, listing connected models, then remembered models, then catalog models (so a mouse can be set up before it arrives). Rows come from `controls(for: selectedModel, address:)`. When two or more units of the model are present, a caption reads "Applies to every MX Vertical". The footer is generated from `ControlCatalog` text. A "Copy setup from…" menu and "Use this setup for all my mice" are added. The raw-XY note uses the selected device's controls. The empty state says "Connect a Logitech mouse". |
| `ButtonRow.swift`, `GestureEditor.swift` | Take `model:`. Names, symbols and details come from `ControlDescriptor(cid:model:)`. Rows flash only for `lastPressedControl` whose source belongs to the selected model. |
| `ProfileSection.swift` | The app-profile list is per model (`library[selectedModel].apps`). |
| `ActionPicker.swift` | Easy-Switch channels follow the selected device's `hosts.count` (falling back to 3 when offline). The Pointer Speed submenu is hidden when the selected device lacks 0x2201. "Set to N DPI" is validated against that device's range. |
| `GeneralPane.swift` | The import review shows the model per item, and adds the target-model picker for v2/v1 files. Battery-in-menu-bar copy says "lowest battery". |
| `OnboardingView.swift` | "Connect your Logitech mouse". "Suggested" applies `ButtonMappings.suggested(for: detected model)` to that model only. The Try-it line names the device ("MX Master 3S: Back → Cmd+[ "). |
| `PermissionsPane.swift` | The privacy text reads "Upright only listens to the HID++ channel of Logitech receivers and supported Logitech mice." The Input Monitoring row lists blocked interfaces. |
| `ScrollPane.swift` | "Only while a Logitech mouse is connected", with a note: "Applies to every mouse wheel. macOS doesn't say which mouse a scroll came from." The paused status says "Paused until a Logitech mouse connects". |
| `AboutPane.swift` | "Remaps Logitech mice over HID++. Built and tested on the MX Vertical." |
| `BatteryNotifier.swift` | `[DeviceAddress: BatteryAlertPolicy]`, with notification ID `upright.battery.<DeviceID or address>` and the device name or nickname in the text. A policy is dropped when its address is removed, and seeded from the last level when a stable ID reconnects. |
| `SystemActionPerformer.swift` | Synthetic mouse buttons (down/up, click state, drag rewriter) and media-key repeats are refcounted per button or key, as `modifierHolds` already is. |
| `Localizable.xcstrings` | Sync every changed literal. The 11 "MX Vertical" keys are reworded, and new keys are added for Mice, unsupported reasons, banners and badges. English only, so there are no translations to migrate. |

---

## (G) Test plan

T = `UprightKit/Tests/UprightKitTests/`. All suites are XCTest on Linux and macOS, with Swift 6.0 strict concurrency as today. `@MainActor` tests are `async`, per commit 01c22a1.

### G-1. Simulator extension (`T/Simulation/`)
- **`SimulatedDeviceProfile`** describes one mouse: name, `DeviceKind`, protocol version (including a HID++ 1.0 variant), wpid, bt and usb PIDs, 0x0003 unit ID and model IDs, serial, ordered features with versions, control table (cid, tid, flags, additional flags), DPI list and default, battery feature (0x1000, 0x1004 or 0x1001), host count. Event feature indices are looked up from the profile, never hard-coded.
- **`SimulatedReceiver`** has the Unifying, Nano and Bolt pairing layouts, slots 1–6, per-slot link state, 0x40 and 0x41, register 0x00 read and write, and 0x02 announcements.
- **Per-slot API:** `hold(cid, slot:)`, `release`, `move(dx, dy, slot:)`, `goToSleep(slot:)`, `wakeUp(slot:)`, `diverted(slot:)`, `rawXY(slot:)`, `dpi(slot:)`, `setDPINatively(slot:)`, `repair(from:to:)`, `unpair(slot:)`, `pair(profile, slot:)`.
- **Per-slot faults:** `dropsRequests(slot:)`, `latency(slot:)`, `cidErrors[(slot, cid)]`.
- **Per-slot counters:** `setReportingCount(slot:)`, `pingCount(slot:)`, `requestsInFlightMax` (asserts the gate).
- The Easy-Switch handler sleeps the addressed slot.
- **`SimulatedDirect`** wraps one profile at 0xFF for USB and Bluetooth.
- **`SimulatedMXVertical`** remains a facade with its current API, acting on the primary slot. The existing tests compile and pass unchanged.
- **`DeviceProfiles.swift`** fixtures, from `devices.verified.json` (high and medium confidence only):
  - MX Vertical: 407B/B020/C08A, unit 0x1A2B3C4D.
  - MX Vertical #2, a different unit.
  - MX Master 3 and MX Master 3S: B034 Bolt, 0x1004, 0x1B04 v5, 0xC3 and 0xC4.
  - MX Anywhere 3.
  - Lift.
  - M720: 0x5B, 0x5D, 0xD0, no 0x2201, 0x2205 only.
  - MX Ergo: trackball.
  - M185: Left and Right flagged divertable, no DPI.
  - MX Keys: keyboard with 0x1B04.
  - A generic HID++ 1.0 device.
  - G502 Lightspeed-like: no 0x1B04.
  - A no-unit-ID mouse.
- **`T/TestSupport.swift`** holds the shared helpers (`makeLink`, `eventually`, `pause`, `isConnected(at:)`, `records`), replacing the copies in ControllerTests and DeviceFeatureTests.

### G-2. New suites (named tests)

**`MultiDeviceControllerTests`** (HIDPPLink with the simulator):
- `testTwoMXVerticalsOnOneReceiverAreBothServed`
- `testMixedModelsOnUnifyingEachGetOwnDiversion` (Vertical in slot 1, Master 3 in slot 2, MX Keys in slot 3)
- `testKeyboardOnSharedReceiverIsNeverWritten` (zero setCidReporting to its slot)
- `testHIDPP10DeviceIsUnsupportedAndNotRetried`
- `testMouseWithoutReprogControlsIsTerminal`
- `testBoltReceiverPairingLayoutFindsBothMice` (Master 3S and Lift)
- `testNanoReceiverUsesUnifyingLayout`
- `testStartupProbesEverySlot`
- `testSleepingSlotDoesNotDelayOtherSlotBeyondOneTimeout`
- `testBackoffAndCountersArePerSlot`
- `testWakePingPongKeepsBothSessions`
- `testRePairByUnitIDRetiresOldSlotWithUndivert`
- `testUnpairRemovesOnlyThatSlot`
- `testDifferentWPIDInOccupiedSlotReplacesEndpoint`
- `testMissedLinkUpRecoveredFromReport`
- `testAnnouncementEchoSuppressionIsPerSlot`
- `testNotificationFlagsAreReadModifyWrittenOncePerLink`
- `testEasySwitchOnBLeavesALone`
- `testShutdownRestoresEverySlot`
- `testDroppedEndpointSendsRestore`
- `testConfigurationIsPulledBeforeFirstDiversion`
- `testOneRequestInFlightPerTransport`
- `testFirstRawXYReportDroppedOnReprogV5`
- `testUnsupportedExclusionClearsOnNewWPID`

**`RemapEngineMultiSourceTests`:**
- `testSameCIDHeldOnTwoSourcesIsIndependent`
- `testInterleavedReleasesEndOnlyTheirOwnHold`
- `testLostReleaseHeuristicIsPerSource`
- `testGestureDeltasRouteBySource`
- `testCursorDeltasOnlyReachCursorGestures`
- `testReleaseAllSourceLeavesOthersHeld`
- `testDeviceActionCarriesSource`
- `testPerSourceThresholdCapturedAtPress`
- `testPerSourceMappingsProvider`
- `testCompatPressedControlsIsUnion`

**`MappingLibraryTests`:**
- `testV2MigratesToMXVerticalEquivalentForEveryBundle` (golden, every action kind and gesture)
- `testV1LegacyMigratesIntoMXVertical`
- `testUpgradeWithoutDataGivesLegacyDefaultsOnMXVertical`
- `testFreshInstallIsEmptyForEveryModel`
- `testV2KeyNeverWrittenAfterMigration`
- `testPreV3BackupWrittenOnce`
- `testRoundTripPreservesUnknownModelsDevicesAndTopLevel`
- `testNewerSchemaNoteAndBackup`
- `testExportHasCompatMirrorAndNames`
- `testImportV3MergesPerModel`
- `testImportV2IntoChosenModel`
- `testUnknownModelResolvesToEmpty`
- `testAllActiveActionsUnionsModels`
- `testSuggestedPerModel`

**`ConfigurationPlannerTests`:**
- `testMatchesTodaysSyncDiversionForMXVertical` (golden)
- `testNewModelIsNative`
- `testRemapDisabledKeepsOnlyHeldUntilRelease`
- `testStandbyIsNative`
- `testHeldKeepAliveIsPerDevice`
- `testRawXYOnlyForCapableControls`
- `testNeverDivertPrimaryClicksEvenIfFlaggedDivertable` (M185)
- `testDPISnappedToDeviceList`

**`DeviceRegistryTests`:**
- `testOrderIsFirstSeenAndStable`
- `testSameUnitOnUSBAndReceiverPrefersUSB`
- `testStandbyPromotedWhenActiveLeaves`
- `testTransientIDsNeverDeduped`
- `testUnsupportedSortedLastAndNotAProblem`
- `testSummaryLowestBatteryAndAnyPresent`
- `testRemoveLinkRemovesAllItsEndpoints`

**`DeviceIdentityTests`:**
- `testParseFirmwareIDsPacksByTransportBits`
- `testCanonicalModelKeyIsTransportIndependent` (MX Vertical over BT, USB and Unifying all give 046D:B020)
- `testCatalogAliasesMapToCanonical`
- `testDeviceIDFallbackChain`
- `testDeviceKindTables`

**`InterfaceClassifierTests`:**
- `testUnifyingBoltNanoAccepted`
- `testLightspeedAnd27MHzIgnored`
- `testDirectMouseRangesAcceptedKeyboardRangesIgnored`
- `testBLETwinsWithEmptySerialStaySeparateByRegistryID`
- `testTwinInterfacesOfOneDeviceCollapse`

**`CatalogTests`:**
- `testEveryCatalogPIDUniqueAcrossModels`
- `testMXVerticalEntryMatchesShippedBehaviour`
- `testEveryControlOrderCIDIsNamed`
- `testControlTextFallbacks`
- `testOldControlDescriptorInitKeepsMXVerticalWording`

**`DevicePreferencesTests`:**
- `testLegacyPreferredDPISeedsMXVerticalOnce`
- `testFirstSeenOtherModelKeepsOwnDPI`
- `testTransientIDsNotPersisted`
- `testForget`

**`EndToEndRoutingTests`** (real HIDPPLinks, simulator, DeviceRegistry, ConfigurationPlanner, RemapEngine; a small Kit-side `FleetHarness` mirrors the AppModel wiring):
- `testTwoHubsUSBVerticalAndReceiverMasterNoCrossTalk`
- `testBothHoldBackIndependentKeyEffects`
- `testDetachingADoesNotReleaseB`
- `testCycleDPIOnBChangesOnlyB`
- `testNativeDPIChangeOnANotPropagated`
- `testAppSwitchMidHoldOnAKeepsADivertedAndBFollowsNewApp`
- `testSeededLinkLossFuzzNeverLeavesStuckEffects` (1000 random steps across press, release, sleep, wake, unpair, re-pair and transport close; seeded, so failures reproduce; asserts that held effects end empty and every down has a matching up)

### G-3. Regression

All 163 existing tests stay green unchanged, except the following, which are deliberately rewritten:

| Existing test | Becomes |
|---|---|
| `ControllerTests.testSecondLiveMXVerticalDoesNotStealTheSession` | `testSecondLiveMXVerticalGetsItsOwnSession` |
| `ControllerTests.testReceiverIgnoresOtherDevices` | `testReceiverIgnoresKeyboardButServesOtherMouse` (MX Keys untouched, MX Master served) |
| `ControllerTests.testReceiverUsesPairingInfoInsteadOfPingingEverySlot` | Keeps its intent, with pings only to unoccupied slots equal to 0. The `registerWriteCount(0x02) == 0` assertion stays; the 407B-only shortcut assertion is dropped. |
| `HIDPPMessageTests` classify cases (C077, "MX Master 3" unsupported) | Inverted against `InterfaceClassifier`. |
| `MappingPersistenceTests` schema pins (`schemaVersion 2` in export text; 3 used as the "newer" sample) | Pins move to 3, and the "newer" sample to 4. |
| `ScrollTransformTests` (`ScrollSettings(onlyWhileMXVerticalConnected:)`) | Uses the renamed initializer label. The Codable key test is unchanged. |

**Named behaviours that must keep passing as-is** (they encode what the user tested on hardware):
- `testDirectConnectionDiscoversAndDivertsButtons`
- `testSleepingMouseIsReconfiguredWhenItWakes`
- `testLinkUpAndWirelessStatusTogetherReconfigureOnce`
- `testMouseThatArrivesLaterIsPickedUp`
- `testReportFromASilentlyWokenMouseTriggersReconnect`
- `testRefreshAfterMacWakeReappliesDiversion`
- `testDirectTimeoutKeepsSessionAndButtonsKeepWorking`
- `testUnansweringDirectMouseIsRetriedWithBackoff`
- `testAsleepDirectMouseRecoversThroughBackoffAlone`
- `testHeldButtonIsReleasedWhenTheMouseStopsAnswering`
- `testTransportRemovalReleasesHeldButtons`
- `testShutdownHandsButtonsBackToTheMouse`
- `testRePairToANewSlotMovesTheSession` (now passes through the unit-ID retire path; the simulator's `repair` keeps the unit ID)
- `testUnpairThenPairOnANewSlot`
- `testUnpairDropsTheSessionAndReleasesHeldButtons`
- every `MappingPersistenceTests` v1/v2 migration test
- `testRepeatedPressReleasesThePreviousOne` (single source)
- `testProfileSwitchMidHoldKeepsTheGestureFromThePress`
- `testRawThresholdIsAPhysicalDistance`

### G-4. CI and hardware
- **CI:** `swift test` on macOS and in a `swift:6.0` Linux container. `make app` (Xcode 16.2, Debug and Release, hardened runtime, macOS 13 deployment target).
- **Hardware smoke checklist** on the user's MX Vertical, run over USB, Bluetooth and Unifying:
  - mappings and DPI identical before and after upgrade;
  - sleep and wake reconnect latency unchanged;
  - quit restores native buttons;
  - re-pair to another slot;
  - `upright-probe --all` shows the same unit ID on Bluetooth and Unifying;
  - with a borrowed second Logitech mouse, if available: two rows, independent Back.

---

## (H) Implementation plan

**Rules for every wave:**
- Owned files are disjoint within a wave.
- A task edits only the files it owns and codes against the §B signatures.
- Data comes only from `scratchpad/research/devices.verified.json`, using high and medium confidence entries. Placeholder entries ("NOT FOUND") and G-series mice are listed only as known-unsupported.
- Wave gates:
  - Waves 0–3: `cd UprightKit && swift build && swift test`. The Kit stays green.
  - Wave 4 onward: also `make app`.
- The app target is allowed to be red between the end of Wave 1 and the end of Wave 4, but only for the app-target files that Wave 4 owns. Compat shims keep it building as far as possible.
- No new dependencies; the Kit stays Foundation-only outside `Platform/`.

### Wave 0: contracts and scaffold (sequential, 1 agent)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W0 | opus | `K/Device/DeviceIdentity.swift` (complete §B1 plus `EndpointConfiguration`). Compiling stubs with the final signatures: `K/Device/{HIDPPLink, ReceiverDirectory, DeviceCatalog, ControlCatalog, InterfaceClassifier, DeviceRegistry, ConfigurationPlanner, DevicePreferences}.swift`, `K/Mapping/MappingLibrary.swift`. Also `K/Device/ButtonStateTracker.swift` (`source`, `PointerDelta`), `K/Device/MXVertical.swift` (`ConnectionKind.nano`), `Upright/App/DeviceManager.swift` (exhaustive `.nano` switch cases only), `Upright/Views/{DeviceListView, ModelPicker}.swift` (stubs), `Upright.xcodeproj/project.pbxproj` (register every new Kit file in the app target, and both new view files). | none | `swift build`, all 163 tests and `make app` green. Every new file is in pbxproj. The stubs `fatalError` nowhere on existing code paths. |

### Wave 1: Kit foundations (parallel, all depend on W0)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W1.1 Catalog | sonnet | `K/Device/DeviceCatalog.swift`, `K/Device/ControlCatalog.swift` (move `KnownControl` and `ControlDescriptor` here; keep the old `init(cid:)` wording), `T/CatalogTests.swift` | W0 | Models: MX Vertical (verification `.hardware`), MX Master 2S/3/3B/3S/4, MX Anywhere 2/2S/3/3B, MX Ergo, Lift (+B), M720, M585/M590, M650 L, M550, M575, M705, Pebble M350, M510 v2, M185 family. Receivers per D8. All 33 Solaar CID names. `modelKey(for:)` follows D5. CatalogTests green. |
| W1.2 Classifier and IOKit | sonnet | `K/Device/InterfaceClassifier.swift`, `K/Platform/IOKitHID.swift` (generic mouse matching dict, `HIDInterfaceDescriptor` from the device incl. `IORegistryEntryGetRegistryEntryID`, identity key via the classifier), `T/InterfaceClassifierTests.swift`, `T/HIDPPMessageTests.swift` (inverted classify cases) | W0 | D9 and the twin rules hold. `MXVertical.classify` is left in place (W5.4 removes it). Builds on Linux, with IOKit code still `#if canImport(IOKit)`. |
| W1.3 HID++ reads | opus | `K/HIDPP/{HIDPPFeature, DeviceFeatures, HIDPPDevice, HIDPPError}.swift`, `K/Device/ReceiverDirectory.swift`, `T/HIDPPIdentityTests.swift`, `T/ReceiverDirectoryTests.swift` | W0 | `DeviceFeatures.identity()` (0x0003 fn0, serial), `deviceKind()` (0x0005 fn2), 0x1001 battery voltage, feature names 0x1B00–0x1B03, 0x2202, 0x2205, 0x1C00. `HIDPPError.unsupportedDevice` added; `notMXVertical` is kept until W3.1. Pairing and 0x41 parsing for both layouts, and the notification-flag merge. DeviceIdentityTests and ReceiverDirectoryTests green. |
| W1.4 Engine | opus | `K/Mapping/RemapEngine.swift`, `K/Mapping/GestureRecognizer.swift`, `T/RemapEngineMultiSourceTests.swift` | W0 | §B8. MappingTests, GestureTests and ProfileTests pass **unchanged**. New suite green. |
| W1.5 Mapping v3 | opus | `K/Mapping/{MappingLibrary, MappingStore, MappingProfiles, ButtonMappings}.swift`, `T/MappingLibraryTests.swift`, `T/MappingPersistenceTests.swift` (only the pin updates), `T/ProfileTests.swift` (unchanged unless the compiler forces it) | W0 | §E load order and invariants. The golden equivalence test passes for every existing v2 fixture. Export round-trips. |
| W1.6 Simulator v2 | opus | `T/SimulatedMXVertical.swift` (facade), `T/Simulation/{SimulatedReceiver, SimulatedDeviceProfile, DeviceProfiles}.swift`, `T/TestSupport.swift` | W0 | The current suite passes against the **unchanged** controller. The new per-slot API compiles. Profiles are sourced from the verified JSON, with the source noted in comments. |
| W1.7 Preferences and scroll rename | sonnet | `K/Device/DevicePreferences.swift`, `T/DevicePreferencesTests.swift`, `K/Scrolling/ScrollSettings.swift` (Swift rename, Codable key kept), `T/ScrollTransformTests.swift` | W0 | §B10. Scroll Codable-key test unchanged and green. |

### Wave 2: session, registry, planner (parallel)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W2.1 Session | opus | `K/Device/DeviceSession.swift`, `K/HIDPP/ReprogControls.swift`, `T/DeviceFeatureTests.swift` | W1.1, W1.3, W1.6 | Read-only `start()` in §B3 order, with the capability gate and `.unsupportedDevice(reason, partial)`. Snapshot gets identity, address and reprogVersion. The raw-XY v5 first-report drop. Name fallback. Every event stamped with `source`. DeviceFeatureTests (24) green plus new identity and unsupported cases. |
| W2.2 Registry and planner | opus | `K/Device/DeviceRegistry.swift`, `K/Device/ConfigurationPlanner.swift`, `T/DeviceRegistryTests.swift`, `T/ConfigurationPlannerTests.swift` | W1.1, W1.7 | §B7. Planner golden-equal to today's `AppModel.syncDiversion` for an MX Vertical, re-derived from the current AppModel source and quoted in the test. Standby and promotion rules. |

### Wave 3: hub and controller (sequential core, then parallel)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W3.1 Hub and endpoint | opus | `K/Device/HIDPPLink.swift`, `K/Device/MXVerticalController.swift` (becomes `EndpointController` with the typealias), `K/HIDPP/HIDPPClient.swift` (FIFO gate with interactive and background lanes, `maxInFlight`), `K/HIDPP/HIDPPError.swift` (remove `notMXVertical`), `T/ControllerTests.swift`, `T/MultiDeviceControllerTests.swift` | W1.3, W1.6, W2.1 | D1, D10, D11, D12 and §C steps 3–5 and 11. All 29 ControllerTests green, with only the §G-3 rewrites. The MultiDeviceControllerTests list in §G-2 green. No name or PID gate is left (`grep -n "mx vertical\|407B" K/Device` returns only catalog data). |
| W3.2 Probe | sonnet | `UprightKit/Sources/upright-probe/Probe.swift`, `Makefile` (probe target help) | W3.1 | `--all` lists every Logitech HID++ interface, including unsupported ones, and dumps features and controls (cid, tid, flags, raw XY) plus identity, without needing classification. Every line is prefixed `[MX Master 3S · Bolt slot 2]`. Multiple devices are supported. `--divert` works per device. |
| W3.3 End-to-end | opus | `T/EndToEndRoutingTests.swift`, `T/Simulation/FleetHarness.swift` | W3.1, W2.2, W1.4, W1.5 | The §G-2 EndToEnd list green, including the seeded fuzz at 1000 steps under 20 s on Linux. |

### Wave 4: app core (parallel; contract §B11 frozen)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W4.1 DeviceManager | opus | `Upright/App/DeviceManager.swift` | W3.1, W2.2, W1.2 | §B11 DeviceManager. Per-link recovery and blocked interfaces. Per-device actions. Labelled log. Compat `status`, `snapshot` and `controls` derive from the primary record. `connectedController` deleted. Cross-controller DPI propagation deleted. |
| W4.2 AppModel and settings | opus | `Upright/App/{AppModel, AppSettings, PermissionsMonitor}.swift` | W1.4, W1.5, W1.7, W2.2, W4.1 contract | Engine providers wired per §C-7. `configurationProvider` uses the planner. Per-device resync with `appliedConfig[address]`. Library load and save. Legacy DPI seed. `selectedDevice`, `selectedModel`, `focusedDevice` and `knownModels`. Model-scoped bindings plus compat overloads. `PressedControl.source`. |
| W4.3 Peripherals | sonnet | `Upright/App/{BatteryNotifier, ScrollController, SystemActionPerformer}.swift`, `T/BatteryAlertPolicyTests.swift` (add per-device cases if `BatteryAlertPolicy` gains a helper; otherwise read-only) | W4.1 contract | Per-device battery policies and notification IDs. Scroll gate on `summary.anyPresent`. Refcounted mouse buttons and media repeats. |

Gate: `make app` green. A manual run with the MX Vertical behaves as before; the Fable orchestrator runs this check.

### Wave 5: UI and copy (parallel, depends on W4)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W5.1 Mice UI | sonnet | `Upright/Views/{DevicePane, DeviceListView, PointerSpeedSection, Components, MenuBarView, SettingsView, SettingsWindowController}.swift`, `Upright/App/UprightApp.swift` | W4 | The §F rows for these files. No view reads the compat `status` or `snapshot`, except the primary-row fallback where documented. |
| W5.2 Buttons UI | sonnet | `Upright/Views/{ButtonsPane, ButtonRow, ProfileSection, GestureEditor, ActionPicker, ModelPicker, GeneralPane}.swift` | W4 | The §F rows. Editing a model never changes another model's table (verified by the reviewer). |
| W5.3 Onboarding and copy | sonnet | `Upright/Views/{OnboardingView, PermissionsPane, ScrollPane, AboutPane}.swift` | W4 | The §F rows. `grep -rn "MX Vertical" Upright/Views` matches only "Built and tested on the MX Vertical" and catalog-driven text. |
| W5.4 Kit cleanup | haiku | `K/Device/MXVertical.swift` (remove `matches`, `wirelessProductID`, `classify`, `mxVerticalDefaults`; keep `displayName`, `ConnectionKind` and `TransportKind`) | W4 | No remaining references (`grep`). Kit and app build. |

### Wave 6: docs, strings, project, build (parallel, then sequential verification)

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W6.1 Strings | sonnet | `Upright/Localizable.xcstrings` | W5 | Every literal used in code has a key. Stale MX-only keys are removed. The JSON is valid, and Xcode's string catalog build step passes. |
| W6.2 Docs | sonnet | `README.md` (positioning, requirements, a supported-devices table with Verified on hardware: MX Vertical / Published data / Untested, the receivers table incl. Nano and the Lightspeed exclusion with the reason, limitations: per-model mappings, global scroll, cursor-fallback gestures, 0x2201-only DPI), new `docs/DEVICES.md` (generated from the catalog), `docs/HIDPP.md` (hub and endpoint architecture, pairing layouts, identity, capability gate, request gate), `INSTALL.md`, `CONTRIBUTING.md` (simulator profiles, the pbxproj checklist, how to add a model from a probe dump), `CHANGELOG.md` (Unreleased: multi-mouse, migration notes incl. downgrade behaviour), `.github/ISSUE_TEMPLATE/{bug_report, feature_request}.md` (model, number of mice, receiver layout, `upright-probe --all` output), new `.github/ISSUE_TEMPLATE/new_mouse.md`, `.github/pull_request_template.md` | W5 | No doc states "MX Vertical only" or "other mice out of scope". Every claim about non-MX-Vertical models is marked unverified on hardware. |
| W6.3 Project registration | sonnet | `Upright.xcodeproj/project.pbxproj`, plus `git mv K/Device/MXVerticalController.swift K/Device/EndpointController.swift` | W5 | The file rename is reflected in pbxproj. Every Kit source file is in the app target: a script diffs `find K -name '*.swift'` (excluding `upright-probe`) against the pbxproj file references and must be empty. |
| W6.4 Build and test | sonnet | none (read-only); writes logs to the scratchpad only | W6.1–W6.3 | `swift test` on macOS: 163 baseline (as adjusted per §G-3) plus every new suite green. `swift:6.0` Linux container `swift test` green. `make app` Debug and Release green, with hardened runtime and macOS 13 deployment target unchanged (`codesign -d --entitlements`, `otool -l` minos check). `Package.swift` has no new dependency. |

### Wave 7: final audit

| id | owner | files owned | deps | acceptance |
|---|---|---|---|---|
| W7 | opus | none (read-only) | W6 | Walks every inventory item (all four layers) and marks it fixed, accepted limitation or deferred, with file and line. Re-verifies: no cross-talk paths (search for any remaining CID-only keyed state); no path that drops an endpoint without release plus restore; the migration golden tests; the Swift 6.0 build; the hardened runtime. Produces the hardware smoke checklist (§G-4) for the user. |

---

## (I) Risks, and what cannot be verified without hardware

**Risks and mitigations**
1. **Controller refactor regressions.** The per-endpoint child keeps today's state machine. The 29 controller tests run unchanged through the facade simulator, and the user's "reconnects pretty fast" behaviour is covered by the named regression tests in §G-3.
2. **Request gate latency.** One request in flight per transport, with an interactive lane. In the worst case a diversion change waits one request timeout (about 1 s) behind a probe of a sleeping slot. It can be relaxed through `ControllerTuning.maxInFlight` once hardware shows that receivers accept concurrent slot traffic.
3. **Broader matching opens more interfaces.** Keyboard PID ranges are excluded at classification, Lightspeed and 27 MHz receivers are never opened, and unsupported endpoints are terminal and never written. A misclassified device is still never diverted, because a model without mappings is native.
4. **Model key drift.** A device lacking 0x0003 model IDs falls back to the transport PID, so the same mouse over two transports could get two keys. Catalog aliases cover all known models. For unknown models, "Copy setup from…" is the escape hatch and nothing is lost.
5. **Downgrade.** Older builds read the frozen v2 key: they get the user's pre-upgrade MX Vertical setup, not later edits. This is documented in the CHANGELOG.
6. **Cursor-fallback gestures can't be attributed to a mouse.** This only affects controls without raw XY, which is rare on MX-class mice, and is documented.
7. **Scroll rewriting is global** (CGEvent scroll events carry no source). Today's semantics are kept and documented.
8. **pbxproj drift.** Wave 0 registers new files, and W6.3 runs the diff check.
9. **Swift 6.0.** All new types are `Sendable`, callbacks are `@MainActor`, there are no tuple dictionary keys, and `@MainActor` tests are `async`. Every wave builds with the 6.0 toolchain.
10. **Options+ or Solaar running at the same time** can fight over diversion. Read-modify-write of the notification flags avoids clobbering their flags; detecting them is out of scope and documented.

**Cannot be verified without hardware** (the user owns one MX Vertical). Each item has a mitigation path:

| Item | How it gets verified or contained |
|---|---|
| Other models' Bluetooth/BLE HID++ interface matches the generic Mouse-usage or 0xFF43 entry, and uses device index 0xFF | `upright-probe --all` dumps from contributors; the README marks the model untested; the "Copy device report" button |
| Bolt pairing layout (0x50+n) and Bolt 0x41 behaviour | Implemented from Solaar, simulator-tested only; the announcement and ping fallbacks still find mice if the parse fails |
| Receivers tolerate interleaved requests to different slots | The gate keeps one in flight; this is today's single-mouse pattern |
| 0x0005 kinds and pairing nibbles on real firmware | Values verified against Solaar constants; the `mse`-flag fallback |
| 0x0003 unit ID identical across Bluetooth, USB and Unifying for the MX Vertical | **The user can verify this** with `upright-probe --all` over two transports. If it differs, only same-unit dedupe is lost |
| The raw-XY first-report quirk on 0x1B04 v5+ and raw-XY scale on non-Vertical models | Isolated in DeviceSession; gestures stay threshold-based in mm per device DPI |
| Whether MX mice keep their wireless link when cabled | Standby dedupe prevents double actions either way |
| BLE `SerialNumber` and `LocationID` reporting on macOS | Registry-ID fallback, plus registry dedupe as a backstop |
| Behaviour on Nano receivers with 1–2 slots | Slots 1–6 are scanned regardless; unanswered slots cost one gated ping each |
| Two physical mice at once | Simulator and end-to-end fuzz only. The README calls multi-mouse "simulator-verified; tested on hardware with one MX Vertical" until a second mouse is tried |
