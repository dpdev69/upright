# HID++ notes

This page lists every message Upright exchanges with the MX Vertical. All values come from
public HID++ documentation and the open-source projects credited in the README. Bytes are hex.

## Framing

| Report | ID | Length | Used for |
| --- | --- | --- | --- |
| Short | `10` | 7 bytes | HID++ 1.0 receiver register access, receiver notifications |
| Long | `11` | 20 bytes | All HID++ 2.0 feature calls |

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

## Discovery

| Step | Request | Reply |
| --- | --- | --- |
| Enable receiver notifications (wireless + software present) | `10 FF 80 00 00 09 00` | echo |
| Ping a slot / read protocol version (`Root` fn 1) | `11 0n 00 1A 00 00 5A` | `11 0n 00 1A <major> <minor> 5A`. A HID++ 1.0 error `09` means the slot is empty or asleep. |
| Feature index lookup (`Root` fn 0) | `11 0n 00 0A <id hi> <id lo>` | `… <index> <type> <version>` (index `00` = unsupported) |
| Feature table (`0x0001`) | fn 0 → count; fn 1 `<i>` → `<id hi> <id lo> <type> <version>` | |
| Device name (`0x0005`) | fn 0 → length; fn 1 `<offset>` → up to 16 characters | |
| Battery (`0x1004` fn 1 or `0x1000` fn 0) | | `<percent> …` |

## Button diversion (`0x1B04` REPROG_CONTROLS_V4)

| Function | Params | Reply |
| --- | --- | --- |
| 0 `getCount` | | `<count>` |
| 1 `getCidInfo` | `<index>` | `<cid:2> <tid:2> <flags> <pos> <group> <gmask> <additional flags>` |
| 2 `getCidReporting` | `<cid:2>` | `<cid:2> <reporting flags> <remap:2>` |
| 3 `setCidReporting` | `<cid:2> <flags> 00 00` | echo |

- **Capability flags (`getCidInfo`).** `01` mouse button, `10` reprogrammable, `20` divertable,
  `40` persistently divertable, `80` virtual.
- **Reporting flags (`setCidReporting`).** `03` diverts temporarily (divert + valid), `02`
  un-diverts. Upright never sets the persistent bits, so nothing survives a power cycle.
- **Event 0, `divertedButtonsEvent`.** `11 idx <feature idx> 00 <cid1:2> <cid2:2> <cid3:2> <cid4:2>`
  lists the diverted controls currently held. All zeros means everything was released.

MX Vertical controls Upright offers:

| CID | Button |
| --- | --- |
| `0052` | Wheel click |
| `0053` | Back (lower thumb button) |
| `0056` | Forward (upper thumb button) |
| `00FD` | Top button behind the wheel (DPI switch) |

Whatever else the mouse reports as divertable and non-virtual appears in the app as
"Control 0xNNNN". The Device pane lists the full control table with flags.

## Staying configured

| Signal | Meaning | Upright's reaction |
| --- | --- | --- |
| `10 0n 41 <proto> <flags> <wpid lo> <wpid hi>`, flags bit 6 clear | Receiver: link to slot *n* established | Reapply diversion, or probe slot *n* if no mouse is known yet (wireless PID `407B` = MX Vertical) |
| Same, flags bit 6 set | Link lost (mouse off or asleep) | Release held keys, show "Asleep" |
| `0x1D4B` event 0, status `01` | Device reconnected and needs reconfiguring | Reapply diversion |
| macOS wake / session active | Mac resumed | Reapply diversion |
| IOKit device removed / matched | Receiver or cable unplugged / replugged | Tear down / probe again |
