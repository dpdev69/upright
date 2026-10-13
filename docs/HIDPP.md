# HID++ notes

This page lists every message Upright exchanges with the MX Vertical and its receiver. All
values come from public HID++ documentation and the open-source projects credited in the
README. Bytes are hex; multi-byte values are big-endian unless noted.

## Transports

Upright opens one HID interface per connection and speaks HID++ over it.

| Connection | Product ID | Interface |
| --- | --- | --- |
| Unifying receiver | `C52B`, `C532` | Vendor usage page `FF00`; device index `01`–`06` |
| Bolt receiver | `C548` | Same layout. The MX Vertical can't pair with Bolt, so this only matters for other models. |
| USB cable | `C08A` | Vendor usage page `FF00` (the mouse interface is skipped when it exists); device index `FF` |
| Bluetooth | `B020` | Usage page `FF43`, or the mouse interface itself when macOS exposes no separate HID++ one; device index `FF` |

The wireless product ID a receiver reports for an MX Vertical is `407B`.

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
  `01`–`06` is a receiver slot.
- **Software ID.** Upright uses `A`. Events from the device always carry software ID `0`, which
  is how replies are told apart from events.
- **Errors.** HID++ 2.0 errors come back as `11 idx FF <feature idx> <fn|sw> <code>`. HID++ 1.0
  errors come back as `10 idx 8F <sub-ID> <address> <code>`. `HIDPPClient` matches both to the
  pending request.
- **Busy.** HID++ 2.0 error `08` and HID++ 1.0 error `07` mean "ask again". `HIDPPClient`
  resends the request up to 2 more times, 50 ms apart, before returning the error.
- **Timeouts.** A request that gets no reply fails after 2 s (1 s for discovery pings).

### Errors that mean "not reachable right now"

