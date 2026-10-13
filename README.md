# Upright

**Open-source button remapping for the Logitech MX Vertical on macOS, without Logi Options+.**

Upright is a small native SwiftUI menu-bar app. It remaps the MX Vertical's thumb buttons, the
top (DPI) button, and the wheel click to keyboard shortcuts or system actions. It talks to the
mouse directly over the publicly documented **HID++ 2.0** protocol, the same approach used by
Solaar, LogiOps and libratbag. It doesn't use a kernel extension or a background daemon, and it
doesn't include any Logitech software.

- **Remap** Back, Forward, the Top (DPI) button and Wheel Click to built-in actions: Mission
  Control, App Exposé, Show Desktop, switching Spaces, Back/Forward, tabs, media keys, Spotlight,
  screenshots, Lock Screen, Copy/Paste/Undo/Redo, middle click and mouse buttons 4/5. You can
  also record any keyboard shortcut.
- **Connects** over the USB cable, a Unifying receiver, a Bolt receiver, or Bluetooth (best
  effort).
- **Stays configured** after the mouse sleeps or is switched off and on, after the Mac wakes
  from sleep, and when the receiver is unplugged and plugged back in.
- **Leaves nothing behind.** Buttons are only *temporarily* diverted. When Upright quits it hands
  them back to the mouse, and power-cycling the mouse always restores factory behavior. Nothing
  is written to the mouse's memory.
- **Feels native.** It has a menu-bar panel, a System Settings-style window, SF Symbols, system
  materials, and supports light and dark mode. Open at Login uses `SMAppService`.
- **Explains permissions.** It shows exactly what it needs (Accessibility) and why. Until access
  is granted, mapped buttons keep their normal behavior instead of silently doing nothing.

| Connection | Status |
| --- | --- |
| USB cable (`046D:C08A`) | Supported |
| Unifying receiver (`046D:C52B`, `C532`) | Supported. The mouse is found in any of the 6 slots. |
| Bolt receiver (`046D:C548`) | Supported (same receiver protocol) |
| Bluetooth (`046D:B020`) | Best effort. Depends on macOS exposing the HID++ collection. |

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel)
- Xcode 15 or later to build
- A Logitech MX Vertical

## Build and run

### Xcode

1. Open `Upright.xcodeproj`.
2. Select the **Upright** scheme and press **⌘R**.

The project is set to *Sign to Run Locally* (ad-hoc signing), so you don't need an Apple
Developer account or team. A mouse icon appears in the menu bar. On first launch the settings
window opens too.

### Command line

```bash
make test   # UprightKit unit tests (also runs on Linux)
make app    # Release build, ad-hoc signed, universal → build/Build/Products/Release/Upright.app
make dmg    # …and package it as dist/Upright.dmg
make open   # build and launch
```

`make app` wraps this command:

```bash
xcodebuild -project Upright.xcodeproj -scheme Upright -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

### Unsigned DMG from GitHub Actions

`.github/workflows/build.yml` runs the core tests on Linux and macOS, builds the app on a
`macos-14` runner, and uploads an **unsigned** `Upright.dmg` as a workflow artifact. Pushing a
tag such as `v1.0.0` also attaches the DMG to a GitHub release. No Apple signing or
notarization is involved.

Because the DMG isn't notarized, Gatekeeper blocks the first launch. Either right-click
`Upright.app` → **Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Upright.app
```

## Permissions

| Permission | Needed for | When |
| --- | --- | --- |
| **Accessibility** | Posting the keyboard shortcuts, media keys and clicks your buttons are mapped to | Whenever a mapping sends input. Mission Control actions and "Do Nothing" work without it. |
| **Input Monitoring** | Opening the receiver's HID++ interface | Only if macOS refuses access. The Permissions pane says so when it happens. |

- Upright never reads keystrokes. It only opens Logitech HID interfaces on the vendor usage
  pages `0xFF00` and `0xFF43` (the HID++ channel), and only posts the actions you assign.
- Until Accessibility is granted, buttons with keyboard or media actions are **not diverted**,
  so they keep working as normal mouse buttons. The menu-bar panel and the Buttons pane show an
  **Allow…** button that opens the right System Settings page. The UI updates by itself once
  you flip the switch.
