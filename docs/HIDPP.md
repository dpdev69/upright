# HID++ notes

This page lists every message Upright exchanges with a Logitech mouse and its receiver, and
explains how Upright organizes the conversations when several mice are connected at once. All
values come from public HID++ documentation and the open-source projects credited in the
README. Bytes are hex; multi-byte values are big-endian unless noted.

**What has been tested on hardware.** Only the MX Vertical (over a Unifying receiver, a USB cable
and Bluetooth LE) has been checked against a real device. Everything about other models, about
Bolt and Nano receivers, and about several mice at once comes from published data and from
Upright's simulator (`UprightKit/Sources/UprightKit/Simulation`). Those places are marked
*unverified* below, and [What is not verified](#what-is-not-verified) collects them. If you have
the hardware, `make probe ARGS=--all` output is the most useful thing you can send; see
[CONTRIBUTING.md](../CONTRIBUTING.md).

Source files named below are relative to `UprightKit/Sources/UprightKit/` unless they start with
`Upright/` (the app).

## Contents

- [Architecture: hub and endpoint](#architecture-hub-and-endpoint)
- [Interfaces and transports](#interfaces-and-transports)
- [Pairing layouts](#pairing-layouts)
- [Identity](#identity)
- [The capability gate](#the-capability-gate)
- [The request gate](#the-request-gate)
- [Framing](#framing)
- [Receiver registers (HID++ 1.0)](#receiver-registers-hid-10)
- [Discovery](#discovery)
- [Features used](#features-used)
- [Button diversion](#button-diversion-0x1b04-reprog_controls_v4)
- [Pointer speed](#pointer-speed-0x2201-adjustable_dpi)
- [Firmware, serial and identity](#firmware-serial-and-identity-0x0003-device_fw_version)
- [Easy-Switch](#easy-switch-0x1814-change_host-0x1815-hosts_info)
- [Battery](#battery)
- [Staying configured](#staying-configured)
- [Connection states](#connection-states)
- [What is not verified](#what-is-not-verified)

## Architecture: hub and endpoint

Upright opens one HID interface per receiver or directly connected mouse. Two classes split the
work, and they never swap jobs:

| Class | File | One per | Owns |
| --- | --- | --- | --- |
| `HIDPPLink`, the **hub** | `Device/HIDPPLink.swift` | opened HID interface (a receiver, or a mouse on USB or Bluetooth) | the `HIDPPClient` (and its request gate), the receiver's notification flags, pairing discovery, routing of incoming reports by device index |
| `EndpointController`, the **endpoint** | `Device/EndpointController.swift` | mouse: a receiver slot (`1`-`6`) or the direct link (`FF`) | the identification, the configuration that is applied, retry and backoff, wake-up debouncing, battery refresh, pointer-speed bookkeeping |

```
IOKit (HIDDeviceMonitor)        Demo Mode (SimulatedLinkSource)
        |                                    |
        +------------ LinkSource ------------+          Upright/App/LinkSource.swift
                          |
              InterfaceClassifier                       which interfaces to open, and as what
                          |
        DeviceManager: one HIDPPLink per interface      Upright/App/DeviceManager.swift
                          |
        HIDPPLink  --- spawns --->  EndpointController  (one per mouse)
            |                              |
            |                         DeviceSession     reads identity, applies the gate,
            |                              |            diverts buttons, turns reports into events
            |                              |
            +-- DeviceRegistry <-----------+            every endpoint, roles, display names
                      |
              ConfigurationPlanner                      what each endpoint should be doing
                      |
        AppModel pushes EndpointConfiguration back down to the endpoint
```

How the pieces cooperate:

- **Pull, then push.** The moment an endpoint has identified its mouse, and before anything is
  diverted, the hub asks `configurationProvider` for that mouse's `EndpointConfiguration`
  (diverted controls, raw XY controls, pointer speed). Every later change (a new mapping, a new
  frontmost app, a role change) is pushed with `HIDPPLink.setConfiguration(_:at:)`. A mouse is
  therefore never diverted before the app knows which mouse it is, and every button event
  already carries its source.
- **Everything is addressed.** Button events and raw movement carry a `DeviceAddress` (see
  [Identity](#identity)), so two mice with the same buttons never share state.
- **The hub handles the receiver, the endpoint handles the mouse.** Receiver-level reports
  (`40`, `41`) and receiver registers belong to the hub. Reports with a slot's device index go to
  that slot's endpoint. A direct link has one endpoint at index `FF` and no receiver logic.
- **One endpoint cannot hold up another** beyond the [request gate](#the-request-gate): each has
  its own operation queue, retry timer, backoff counter and wake-up debounce.
- **Nothing is written to a mouse before the gate passes.** Identification only reads (see
  [The capability gate](#the-capability-gate)). The one write before that goes to the receiver
  itself: its notification flags, once per link.
- **On quit or removal** the endpoint hands diverted buttons back with fire-and-forget
  `setCidReporting` messages (`restoreMessages`), and releases any held button first.

`MXVerticalController` (also in `Device/EndpointController.swift`) is a facade over a private
one-link hub with the single-mouse API of earlier versions. Only the older controller tests use
it; the app and the probe talk to `HIDPPLink`.

## Interfaces and transports

Upright watches for Logitech (`046D`) HID interfaces on usage page `FF00` (receivers and USB),
usage page `FF43` (Bluetooth LE) and the generic mouse usage (`0001:0002`; many Bluetooth mice
carry HID++ inside their mouse interface). `InterfaceClassifier.classify` then decides, from the
product ID, the IOHID `Transport` string and the usage, what to do with each match:

| Connection | Product IDs | Interface | Device index |
| --- | --- | --- | --- |
| Unifying receiver | `C52B`, `C532` | Vendor page `FF00` | `01`-`06` |
| Bolt receiver (*unverified*) | `C548` | Vendor page `FF00` | `01`-`06` |
| Nano receivers (*unverified*) | `C52F`, `C531`, `C534`, `C537`, `C518`, `C51A`, `C51B`, `C521`, `C525`, `C526`, `C52E`, `C535` | Vendor page `FF00`; pairing registers as on Unifying | `01`-`06` |
| USB cable | The model's own ID (MX Vertical `C08A`), or `C07D`-`C094` | Vendor page `FF00` when it exists, else the mouse interface | `FF` |
| Bluetooth | The model's own ID (MX Vertical `B020`), or `B012`-`B0FF` | Vendor page `FF43`, or the mouse interface itself when macOS exposes no separate HID++ one | `FF` |

Never opened, with the reason logged once per interface:

- **Lightspeed receivers** (`C539`, `C53A`, `C53D`, `C53F`, `C541`, `C545`, `C547`, `C54D`): every
  G-series and PRO mouse in the research data keeps its buttons in onboard profiles (`0x8100`)
  and lacks `0x1B04`; G HUB owns these receivers, and the `C53A` also carries a PowerPlay chip.
  Re-enabling one is a table change in `InterfaceClassifier` and `DeviceCatalog.receivers`, if a
  probe dump ever shows `0x1B04` behind it.
- The 27 MHz receiver `C517` (HID++ 1.0 only) and any other unrecognized receiver in `C500`-`C5FF`.
- **Keyboards**: the product ID ranges `C32B`-`C344` (USB) and `B317`-`B3FF` (Bluetooth). A model
  listed in the catalog wins over these ranges. This is the first of two anti-hijack layers; the
  second is the [capability gate](#the-capability-gate).
- A receiver on a Bluetooth transport, a receiver's boot-mouse or keyboard interface, and any
  other transport string than USB or Bluetooth.

**Twin interfaces.** A USB device or a receiver publishes a vendor-page HID++ interface and a
mouse interface; a Bluetooth mouse can appear twice. Opening two interfaces of one device would
interleave HID++ replies, so `InterfaceClassifier.twinsToReplace` keeps one: interfaces with the
same vendor, product and (non-zero) location ID whose serial numbers don't contradict each other
are the same device, and the vendor-page interface wins. An interface without a location ID is
never treated as a twin. `identityKey` (vendor, product, usage page, usage, then serial, else
location ID, else registry entry ID) identifies an interface across re-matching.

The wireless product ID a receiver reports for an MX Vertical is `407B`.

## Pairing layouts

How mice show up depends on how they are connected. This table is what Upright does in each
layout. "Link" is one opened HID interface; "endpoint" is one mouse.

| Layout | Links | Endpoints | Notes |
| --- | --- | --- | --- |
| One mouse on a receiver | 1 | 1, at the mouse's slot | The usual case (verified with a Unifying receiver and an MX Vertical). |
| Several mice on one receiver | 1 | One per mouse slot | All share the receiver's [request gate](#the-request-gate). Slots `1`-`6` are always scanned, whatever capacity the receiver claims. Simulator only. |
| A mouse and a keyboard on one receiver | 1 | 1 (the mouse) | A slot the pairing table lists as a keyboard (or numpad, presenter, remote) gets no endpoint and no traffic. A slot listed with an unknown kind is probed read-only, and is then either served or ends in `.unsupported`. |
| Several receivers | One each | One per mouse | Each link has its own client, gate and notification flags. Slot numbers repeat across receivers (slot `1` of two receivers is not the same slot); `DeviceAddress` includes the link number. |
| Bluetooth mouse | 1 | 1, at `FF` | One endpoint per interface. Verified with an MX Vertical over BLE. |
| USB cable | 1 | 1, at `FF` | As above. Verified with an MX Vertical. |
| A mix of the above | One per interface | One per mouse | For example an MX Vertical on a Unifying receiver, an MX Master 3S on a Bolt receiver and a Lift over Bluetooth: three links, three endpoints (this is Demo Mode's fleet). |
| Two identical mice | As above | Two, with different `DeviceID`s | They get separate state, preferences and a "#2" suffix, and share one mapping setup (the mappings belong to the model). |
| **The same unit on two links** | 2 | 2, same `DeviceID` | See below. |

### The same unit on two transports

A mouse can be reachable twice at once: a cable plus its receiver, a receiver plus Bluetooth, or
a mouse switched between Easy-Switch channels. When two endpoints identify as the same stable
`DeviceID`, `DeviceRegistry` gives each a role:

- One is `.active`: it is served, and its events are handled.
- The others are `.standby(of:)` the active one: they are kept native (nothing diverted unless a
  button is still held), their button presses and movement are dropped, and they are not counted
  twice in `FleetSummary`.

The winner is the endpoint that is *connected* (one that sleeps or waits loses), then the better
link (USB, then receiver, then Bluetooth, `DeviceRegistry.linkRank`), then the one seen first.
Roles are recomputed on every change, so when the active endpoint leaves or stops answering, the
standby is promoted (the mouse switched to its Bluetooth channel leaves its receiver slot
asleep, and the Bluetooth endpoint becomes active). Without a stable `DeviceID` (no unit ID and
no serial), Upright cannot know the two endpoints are one mouse and treats them as two.

*Unverified:* that the `0x0003` unit ID is identical across the transports of a real MX Vertical,
and whether MX mice keep their wireless link while cabled. `upright-probe --all` over two
transports shows both (look for the `Unit ID` line under `Identity`); if the IDs differ, only
this deduplication is lost.

### Receiver events that change a layout

| Event | Reaction |
| --- | --- |
| A mouse is **re-paired to another slot** of the same receiver | The new slot gets a new endpoint. When it identifies with the same stable `DeviceID` as an endpoint on another slot of that hub, the old endpoint is *retired*: held buttons released, diverted buttons handed back (fire-and-forget), `onEndpointRemoved(.retired(movedTo:))`. |
| A slot is **un-paired** (`40` with the un-pair bit) | Only that endpoint is removed (`.unpaired`, nothing is sent to the gone device). |
| A slot now holds **another device** (a `41` with another wireless PID) | The old endpoint is removed (`.replaced`) and a new one starts. An unsupported endpoint whose wireless PID was never learned is checked once more. |
| The HID interface goes away | Every endpoint of the link is dropped (`.transportClosed`) and the link number is never reused. |

### Receiver pairing registers

The pairing table is a HID++ 1.0 long register, `B5`, read through device index `FF`. Where the
slot is listed depends on the receiver family (`PairingLayout`, `Device/ReceiverDirectory.swift`):

| Layout | Used by | Sub-register for slot *n* | Reply parameters |
| --- | --- | --- | --- |
| `unifying` | Unifying, and every Nano receiver | `20 + (n - 1)`, so `20`-`25` | `<sub> <destination ID> <report interval> <wpid hi> <wpid lo> <?> <?> <kind>`; kind is the low nibble of byte 7 |
| `bolt` (*unverified*) | Bolt | `50 + n`, so `51`-`56` | `<sub> <kind> <wpid lo> <wpid hi> <serial:4> …`; kind is the low nibble of byte 1 |

On Bolt, the wireless PID a slot reports is the mouse's Bluetooth LE ID (an MX Master 3S shows
`B034` there). The Bolt layout and the Nano receivers' use of the Unifying layout follow Solaar
and are simulator-tested only.

Kind nibbles (HID++ 1.0, pairing records and `41` notifications): `0` unknown, `1` keyboard,
`2` mouse, `3` numpad, `4` presenter, `7` remote, `8` trackball, `9` touchpad. A zero wireless
PID marks an empty slot. A device's own `0x0005` answer outranks the nibble.

## Identity

Four different identifiers exist, because "which mouse is this" has four different answers:

| Identifier | Type | Built from | Lifetime | Used for |
| --- | --- | --- | --- | --- |
| **`DeviceAddress`** | `link` (per opened HID interface, counted from 1, never reused in a process) + `index` (`1`-`6`, or `FF`) | where the endpoint lives right now | One connection. A re-pair, a transport change or a re-plug gives a new address. | Routing: button events, raw movement, engine and gesture state, the applied-configuration cache, device actions, battery policy, the UI selection. Always unique among live endpoints, and known before the mouse identifies. Never persisted. |
| **`DeviceID`** | `u:<model>:<unit ID>`, else `s:<model>:<serial>`, else `t:<link>.<index>` | the unit ID (`0x0003` function 0, bytes 1-4, 8 hex digits, if non-zero), else the serial (`0x0003` function 2, version 4 and later), else a transient ID | Permanent for `u:` and `s:` IDs. A `t:` ID lasts one connection and is never saved. | Per-mouse preferences (nickname, "Remap this mouse", pointer speed, last seen), the same-unit dedupe, re-pair detection, notification text. Never routes events. |
| **`ModelKey`** | `046D:XXXX`, else `name:<lowercased name>` | see below | Permanent, and the same on every transport | Mappings (one setup per model), catalog lookups, control names, suggested setups. |
| IOKit identity key | `vendor:product:page:usage` plus serial, else location ID, else registry entry ID | the IOHID properties | One `IOHIDDevice` | Twin-interface dedupe at match time only. |

Consequences worth remembering:

- Two units of one model have different `DeviceID`s but one `ModelKey`, so they share a button
  setup and keep independent held buttons, gesture state and pointer speed.
- A mouse that reports neither unit ID nor serial still works (its address is unique). Its
  preferences fall back to the model's seed, the Mice pane says that settings for it can't be
  remembered, and the probe prints `Device ID: t:… (transient …)`.
- The receiver's own copy of a slot's serial (`B5` sub-register `30 + (n - 1)` on Unifying and
  Nano, the pairing record on Bolt) can be read with `ReceiverDirectory.readSerial`, but only
  `upright-probe --all` does; it does not feed `DeviceID`.

### The model key

`ModelKey` is the same whichever way the mouse is connected. `DeviceCatalog.modelKey(for:)` takes:

1. the first catalog model that matches any model ID the mouse reports in `0x0003` function 0
   (the catalog key is that model's first Bluetooth ID, else its first wireless ID, else its USB
   ID);
2. otherwise the first of the reported IDs in the order Bluetooth, Bluetooth LE, wireless, USB;
3. otherwise the transport PID (the wireless PID from the receiver, or the IOHID product ID),
   through the catalog's aliases;
4. otherwise `name:<lowercased name>`.

The MX Vertical reports `407B`, `C08A` and `B020` on its three transports and always gets
`046D:B020` (`ModelKey.mxVertical`). A mouse the catalog doesn't know yet gets
`046D:<its canonical 0x0003 ID>`, which is exactly the key the catalog entry will have once
someone adds it, so saved mappings survive that addition. Do not change an existing catalog key.

### Reading the identity

`DeviceFeatures.identity` and `DeviceIdentity.parseFirmwareIDs` read `0x0003` function 0
(`getEntityCount`). The reply is
`<entity count> <unit ID:4> <?> <transport bits> <model IDs:6> <extended model ID>`:

- The transport bits (byte 6) say which model IDs follow: `01` Bluetooth, `02` Bluetooth LE,
  `04` wireless (receiver), `08` USB. One big-endian ID per set bit is packed into bytes 7-12 in
  that order, so at most three fit.
- A unit ID of `00000000` means "none".

`getDeviceSerialNumber` (function 2, only from `0x0003` version 4) gives the serial, and
`DEVICE_NAME` (`0x0005`) function 2 gives the device kind: `0` keyboard, `1` remote, `2` numpad,
`3` mouse, `4` touchpad, `5` trackball, `6` presenter, `7` receiver.

## The capability gate

What Upright serves is decided by what a device answers, never by its name or product ID. The
gate lives in `DeviceSession.start()` and runs on every endpoint, receiver slot or direct link.
In order, with reads only:

1. **Protocol version** (`Root` function 1 ping). HID++ 1.0 answers `01` (invalid sub-ID), or
   the version is below 2: `.unsupported(.hidpp10)`.
2. Feature table (`0x0001`), name (`0x0005`), identity (`0x0005` kind, `0x0003` IDs and serial).
3. **Pointer?** If the device reported its own kind (`0x0005` function 2), that is
   authoritative: mouse, trackball and touchpad pass, anything else gives
   `.unsupported(.notAPointer)`. Without an answer, the receiver's pairing kind stands in for
   it: a keyboard, numpad, presenter, remote or receiver is rejected, and a mouse, trackball or
   touchpad passes. If neither source says (kind unknown), the device passes only when one of
   its controls carries the `mse` (mouse button) flag.
4. **`0x1B04` REPROG_CONTROLS_V4** must exist: otherwise `.unsupported(.noReprogControls)`.
   This is where the G-series and PRO mice end.
5. At least one **configurable control** (divertable, not virtual, not a primary click):
   otherwise `.unsupported(.noConfigurableControls)`. Touchpads usually end here.

Only then does the session read the battery, firmware, pointer speed and Easy-Switch channels,
and only after the hub's configuration is known does anything get written
(`setCidReporting`).

`.unsupported` is terminal: no retry, no writes, never diverted. The endpoint stays in the
registry (the Mice pane lists it under "Other Logitech devices" with the reason), and a
receiver slot is re-checked only if another device shows up in it. A keyboard that the receiver
lists as a keyboard never gets an endpoint at all. Left and Right click are never diverted,
whatever a device's flags say (`ControlCatalog.neverDivert`).

Because the decision is by capability, a Logitech mouse that is not in `DeviceCatalog` can still
be served, and a catalog model can still be rejected if its firmware answers differently.

## The request gate

A `HIDPPClient` (one per `HIDPPLink`, so one per HID interface) multiplexes requests and replies.
Its gate (`RequestGate` in `HIDPP/HIDPPClient.swift`) limits how many requests wait for a reply
at once:

- **One request in flight per transport.** `ControllerTuning.maxInFlight` is `1`, and the hub
  applies it to its client. A bare `HIDPPClient` is unlimited. Requests beyond the limit queue
  in FIFO order. Two links (two receivers, or a receiver and a Bluetooth mouse) have separate
  gates and do not wait for each other.
- **Two lanes.** `Lane.interactive` requests (button diversion, pointer speed) go ahead of
  `Lane.background` ones (probing, the feature table, battery, device information). The lane is
  the task-local `HIDPPClient.lane`; `EndpointController` sets `.interactive` around
  `applyDiversion` and `setDPI`, and everything else is background.
- The timeout counts from the moment the request leaves the gate, not from when it was queued.
  A "busy" reply is sent again (up to 2 more times, 50 ms apart); each attempt goes through the
  gate again.
- `sendWithoutReply` bypasses the gate. It carries the shutdown "restore" messages, retiring an
  endpoint's undivert, and the Easy-Switch `setCurrentHost`, none of which are answered.

The effect: a sleeping slot's probe interleaves request by request with the other slots instead
of blocking them for a whole `start()`, and the worst delay for a diversion change is one request
timeout (1 s for a receiver ping, 2 s for any other request) behind a probe that gets no answer.
One mouse sees the same wire pattern as before the gate existed.

**Why one?** It is *unverified* whether real receivers tolerate concurrent requests to different
slots. The limit is the conservative guess; relaxing it is one value (`maxInFlight`), and
hardware evidence should come first. Replies are matched to requests by device index, sub-ID
and address, and the simulator records the highest overlap it saw (`requestsInFlightMax`,
`MultiDeviceControllerTests.testOneRequestInFlightPerTransport`).

## Framing

| Report | ID | Length | Used for |
| --- | --- | --- | --- |
| Short | `10` | 7 bytes | HID++ 1.0 receiver register access, receiver notifications |
| Long | `11` | 20 bytes | All HID++ 2.0 feature calls and events |
| Very long | `12` | 64 bytes | Parsed but not sent by Upright |

```
[report ID] [device index] [feature index | sub-ID] [function << 4 | software ID] [params…]
```

- **Device index.** `FF` means the receiver itself, or a mouse connected by cable or Bluetooth.
  `01`-`06` is a receiver slot.
- **Software ID.** Upright uses `A`. Events from the device always carry software ID `0`, which
  is how replies are told apart from events.
- **Errors.** HID++ 2.0 errors come back as `11 idx FF <feature idx> <fn|sw> <code>`. HID++ 1.0
  errors come back as `10 idx 8F <sub-ID> <address> <code>`. `HIDPPClient` matches both to the
  pending request.
- **Busy.** HID++ 2.0 error `08` and HID++ 1.0 error `07` mean "ask again". `HIDPPClient`
  resends the request up to 2 more times, 50 ms apart, before returning the error.
- **Timeouts.** A request that gets no reply fails after 2 s (1 s for receiver pings and pairing
  reads, `ControllerTuning.probeTimeout`).

### Errors that mean "not reachable right now"

A timeout, a failed send, or a HID++ 1.0 error `04` (connection failed), `08` (unknown device)
or `09` (resource error) from a receiver. Upright treats these as the mouse being asleep or
away, not as a fatal error. See [Connection states](#connection-states).

## Receiver registers (HID++ 1.0)

Registers are addressed through sub-IDs `80` (write, short reply), `81` (short read) and `83`
(long read). Upright sends them as short reports to device index `FF`.

| Register | Request | Purpose |
| --- | --- | --- |
| `00` notifications | read `10 FF 81 00 00 00 00`; write `10 FF 80 00 <b0> <b1> <b2>` | Three flag bytes. Bit `01` of byte 1 is wireless notifications, bit `08` is software present. Without them the receiver doesn't announce link changes. |
| `02` connection state | `10 FF 80 02 02 00 00` | Writing `02` makes the receiver send a `41` notification for every paired device ("fake arrival"). Used only when the pairing list can't be read. |
| `B5` pairing info | `10 FF 83 B5 <sub-register> 00 00` | Long read; see [Receiver pairing registers](#receiver-pairing-registers). |

- **Read-modify-write.** Register `00` is read first and written back with `01 | 08` OR-ed into
  byte 1 and every other flag kept, so a flag another program set (Logi Options+, Solaar) is not
  cleared. A receiver that refuses the read gets the two flags alone (`00 09 00`). This happens
  once per link, at link start and when the Mac wakes, and not on every slot's reconfiguration
  (`ensureNotifications`, shared by concurrent callers); it is repeated when a slot comes back
  after losing its link.
- The `B5` read doesn't wake any device. HID++ 1.0 errors `01` or `02` mean the receiver lacks
  the register (Upright then falls back to the `02` announcement and to probing slots in turn);
  any other error means the slot is empty. A timeout stops the scan, keeping what was read.

### Receiver notifications

| Notification | Layout | Upright's reaction |
| --- | --- | --- |
| `41` device connection | `10 0n 41 <kind/flags> <wpid lo> <wpid hi> …` | Flags bit 6 (`40`) clear: link to slot *n* established. Set: link lost. Low nibble: device kind. The wireless PID is little-endian here. |
| `40` device disconnection | `10 0n 40 <type> …` | `type` bit 1 (`02`) set: the device was un-paired. Other disconnections carry nothing to act on. |

On link-up for a known slot, the endpoint reapplies its configuration (ignoring echoes caused by
Upright's own `02` announcement request, tracked per slot). On link-up for a slot nobody serves, the hub
starts an endpoint there (unless the slot is a keyboard or another non-pointer). On link-lost it
releases held buttons and shows the mouse as asleep. On an un-pair it removes the endpoint.
A device report from a slot nobody serves means a link-up was missed: the hub checks the device
there.

## Discovery

For a receiver, `HIDPPLink.discover` does:

1. Turn on notifications (read-modify-write of register `00`).
2. Read the pairing table (`B5`) for slots 1 to 6. Each occupied slot whose kind isn't a
   keyboard or another non-pointer gets an endpoint, which probes it. Slots listed as such are
   skipped and logged once.
3. If the table can't be read: write register `02` and wait 0.3 s (`announcementWait`) for `41`
   announcements. If none arrive, ping slots 1 to 6 in turn (1 s each), skipping slots that
   already have an endpoint or are known to hold a non-pointer.
4. If there is still no mouse and notifications could not be enabled, rediscover with backoff.

For a direct link the hub starts one endpoint at `FF`.

Each endpoint then identifies its device with a ping, the feature lookups and reads of the
[capability gate](#the-capability-gate):

| Step | Request | Reply |
| --- | --- | --- |
| Ping a slot / read protocol version (`Root` fn 1) | `11 0n 00 1A 00 00 <ping>` | `11 0n 00 1A <major> <minor> <ping>`. The ping byte changes per request; a reply with another value is a late answer and is asked again. A HID++ 1.0 error `01` (invalid sub-ID) means a HID++ 1.0 device. Errors `04`/`08`/`09` mean the slot is empty or asleep. |
| Feature index lookup (`Root` fn 0) | `11 0n 00 0A <id hi> <id lo>` | `… <index> <type> <version>` (index `00` = unsupported) |
| Feature table (`0x0001`) | fn 0 → count; fn 1 `<i>` → `<id hi> <id lo> <type> <version>` | |
| Device name (`0x0005`) | fn 0 → length; fn 1 `<offset>` → up to 16 characters; fn 2 → kind | |

A device that doesn't report a name is shown by its IOHID product string (direct link) or as
"Logitech mouse".

## Features used

| ID | Name | Used for |
| --- | --- | --- |
| `0000` | Root | Feature lookup, protocol version |
| `0001` | Feature Set | Feature table |
| `0003` | Device Firmware Version | Unit and model IDs, firmware entries, serial number |
| `0005` | Device Name | Name, device kind |
| `1000` | Battery Status | Battery level (older mice) |
| `1001` | Battery Voltage | Battery level estimated from voltage; read-only (*unverified*) |
| `1004` | Unified Battery | Battery level or coarse level |
| `1814` | Change Host | Easy-Switch channel count, current channel, switching |
| `1815` | Hosts Info | Easy-Switch host names |
| `1B04` | Reprog Controls v4 | The capability gate, button diversion, raw XY, button events |
| `1D4B` | Wireless Device Status | Reconnect events |
| `2201` | Adjustable DPI | Pointer speed |

Other features in the table (for example SmartShift `2110`, Hi-Res Wheel `2121`, the older
`1B00`-`1B03` controls, `2202` and `2205` pointer-speed variants) are listed in the probe output
and the Mice pane but never called. A mouse with only `2202` or `2205` gets no pointer-speed UI.

## Button diversion (`0x1B04` REPROG_CONTROLS_V4)

| Function | Params | Reply |
| --- | --- | --- |
| 0 `getCount` | | `<count>` |
| 1 `getCidInfo` | `<index>` | `<cid:2> <tid:2> <flags> <pos> <group> <gmask> <additional flags>` |
| 2 `getCidReporting` | `<cid:2>` | `<cid:2> <reporting flags> <remap:2>` |
| 3 `setCidReporting` | `<cid:2> <flags> 00 00` | echo |

- **Capability flags (`getCidInfo`, byte 4).** `01` mouse button, `02` Fn key, `04` non-standard,
  `08` Fn-sensitive, `10` reprogrammable, `20` divertable, `40` persistently divertable, `80`
  virtual. Upright offers a control for remapping when it is divertable, not virtual, and not
  left or right click (`ControlInfo.isConfigurable`).
- **Additional flags (byte 8).** Bit `01` means the control can report raw pointer movement
  while held ("raw XY"). The probe marks these controls `raw XY`.
- **Reporting flags (`setCidReporting`).** Each setting has a "valid" bit shifted one place
  left, which tells the mouse to apply the setting next to it.

  | Bit | Meaning |
  | --- | --- |
  | `01` / `02` | Diverted / diverted valid |
  | `04` / `08` | Persistently diverted / valid. **Never set** by Upright. |
  | `10` / `20` | Raw XY diverted / valid |

  Resulting values: `03` diverts temporarily, `02` un-diverts. For a control that supports raw
  XY, Upright always sends the raw XY valid bit too: `33` diverts and enables raw XY, `23`
  diverts without raw XY, and `22` un-diverts and turns raw XY off. Controls without the raw
  XY capability never receive the raw bits (`03` / `02`). On quit, the un-divert message is
  `22` for controls that had raw XY on and `02` otherwise. Nothing survives a power cycle.
- **Event 0, `divertedButtonsEvent`.** `11 idx <feature idx> 00 <cid1:2> <cid2:2> <cid3:2> <cid4:2>`
  lists the diverted controls currently held. All zeros means everything was released. The
  tracker turns each snapshot into press and release events stamped with the endpoint's address.
- **Event 1, `divertedRawMouseXYEvent`.** `11 idx <feature idx> 10 <dx:2> <dy:2>`, both signed
  16-bit values. Sent repeatedly while a raw-XY control is held, instead of the pointer
  moving. Positive `dy` is down. The gesture recognizer sums them per mouse and fires a
  direction at a threshold that depends on that mouse's current pointer speed.
- **Version 5 quirk (*unverified*).** On `0x1B04` version 5 and later, the first raw-XY report
  after a raw-XY control goes down is dropped (Solaar notes a bogus first movement on the
  MX Master 3S). It is isolated in `DeviceSession.isSpuriousRawXYReport`.

Controls are named by CID. The model's catalog entry decides the order and wording where it
has an opinion, otherwise the generic name from Solaar's table applies, and an unknown CID shows
as "Button 0xNNNN". The MX Vertical's controls:

| CID | Button |
| --- | --- |
| `0052` | Wheel click |
| `0053` | Back (lower thumb button) |
| `0056` | Forward (upper thumb button) |
| `00FD` | Top button behind the wheel (DPI switch) |

Other models report different sets (for example `00C3` the gesture button and `00C4` SmartShift
on the MX Master family, `005B`/`005D` tilt left and right); the same CID can mean something
different on another model, which is why mappings are kept per model. Which controls are diverted
depends on the frontmost app's profile for that mouse's model, so the set is re-sent when the app
in front changes. A button that is still held stays diverted until released.

## Pointer speed (`0x2201` ADJUSTABLE_DPI)

| Function | Params | Reply |
| --- | --- | --- |
| 1 `getSensorDpiList` | `<sensor>` (always `00`) | `<sensor> <value:2>… 00 00` |
| 2 `getSensorDpi` | `<sensor>` | `<sensor> <current:2> <default:2>` |
| 3 `setSensorDpi` | `<sensor> <dpi:2>` | echo |

- **List encoding.** Values are listed one by one and end with `0000`. A value whose top three
  bits are set (`E000` or above) is a *step*, not a value: the low 13 bits are the increment,
  and the next 16-bit value is the end of the range. `01 90 E0 32 0F A0` means 400, then 450,
  500… up to 4000 in steps of 50.
- A current value of `0000` is read as the default value.
- `setSensorDpi` sends the supported value nearest to the request. Many mice forget it on
  reconnect, so Upright sends it again on every (re)configuration for as long as it has a
  speed to keep. The speed is kept per mouse; nothing is broadcast to other mice.
- A button that changes the speed natively (when it isn't diverted) is respected: Upright
  re-reads the speed when the Mice pane or menu opens and adopts the mouse's value as the one to keep.
- A mouse without `0x2201` has no pointer speed in Upright.

## Firmware, serial and identity (`0x0003` DEVICE_FW_VERSION)

| Function | Params | Reply |
| --- | --- | --- |
| 0 `getEntityCount` | | `<count>`, then unit ID, transport bits and model IDs (see [Reading the identity](#reading-the-identity)) |
| 1 `getFwInfo` | `<entity>` | `<type> <prefix:3 ASCII> <number> <revision> <build:2> …` |
| 2 `getDeviceSerialNumber` | | Up to 12 printable ASCII bytes. Only asked when the feature version is 4 or higher. |

`type` is the low nibble: `0` firmware, `1` bootloader, `2` hardware (the version is byte 1),
other values ignored. At most 16 entries are read. Number and revision are BCD; a non-zero build
is appended as `.B<hex>`, giving strings like `RBM 14.00.B0015`.

## Easy-Switch (`0x1814` CHANGE_HOST, `0x1815` HOSTS_INFO)

| Feature | Function | Params | Reply |
| --- | --- | --- | --- |
| `1814` | 0 `getHostInfo` | | `<host count> <current host (0-based)> …` |
| `1814` | 1 `setCurrentHost` | `<host>` (0-based) | **None.** The mouse leaves immediately. |
| `1815` | 0 `getFeatureInfo` | | Byte 0 bit `01`: the mouse stores host names |
| `1815` | 1 `getHostInfo` | `<host>` | Byte 1 non-zero: paired. Byte 4: name length. |
| `1815` | 3 `getHostFriendlyName` | `<host> <offset>` | `<host> <offset> <up to 14 characters>` |

`setCurrentHost` is sent with no reply expected (it bypasses the request gate). The usual
link-lost handling then shows the mouse as asleep. Only that slot sleeps; the other mice on the
receiver keep their sessions. Host names are read for up to 8 hosts, 14 bytes per page. Upright
only switches when the requested channel exists and isn't the current one.

## Battery

| Feature | Calls | Notes |
| --- | --- | --- |
| `1004` Unified Battery | fn 0 `getCapabilities` → `<levels> <flags>`; fn 1 `getStatus` → `<charge %> <level flags> <status> <external power>` | Capability flags bit `02` = reports a percentage. |
| `1000` Battery Status | fn 0 → `<level %> <next level %> <status>` | Used when `1004` is absent. Level 0 while charging keeps the previous level. |
| `1001` Battery Voltage (*unverified*) | fn 0 → `<millivolts:2> <flags>` | Used when neither of the others exists. Flags bit 7: on external power. The level is estimated from a lithium-ion curve and marked approximate. |

- **Level flags (`1004`).** `01` critical, `02` low, `04` good, `08` full. When the mouse has no
  percentage (or reports 0), Upright shows representative values: 5, 20, 50 and 90, marked
  as approximate ("~50%").
- **Status.** `1004`: `0` discharging, `1` charging, `2` slow charging, `3` complete (full on
  power), `4` error. `1000`: `0` discharging, `1` recharging, `2` almost full, `3` full on
  power, `4` slow recharge, `5`-`7` errors.
- `1004`, `1000` and `1001` broadcast their status as event 0 on their feature index. Upright
  also reads the level on connect, after every reconfiguration, and every 10 minutes.
- Low battery alerts are tracked per mouse. They fire once at 15% and once at 5% per discharge,
  and re-arm when charging or when the level rises above 20%. For approximate readings the
  coarse "low" level (20) counts as low, and only "full" (90) or charging re-arms, because the
  voltage-based levels can flicker between low and good.

## Staying configured

Each endpoint keeps its own mouse configured:

| Signal | Meaning | Upright's reaction |
| --- | --- | --- |
| Receiver `41`, flags bit 6 clear | Link to slot *n* established | That endpoint reapplies diversion, or identifies the device if it hasn't yet |
| Receiver `41`, flags bit 6 set | Link lost (mouse off or asleep) | That endpoint releases held keys and shows "Asleep" |
| Receiver `40`, type bit 1 set | Device un-paired | That endpoint is removed |
| `0x1D4B` event 0, status `01` | Device reconnected and needs reconfiguring | That endpoint reapplies diversion |
| Any report from a mouse that isn't configured | It is awake | That endpoint reconfigures (or identifies the device) right away |
| macOS wake / screens wake / session active | Mac resumed | Every endpoint reapplies; each receiver also re-asserts its notification flags once |
| IOKit device removed / matched | Receiver or cable unplugged / replugged | The link and its endpoints are torn down / identified again |

Wake-up signals that arrive within 0.6 s of each other (`ControllerTuning.reconnectDelay`) are
coalesced into one reconfiguration per endpoint. A reconfiguration re-sends all button reporting
state (forced), re-applies the kept pointer speed, re-reads the Easy-Switch channel and the
battery, after re-enabling receiver notifications if the slot had lost its link.

## Connection states

`EndpointController.State` is a small state machine per mouse:

| State | Meaning |
| --- | --- |
| `probing` | Identifying the mouse (first pass only) |
| `waitingForDevice` | Nothing answered yet: off, asleep, or paired to another computer |
| `connected` | Found and configured |
| `asleep` | Was connected, now silent. Its session is kept. |
| `unsupported` | Not a mouse Upright serves (see the [capability gate](#the-capability-gate)). Terminal. |
| `failed` | The device can't be used right now. `Disconnected` (HID interface closed) is terminal. |

`DeviceRegistry` adds a *role* on top for the app: `active`, `standby(of:)` (a second link to a
unit that is served elsewhere), `unsupported` or `pending` (not identified yet).

- **Backoff.** Retries wait 1 s, then 2 s, 4 s… doubling up to 30 s, and then repeat every 30 s.
  They never stop while the HID interface is open, and are independent per endpoint. A signal
  that the mouse is awake (a report, `41`, `0x1D4B`, Mac wake) cancels the wait and reconfigures
  after the 0.6 s coalescing delay. The hub itself only rediscovers (with the same backoff) when
  no mouse has been found and the receiver's notifications could not be enabled.
- Discovery and reconfiguration, pointer speed, battery and device-info refreshes of one
  endpoint all run on that endpoint's serial operation queue. Requests with the same purpose are
  coalesced; requests of different endpoints interleave at the request gate.
- If reconfiguring fails for a reason other than "not reachable", the session is dropped and
  the mouse is identified again from scratch.
- `DeviceManager` adds one more layer, per interface: if no mouse on a link answers, it re-opens
  that interface (up to 3 times, with a growing delay) in case the open one belongs to a
  pre-reconnect device. When no other interface has a mouse, it restarts the whole source. A
  device that is merely unsupported never triggers it.
- On quit, every endpoint's `restoreMessages` sends the un-divert request for each diverted
  control, without waiting for replies.

## What is not verified

Hardware-tested: the MX Vertical alone, on a Unifying receiver, over USB and over Bluetooth LE,
one mouse at a time. The rest is built from Solaar and libratbag data, exercised in the
simulator, and open for confirmation by anyone who owns the device. The most useful
confirmations, in `make probe ARGS=--all` terms:

| Item | How to confirm |
| --- | --- |
| The `0x0003` unit ID is identical for one mouse over Bluetooth, USB and a Unifying receiver | Compare the `Unit ID` lines of the same mouse over two connections. |
| Bolt pairing layout (`50 + n`) and Bolt `41` behaviour | Run the probe with a Bolt receiver; the `Pairing table (Bolt layout)` lines show each slot's wireless PID and kind. |
| Nano receivers use the Unifying layout | Run the probe with a Nano receiver; the `Pairing table (Unifying layout)` lines should list the paired mouse. |
| Receivers tolerate interleaved requests to different slots (the reason for `maxInFlight = 1`) | Run the probe with `--trace` on a receiver with two mice. |
| Other models' Bluetooth interface is matched by the generic mouse entry and uses device index `FF` | The probe's `→` line for the mouse shows its interface (`usage 0001:0002` or a vendor page) and what Upright does with it. |
| `0x0005` kinds and pairing nibbles on real firmware | The `Kind:` line of the identity block. |
| The raw-XY first-report quirk on `0x1B04` v5 and the raw-XY scale on non-Vertical mice | Hold a gesture button with `--divert` and watch the movement events. |
| Two physical mice at once | Simulator and end-to-end tests only (`EndToEndRoutingTests`). |
| BLE `SerialNumber` and `LocationID` reporting on macOS | The probe's `Ignoring twin interface` lines. |
| Whether MX mice keep their wireless link when cabled | Standby deduplication prevents double actions either way. |