A timeout, a failed send, or a HID++ 1.0 error `04` (connection failed), `08` (unknown device)
or `09` (resource error) from a receiver. Upright treats these as the mouse being asleep or
away, not as a fatal error. See [Connection states](#connection-states).

## Receiver registers (HID++ 1.0)

Registers are addressed through sub-IDs `80` (write, short reply) and `83` (long read). Upright
sends them as short reports to device index `FF`.

| Register | Request | Purpose |
| --- | --- | --- |
| `00` notifications | `10 FF 80 00 00 09 00` | Parameter byte 1 = `09`: bit `01` wireless notifications, bit `08` software present. Without this the receiver doesn't announce link changes. Sent at probe time and on every reconfiguration. |
| `02` connection state | `10 FF 80 02 02 00 00` | Writing `02` makes the receiver send a `41` notification for every paired device ("fake arrival"). Used only when the pairing list can't be read. |
| `B5` pairing info | `10 FF 83 B5 <20+n-1> 00 00` | Long read, sub-register `20` to `25` for slots 1 to 6. Reply parameters: `<sub-register> <destination ID> <report interval> <wireless PID hi> <wireless PID lo> …`. A wireless PID of `407B` marks an MX Vertical. |

- The `B5` read doesn't wake any device. HID++ 1.0 errors `01` or `02` mean the receiver lacks
  the register (Upright then falls back to the `02` announcement and to probing slots in turn);
  any other error means the slot is empty.
- Only Unifying receivers are asked for `B5`; Bolt uses a different layout.

### Receiver notifications

| Notification | Layout | Upright's reaction |
| --- | --- | --- |
| `41` device connection | `10 0n 41 <proto> <flags> <wpid lo> <wpid hi>` | Flags bit 6 (`40`) clear: link to slot *n* established. Set: link lost. |
| `40` device disconnection | `10 0n 40 <type> …` | `type` bit 1 (`02`) set: the device was un-paired. |

On link-up for the known slot, Upright reapplies its configuration (ignoring echoes caused by
its own `02` announcement request). On link-up for another slot whose wireless PID is `407B`
(or unknown), it connects there. On link-lost it releases held buttons and shows the mouse as
asleep. On an un-pair it drops the session and waits for a device.

## Discovery

| Step | Request | Reply |
| --- | --- | --- |
| Ping a slot / read protocol version (`Root` fn 1) | `11 0n 00 1A 00 00 <ping>` | `11 0n 00 1A <major> <minor> <ping>`. The ping byte changes per request; a reply with another value is a late answer and is asked again. A HID++ 1.0 error `01` (invalid sub-ID) means a HID++ 1.0 device. Errors `04`/`08`/`09` mean the slot is empty or asleep. |
| Feature index lookup (`Root` fn 0) | `11 0n 00 0A <id hi> <id lo>` | `… <index> <type> <version>` (index `00` = unsupported) |
| Feature table (`0x0001`) | fn 0 → count; fn 1 `<i>` → `<id hi> <id lo> <type> <version>` | |
| Device name (`0x0005`) | fn 0 → length; fn 1 `<offset>` → up to 16 characters | |

Upright accepts only a device whose name contains "MX Vertical". When a receiver lists no
pairings, slots 1 to 6 are pinged in turn (1 s each), skipping slots already known to hold
another device.

## Features used

| ID | Name | Used for |
| --- | --- | --- |
| `0000` | Root | Feature lookup, protocol version |
| `0001` | Feature Set | Feature table |
| `0003` | Device Firmware Version | Firmware entries, serial number |
| `0005` | Device Name | Name check, display |
| `1000` | Battery Status | Battery level (older mice) |
| `1004` | Unified Battery | Battery level or coarse level |
| `1814` | Change Host | Easy-Switch channel count, current channel, switching |
| `1815` | Hosts Info | Easy-Switch host names |
| `1B04` | Reprog Controls v4 | Button diversion, raw XY, button events |
| `1D4B` | Wireless Device Status | Reconnect events |
| `2201` | Adjustable DPI | Pointer speed |

Other features in the table (for example SmartShift `2110`, Hi-Res Wheel `2121`) are listed in
the Device pane but never called.

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
  left or right click.
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
  lists the diverted controls currently held. All zeros means everything was released.
- **Event 1, `divertedRawMouseXYEvent`.** `11 idx <feature idx> 10 <dx:2> <dy:2>`, both signed
  16-bit values. Sent repeatedly while a raw-XY control is held, instead of the pointer
  moving. Positive `dy` is down. The gesture recognizer sums them and fires a direction at
  40 counts of travel; the dominant axis decides.

MX Vertical controls Upright offers:

| CID | Button |
| --- | --- |
| `0052` | Wheel click |
| `0053` | Back (lower thumb button) |
| `0056` | Forward (upper thumb button) |
| `00FD` | Top button behind the wheel (DPI switch) |

Whatever else the mouse reports as divertable and non-virtual appears in the app as
"Control 0xNNNN". The Device pane lists the full control table with flags.

Which controls are diverted depends on the frontmost app's profile, so the set is re-sent
when the app in front changes. A button that is still held stays diverted until released.

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
  speed to keep.
- The top button changes the speed natively when it isn't diverted. Upright re-reads the speed
  when the Device pane or menu opens and adopts the mouse's value as the one to keep.

## Firmware and serial (`0x0003` DEVICE_FW_VERSION)

| Function | Params | Reply |
| --- | --- | --- |
| 0 `getEntityCount` | | `<count>` (at most 16 are read) |
| 1 `getFwInfo` | `<entity>` | `<type> <prefix:3 ASCII> <number> <revision> <build:2> …` |
| 2 `getDeviceSerialNumber` | | Up to 12 printable ASCII bytes. Only asked when the feature version is 4 or higher. |

`type` is the low nibble: `0` firmware, `1` bootloader, `2` hardware (the version is byte 1),
other values ignored. Number and revision are BCD; a non-zero build is appended as `.B<hex>`,
giving strings like `RBM 14.00.B0015`.

## Easy-Switch (`0x1814` CHANGE_HOST, `0x1815` HOSTS_INFO)

| Feature | Function | Params | Reply |
| --- | --- | --- | --- |
| `1814` | 0 `getHostInfo` | | `<host count> <current host (0-based)> …` |
| `1814` | 1 `setCurrentHost` | `<host>` (0-based) | **None.** The mouse leaves immediately. |
| `1815` | 0 `getFeatureInfo` | | Byte 0 bit `01`: the mouse stores host names |
| `1815` | 1 `getHostInfo` | `<host>` | Byte 1 non-zero: paired. Byte 4: name length. |
| `1815` | 3 `getHostFriendlyName` | `<host> <offset>` | `<host> <offset> <up to 14 characters>` |

`setCurrentHost` is sent with no reply expected. The usual link-lost handling then shows the
mouse as asleep. Host names are read for up to 8 hosts, 14 bytes per page. Upright only
switches when the requested channel exists and isn't the current one.

## Battery

| Feature | Calls | Notes |
| --- | --- | --- |
| `1004` Unified Battery | fn 0 `getCapabilities` → `<levels> <flags>`; fn 1 `getStatus` → `<charge %> <level flags> <status> <external power>` | Capability flags bit `02` = reports a percentage. |
| `1000` Battery Status | fn 0 → `<level %> <next level %> <status>` | Used when `1004` is absent. Level 0 while charging keeps the previous level. |

- **Level flags (`1004`).** `01` critical, `02` low, `04` good, `08` full. When the mouse has no
  percentage (or reports 0), Upright shows representative values: 5, 20, 50 and 90, marked
  as approximate ("~50%").
- **Status.** `1004`: `0` discharging, `1` charging, `2` slow charging, `3` complete (full on
  power), `4` error. `1000`: `0` discharging, `1` recharging, `2` almost full, `3` full on
  power, `4` slow recharge, `5`–`7` errors.
- Both features broadcast their status as event 0 on their feature index. Upright also reads
  the level on connect, after every reconfiguration, and every 10 minutes.
- Low battery alerts fire once at 15% and once at 5% per discharge. They re-arm when charging
  or when the level rises above 20%. For approximate readings the coarse "low" level (20)
  counts as low, and only "full" (90) or charging re-arms, because the voltage-based levels
  can flicker between low and good.

## Staying configured

| Signal | Meaning | Upright's reaction |
| --- | --- | --- |
| Receiver `41`, flags bit 6 clear | Link to slot *n* established | Reapply diversion, or probe slot *n* if no mouse is known yet |
| Receiver `41`, flags bit 6 set | Link lost (mouse off or asleep) | Release held keys, show "Asleep" |
| Receiver `40`, type bit 1 set | Device un-paired | Drop the session, wait for a device |
| `0x1D4B` event 0, status `01` | Device reconnected and needs reconfiguring | Reapply diversion |
| Any report from a mouse that isn't configured | It is awake | Reconfigure (or probe that slot) right away |
| macOS wake / screens wake / session active | Mac resumed | Reapply diversion |
| IOKit device removed / matched | Receiver or cable unplugged / replugged | Tear down / probe again |

Wake-up signals that arrive within 0.6 s of each other are coalesced into one reconfiguration.
A reconfiguration re-enables receiver notifications, re-sends all button reporting state
(forced), re-applies the kept pointer speed, re-reads the Easy-Switch channel and the battery.

## Connection states

`MXVerticalController` is a small state machine per HID interface:

| State | Meaning |
| --- | --- |
| `probing` | Looking for the mouse (first pass only) |
| `waitingForDevice` | Nothing answered yet: off, asleep, or paired to another computer |
| `connected` | Found and configured |
| `asleep` | Was connected, now silent. Its session is kept. |
| `failed` | The device can't be used. `Disconnected` (HID interface closed) is terminal. |

- A directly connected mouse that doesn't answer moves to `waitingForDevice` and is retried. A
  receiver is polled only when it can't send notifications or when the MX Vertical's slot is
  known; otherwise Upright waits for the `41` link-up notification.
- **Backoff.** Retries wait 1 s, then 2 s, 4 s… doubling up to 30 s, and then repeat every
  30 s. They never stop while the HID interface is open. A signal that the mouse is awake
  (a report, `41`, `0x1D4B`, Mac wake) cancels the wait and reconfigures after the 0.6 s
  coalescing delay.
- Discovery and reconfiguration, pointer speed, battery and device-info refreshes all run on a
  single serial queue. Requests with the same purpose are coalesced.
- If reconfiguring fails for a reason other than "not reachable", the session is dropped and
  the mouse is probed again from scratch.
- `DeviceManager` adds one more layer: if a direct mouse keeps failing, it re-matches the HID
  interfaces (up to 3 times, with a growing delay) in case the open one belongs to a
  pre-reconnect device.
- On quit, `restoreMessages` sends the un-divert request for every diverted control, without
  waiting for replies.
