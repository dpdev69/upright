# Supported devices

> **This page is derived from [`DeviceCatalog.swift`](../UprightKit/Sources/UprightKit/Device/DeviceCatalog.swift)**
> (`DeviceCatalog.models`, `DeviceCatalog.receivers` and `DeviceCatalog.knownUnsupported`), plus the
> interface rules in
> [`InterfaceClassifier.swift`](../UprightKit/Sources/UprightKit/Device/InterfaceClassifier.swift).
> If the code and this page disagree, the code is right. Update this page whenever the catalog changes.

Upright works with Logitech mice that speak **HID++ 2.0** and expose the programmable-button feature
(`REPROG_CONTROLS_V4`, `0x1B04`). You can use several mice at once, in any mix of USB cable,
Bluetooth and Unifying, Bolt or Nano receivers.

**Only the MX Vertical has been tested on real hardware.** Every other mouse on this page is built
from published device data (Solaar and libratbag dumps) and has been exercised only against
Upright's built-in mouse simulator. Please treat all of them as unverified until someone with the
mouse confirms it.

## What the catalog is, and isn't

The catalog gives a model its name, its list of controls in display order, a suggested setup for
onboarding, and which product IDs belong to it. It does **not** decide whether a mouse is served.
That is decided by what the mouse answers: HID++ 2.0, a pointer, and `0x1B04` with at least one
control Upright can divert. A Logitech mouse that isn't listed below can therefore still work, and a
listed one can still turn out not to (for example because of firmware differences). Upright shows
such a mouse under **Settings → Mice → Other Logitech devices** with the reason.

## Status values

| Status | Meaning |
| --- | --- |
| **Verified on hardware** | Tested by the maintainer on a real mouse. Only the MX Vertical. |
| **Published data** | The catalog entry (product IDs, control list) comes from published device dumps. Simulator-tested in Upright; **not tested on hardware**. |
| **Untested** | Not in the catalog. If the mouse answers HID++ 2.0 with programmable buttons, Upright serves it, but nothing is known about it. |

## Mice in the catalog

PIDs are hexadecimal USB product IDs under Logitech's vendor ID `046D`. "Receiver / Bolt wireless
PIDs" are what a Unifying, Nano or Bolt receiver reports for the mouse; a `Bxxx` value there means
the mouse reports its Bluetooth ID through a Bolt receiver, which is why those rows list "Bolt
receiver". The catalog does not say which of Unifying or Nano a given mouse shipped with.
Upright reads that from the receiver itself. "Controls" are the remappable controls in the order
the catalog lists them. What a particular unit really exposes is read from the mouse.