- macOS ties these permissions to the app's code signature. A local ad-hoc build gets a new
  signature every time you rebuild, so macOS may list Upright twice or ask again. To start
  fresh:

  ```bash
  tccutil reset Accessibility io.github.upright.Upright
  tccutil reset ListenEvent io.github.upright.Upright
  ```

- The app is not sandboxed, because posting synthetic input and opening HID devices requires
  that. It has no network access and collects nothing.

## Testing with a real MX Vertical

The core of Upright is unit-tested against a simulated MX Vertical (see below). These steps
verify the real hardware path. If something fails, the logs from steps 1 and 6 make a great bug
report.

1. **Probe from the terminal (no app needed).**

   ```bash
   make probe                 # or: swift run --package-path UprightKit upright-probe
   make probe ARGS=--divert   # also divert every remappable button and print events
   ```

   You should see the receiver or cable interface, then `✓ MX Vertical over …`, followed by the
   HID++ feature table and the control list. Remappable controls are marked with `*`. With
   `--divert`, pressing a thumb button prints `● Back Button (0x0053) pressed/released` instead
   of navigating, and **Ctrl-C** gives the buttons back. If nothing is found, click a mouse
   button to wake it. If macOS blocks access, allow your terminal app under Privacy & Security
   → Input Monitoring.
2. **Launch the app** (`make open` or ⌘R in Xcode). The menu-bar panel should show
   *Connected via Unifying receiver* (or USB cable / Bluetooth) and the battery level.
3. **Grant Accessibility** when asked. The orange callout disappears.
4. **Defaults.** In Safari or Finder, the lower thumb button goes back and the upper one goes
   forward. The top button opens Mission Control.
5. **Remap.** Open **Settings… → Buttons**, set *Top Button* to **Keyboard Shortcut…** and
   press e.g. ⇧⌘5. Pressing the top button should now open the screenshot toolbar. Set a button
   to **Default** to give it back to the mouse. For the top button, that brings back DPI
   cycling.
6. **Sleep and reconnects.** Watch **Settings → Device → Activity** while you:
   - switch the mouse off and on (expect *Slot n link lost*, then *link restored* and
     *Reapplied configuration*),
   - put the Mac to sleep and wake it (expect *Mac woke up; reapplying button configuration*),
   - unplug and replug the receiver or cable.

   After each one, the thumb buttons should still be remapped. Turn on **Raw HID++ reports** to
   see every packet.
7. **Quit** Upright. The buttons should immediately behave like stock mouse buttons again.

### Automated tests

`UprightKit` contains every protocol and remapping decision and runs on any platform with
Swift 5.9+:

```bash
swift test --package-path UprightKit
```

The tests cover HID++ framing and response/error matching, control-table and event decoding,
mapping persistence, and the remap engine. They also drive `MXVerticalController` end to end
against `SimulatedMXVertical`, a software mouse that answers HID++ the way the real one does,
either directly or behind a receiver slot. Those scenarios include receiver slot discovery,
diversion, button events, sleeping and waking, a mouse that shows up later, the `0x1D4B`
reconnect event, Mac wake, transport removal mid-press, and restore on quit.

## Architecture