| Model | USB PID | Bluetooth PIDs | Receiver / Bolt wireless PIDs | Connections | Controls | Status |
| --- | --- | --- | --- | --- | --- | --- |
| MX Vertical | `C08A` | `B020` | `407B` | USB cable, Bluetooth, Unifying receiver (it can't pair with Bolt) | Back, Forward, Top (DPI) button, Wheel click | Verified on hardware |
| MX Master | - | `B012`, `B01E` | `4041`, `4071` | Bluetooth, Unifying / Nano receiver | Back, Forward, Gesture button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Master 2S | - | `B019` | `4069` | Bluetooth, Unifying / Nano receiver | Back, Forward, Gesture button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Master 3 | - | `B023` | `4082` | Bluetooth, Unifying / Nano receiver | Back, Forward, Gesture button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Master 3 for Business | - | `B028` | `B028` | Bluetooth, Bolt receiver | Back, Forward, Gesture button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Master 3S | - | `B034` | `B034` | Bluetooth, Bolt receiver | Back, Forward, Gesture button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Master 4 | - | `B042` | - | Bluetooth | Back, Forward, Gesture button, Haptic Sense button, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Anywhere 2 | - | `B013`, `B018`, `B01F` | `404A`, `4072`, `4063` | Bluetooth, Unifying / Nano receiver | Back, Forward, Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| MX Anywhere 2S | - | `B01A` | `406A` | Bluetooth, Unifying / Nano receiver | Back, Forward, Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| MX Anywhere 3 | - | `B025` | `4090` | Bluetooth, Unifying / Nano receiver | Back, Forward, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Anywhere 3 for Business | - | `B02D` | `B02D` | Bluetooth, Bolt receiver | Back, Forward, SmartShift button, Wheel click | Published data (untested on hardware) |
| MX Ergo | - | `B01D` | `406F` | Bluetooth, Unifying / Nano receiver | Back, Forward, Precision button (DPI), Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| Lift | - | `B031` | `B031` | Bluetooth, Bolt receiver | Back, Forward, Top (DPI) button, Wheel click | Published data (untested on hardware) |
| Lift for Business | - | `B033` | `B033` | Bluetooth, Bolt receiver | Back, Forward, Top (DPI) button, Wheel click | Published data (untested on hardware) |
| M720 Triathlon | - | `B015` | `405E` | Bluetooth, Unifying / Nano receiver | Back, Forward, Gesture button (multi-platform), Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| M585 / M590 | - | `B01B` | `406B` | Bluetooth, Unifying / Nano receiver | Back, Forward, Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| Signature M650 L | - | `B02A` | `B02A` | Bluetooth, Bolt receiver | Back, Forward, Wheel click | Published data (untested on hardware) |
| Signature M550 | - | `B02B` | `B02B` | Bluetooth, Bolt receiver | Wheel click | Published data (untested on hardware) |
| ERGO M575 | - | `B027` | `4096` | Bluetooth, Unifying / Nano receiver | Back, Forward, Wheel click | Published data (untested on hardware) |
| Marathon M705 | - | - | `406D` | Unifying / Nano receiver | Back, Forward, Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| Pebble M350 | - | `B021` | `4080` | Bluetooth, Unifying / Nano receiver | Wheel click | Published data (untested on hardware) |
| M510 (v2) | - | - | `4051` | Unifying / Nano receiver | Back, Forward, Wheel click, Tilt left, Tilt right | Published data (untested on hardware) |
| M185 / M235 / M310 | - | - | `4055` | Unifying / Nano receiver | Wheel click | Published data (untested on hardware) |

An empty cell (`-`) means the catalog has no ID of that kind for the model, not that the mouse can't
do it. The MX Vertical row is the one entry that is **verified on hardware**, and its Bluetooth
path is best effort because it depends on macOS exposing the mouse's HID++ collection.

Notes on individual controls (all unverified on hardware outside the MX Vertical):

- The **Signature M550** and **Pebble M350** list only the wheel click as remappable. (The catalog
  notes that the M550's thumb buttons are plain mouse buttons, not programmable controls.)
- On the **M185 / M235 / M310** family the left and right buttons report as divertable, but Upright
  never diverts primary clicks (`ControlCatalog.neverDivert`).
- The **MX Ergo** uses the "Precision Button" wording for its DPI control (`0x00ED`).
- Pointer speed (DPI) is shown only for mice that offer `ADJUSTABLE_DPI` (`0x2201`). Mice that
  don't (the M720 Triathlon and MX Ergo dumps list a different speed feature) get no pointer-speed
  controls. This is derived from published dumps and not tested on hardware.

## Mice that aren't in the catalog

Upright doesn't need a catalog entry to try a mouse:

- **Receivers.** Any mouse paired to a supported receiver (below) is probed in every slot. If it
  reports itself as a pointer and offers `0x1B04`, it is served.
- **Cable and Bluetooth.** A Logitech USB product ID from `C07D` to `C094` or a Bluetooth ID from
  `B012` to `B0FF` is opened as a candidate mouse. Keyboard ID ranges (USB `C32B` to `C344`,
  Bluetooth `B317` to `B3FF`) are never opened.
- Mappings for a mouse that isn't in the catalog are kept per detected model, the same as for
  catalog models. All of this is **untested** on hardware.

If your mouse isn't listed, or is listed and misbehaves, run `make probe ARGS=--all` (read-only: it
doesn't divert any button) and use **Settings → Mice → Copy Device Report** while it is connected.
Attach both to an issue on GitHub. That is how a model moves from "Published data" to "Verified".

## Receivers

| Receiver | Product IDs | Opened? | Pairing layout | Status |
| --- | --- | --- | --- | --- |
| Unifying | `C52B`, `C532` | Yes | Unifying | Supported for the MX Vertical (verified on hardware); other mice behind one are untested |
| Bolt | `C548` | Yes | Bolt | Implemented from Solaar's documentation and **simulator-tested only**; untested on a real Bolt receiver |
| Nano | `C52F`, `C531`, `C534`, `C537`, `C518`, `C51A`, `C51B`, `C521`, `C525`, `C526`, `C52E`, `C535` | Yes | Unifying (Nano receivers use the same pairing registers) | Untested on hardware |
| Lightspeed | `C539`, `C53A`, `C53D`, `C53F`, `C541`, `C545`, `C547`, `C54D` | **Never** | none | Excluded, see below |
| 27 MHz (pre-Unifying) | `C517` | **Never** | none | Excluded: HID++ 1.0 devices only |

**Why Lightspeed receivers are excluded.** Every G-series and PRO mouse in the research data that
sits behind a Lightspeed receiver lacks the programmable-button feature (`0x1B04`): those mice keep
their buttons in onboard profiles. The `C53A` receiver also hosts a PowerPlay charging chip, and
Logitech G HUB owns these receivers. Upright therefore never opens them, which also means it can't
interfere with them. Re-enabling a receiver would need an entry in `DeviceCatalog.receivers` with a
pairing layout.

Any other Logitech receiver ID in the `C500` to `C5FF` range is left alone ("unrecognized Logitech
receiver"). Receivers are scanned in slots 1 to 6.

## Gaming mice that are known not to work

`DeviceCatalog.knownUnsupported` lists mice whose buttons live in onboard profiles instead of
programmable controls. They are documented for logs only; if one is opened it simply ends up
"No programmable buttons" and is never diverted:

G Pro Wireless, G304 / G305, G502 Lightspeed, G502 X Plus, G604, G703 Lightspeed, G903
Lightspeed, PRO X Wireless and PRO X 2.

## Devices Upright never configures

Keyboards, numpads, presenters, remote controls and receivers are never diverted, and devices that
answer only HID++ 1.0 are not served. They appear under **Other Logitech devices** with the reason
and keep working as usual.