```
┌──────────────────────────── Upright.app (SwiftUI, AppKit) ─────────────────────────────┐
│ MenuBarView · SettingsView (Buttons / General / Permissions / Device / About)          │
│ AppModel ── mappings, on/off switch, persistence (UserDefaults)                        │
│ DeviceManager ── IOKit matching, sleep/wake observers, status and activity log         │
│ SystemActionPerformer ── CGEvent keys, media keys, clicks, Mission Control             │
│ PermissionsMonitor · LoginItemController (SMAppService)                                │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │ compiled into the app from
┌───────────────────────────── UprightKit (Swift package) ───────────────────────────────┐
│ Platform/  HIDDeviceMonitor, IOKitHIDTransport (IOHIDManager, macOS only)              │
│ Device/    MXVerticalController ── discovery, receiver notifications, reconnect logic  │
│            DeviceSession ── features, controls, diversion, event decoding              │
│            ButtonStateTracker, MXVertical (IDs), KnownControl (CIDs)                   │
│ HIDPP/     HIDPPMessage, HIDPPClient (request/response matching), HIDPPDevice (root,   │
│            feature set, name, battery), ReprogControls (0x1B04)                        │
│ Mapping/   ButtonAction, SystemAction, KeyCombo, ButtonMappings, RemapEngine           │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

**How a button press gets remapped:**

1. `HIDDeviceMonitor` matches Logitech interfaces on usage page `0xFF00` or `0xFF43`.
   `MXVertical.classify` tells receivers (`C52B`/`C532`/`C548`) from a directly connected mouse
   (`C08A`/`B020`).
2. `MXVerticalController` finds the mouse. For a receiver, it enables wireless notifications
   (HID++ 1.0 register `0x00`), pings slots 1 to 6 with `Root.getProtocolVersion`, and reads
   each answering device's name. A direct connection uses device index `0xFF`.
3. `DeviceSession` resolves feature indices, reads the `REPROG_CONTROLS_V4` control table, and
   calls `setCidReporting(cid, divert)` for every button that has a mapping. Remappable means
   divertable, not virtual, and not left or right click.
4. The mouse now sends `divertedButtonsEvent` reports (the list of CIDs currently held) instead
   of acting on those buttons. `ButtonStateTracker` turns them into press and release events.
5. `RemapEngine` looks up the action and asks `SystemActionPerformer` to post it. Keys and
   clicks follow the physical button (down on press, up on release). One-shot actions fire on
   press.

**Staying configured.** Temporary diversion is lost when the mouse power-cycles, so the
controller reapplies it when:

- the receiver reports a link-established notification (`0x41`) for the mouse's slot,
- the mouse sends a `WIRELESS_DEVICE_STATUS` (`0x1D4B`) reconnection event,
- macOS posts a wake, screens-wake or session-active notification,
- IOKit re-matches a replugged receiver or cable.

All controller work runs on the main actor through a serial operation queue, so probes and
reconfigurations never interleave.

**Why the app compiles UprightKit's sources directly.** The Xcode project references the files
in `UprightKit/Sources/UprightKit` instead of linking the package. That keeps the project
buildable on any Xcode 15+ without package resolution. Meanwhile `swift test` exercises exactly
the same code, on Linux too.

See [`docs/HIDPP.md`](docs/HIDPP.md) for the exact messages Upright sends.

## Scope and limitations

- Upright targets the **MX Vertical** only. Receivers are scanned, but other devices on them are
  ignored.
- No pairing, no firmware, and no DPI value editing. Setting the top button to **Default**
  keeps its built-in DPI cycling.
- No kernel extension, no driver, no App Store build.
- Bluetooth depends on macOS exposing the mouse's vendor HID collection. If the probe can't
  reach the mouse over Bluetooth, use the receiver or cable.
- The scroll wheel, pointer speed and gestures are out of scope for v1.

## Attribution

Upright was written from public information only. No Logitech software, driver or binary was
disassembled, decompiled or otherwise reverse-engineered, and none is included.

- **Logitech's HID++ 2.0 documentation drafts** (published by Logitech and mirrored by the
  projects below) for the report format, the root and feature-set features, and
  `REPROG_CONTROLS_V4`.
- **[Solaar](https://github.com/pwr-Solaar/Solaar)** (GPL-2.0) for its descriptions of receiver
  registers and notifications, the device product IDs, and the CID names in its special-keys
  table.
- **[LogiOps](https://github.com/PixlOne/logiops)** (GPL-3.0) for its documentation of
  diverting MX Vertical buttons (including the top button's CID `0xFD`) through
  `REPROG_CONTROLS_V4`.
- **[libratbag](https://github.com/libratbag/libratbag)** (MIT) for its HID++ 1.0/2.0
  documentation and device data.
- **[Linux `hid-logitech-hidpp`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c)**
  and `hid-logitech-dj` (GPL-2.0) for report IDs and receiver behavior.
- **logitech-mx-vertical-mapper** and similar open projects for showing the approach works on
  macOS.

No code was copied from the GPL projects. They were used as protocol references only.

## License

[MIT](LICENSE). Logitech, MX Vertical, Unifying, Bolt and Logi Options+ are trademarks of
Logitech. Upright is an independent project and is not affiliated with or endorsed by Logitech.
