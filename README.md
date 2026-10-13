# Upright

**Open-source button remapping for the Logitech MX Vertical on macOS, without Logi Options+.**

Upright is a small native SwiftUI menu-bar app. It remaps the MX Vertical's thumb buttons, the
top (DPI) button and the wheel click, and adds pointer-speed, scrolling and battery features. It
talks to the mouse directly over the publicly documented **HID++ 2.0** protocol, the same
approach used by Solaar, LogiOps and libratbag. It doesn't use a kernel extension or a
background daemon, and it doesn't include any Logitech software.

## Features

- **Remap buttons.** Back, Forward, the Top (DPI) button, the Wheel Click and any other
  divertable button the mouse reports. Actions:
  - built-in system actions: Mission Control, App Exposé, Show Desktop, switching Spaces,
    Back/Forward, tabs, media keys, Spotlight, screenshots, Lock Screen,
    Copy/Paste/Undo/Redo, middle click and mouse buttons 4/5
  - any recorded keyboard shortcut
  - **Open App**, **Open URL** and **Run Shortcut** (a Shortcuts.app shortcut, by name)
  - **Pointer speed**: cycle through your presets, or jump to a fixed DPI
  - **Easy-Switch**: move the mouse to computer 1, 2 or 3
  - **Do Nothing**, or **Default** to leave the button to the mouse
- **Gestures.** Set a button to *Gestures* to get five actions: a click, plus hold and move up,
  down, left or right. The mouse reports raw movement while the button is held, so the cursor
  doesn't move. If a button can't report raw movement, Upright falls back to watching the
  cursor, which does move during the gesture (the Buttons pane says so).
- **Per-app profiles.** Keep a global table and add apps (by bundle ID) that override single
  buttons while they are frontmost. A button without an override uses the global action, and
  an override can also hand a button back to the mouse in that app.
- **Pointer speed (DPI).** Set the speed with a slider, keep a list of presets, and pick a
  speed to apply whenever the mouse reconnects. Speeds snap to what the mouse supports.
- **Device info.** Firmware, serial number, battery, connection type, the Easy-Switch channel
  (with host names when the mouse stores them), the HID++ feature table and the control list.
- **Battery.** Reads the level when the mouse connects and about every 10 minutes. Mice that
  report only a coarse level (critical, low, good, full) show an approximate value such as
  "~50%". Low-battery notifications at 15% and 5% (on by default; macOS asks for notification
  permission the first time), and an optional percentage next to the menu-bar icon.
- **Scrolling.** Reverse the mouse wheel independently of the trackpad, change the speed
  (0.5x to 3x), and try the experimental smooth scrolling. All off by default. See
  [Scrolling](#scrolling) for what is and isn't affected.
- **Export and import** of all mappings and profiles as a JSON file.
- **First-run onboarding** for new installs: connect, allow Accessibility, choose a setup.
- **Robust reconnection.** Button diversion is reapplied after the mouse sleeps or is switched
  off and on, after the Mac wakes, and when a receiver or cable is replugged. A mouse that
  doesn't answer is retried with backoff and never given up on while its HID interface is open.
- **Leaves nothing behind.** Buttons are only *temporarily* diverted. When Upright quits it
  hands them back, and power-cycling the mouse always restores factory behavior. Nothing is
  written to the mouse's memory.
- **Feels native.** A menu-bar panel, a System Settings-style window, SF Symbols, light and
  dark mode. Open at Login uses `SMAppService`.
- **Explains permissions.** It shows what it needs and why. Until Accessibility is granted,
  mappings that need it are not applied and the buttons keep their normal behavior.

### Defaults

A fresh install **remaps nothing**: Back, Forward and the Top button keep their native
behavior (mouse buttons 4 and 5, and DPI cycling). Pick actions in **Settings → Buttons**.

If you used an earlier version, your saved mappings are migrated and kept. Anything Upright
can't read is backed up in its preferences instead of being thrown away.

## Connections

| Connection | Status |
| --- | --- |
| USB cable (`046D:C08A`) | Supported |
| Unifying receiver (`046D:C52B`, `C532`) | Supported. The mouse is found in any of the 6 slots. |
| Bluetooth (`046D:B020`) | Best effort. Depends on macOS exposing the HID++ collection, and may need Input Monitoring. |
| Bolt receiver (`046D:C548`) | **Not applicable.** The MX Vertical can't pair with a Bolt receiver (Unifying and Bluetooth only). Upright still watches Bolt receivers in case a future model needs them. |

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel)
- Xcode 15 or later to build (CI builds with Xcode 16.2)
- A Logitech MX Vertical

## Build and run

### Xcode

1. Open `Upright.xcodeproj`.
2. Select the **Upright** scheme and press **⌘R**.

The project is set to *Sign to Run Locally* (ad-hoc signing), so you don't need an Apple
Developer account or team. A mouse icon appears in the menu bar. On first launch the welcome
window opens.

### Command line

```bash
make test     # UprightKit unit tests (also run on Linux)
make app      # Release build, universal, ad-hoc signed with the hardened runtime
              #   → build/Build/Products/Release/Upright.app
make verify   # codesign --verify on the built app, and print its flags
make dmg      # …and package it as dist/Upright.dmg
make open     # build and launch
make probe    # talk to a connected MX Vertical from the terminal (see below)
make clean    # remove build/, dist/ and UprightKit/.build
```

`make app` wraps this command:

```bash
xcodebuild -project Upright.xcodeproj -scheme Upright -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--options=runtime" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

The app uses the **hardened runtime** and is not sandboxed (see [Permissions](#permissions)).

### GitHub Actions

`.github/workflows/build.yml` has three jobs:

- **core-tests** runs the UprightKit tests on Ubuntu 24.04 with Swift 6.0.
- **app** runs on `macos-15` with Xcode 16.2. It runs the tests again on macOS (which also
  covers the IOKit layer), builds the app with `make app`, checks the signature with
  `make verify` and packages `Upright-<version>.dmg` (or `Upright-<commit>.dmg` outside a
  release). The DMG is uploaded as a workflow artifact.
- **release** runs only for tags that start with `v`. It attaches the DMG to a GitHub release
  with generated notes.

For a tag such as `v1.1.0`, the **app** job fails unless the tag matches `MARKETING_VERSION` in
`project.pbxproj`.

By default the DMG is **unsigned** (ad-hoc). If the repository defines the secrets
`MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASSWORD`, the job also signs the app and DMG
with a Developer ID certificate. If `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` are
set as well, it notarizes and staples the DMG. Without those secrets, none of this runs.

An ad-hoc DMG isn't notarized, so Gatekeeper blocks the first launch. Either right-click
`Upright.app` → **Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Upright.app
```

## Permissions

| Permission | Needed for | When |
| --- | --- | --- |
| **Accessibility** | Posting the keyboard shortcuts, media keys and clicks your buttons are mapped to, and changing scrolling (it needs an event tap) | Whenever a mapping sends input or a scroll setting is on. Mission Control actions, Open App/URL, Run Shortcut, pointer speed, Easy-Switch and "Do Nothing" work without it. |
| **Input Monitoring** | Opening the mouse's HID++ interface | Only if macOS hides the mouse from Upright, which can happen over Bluetooth. Upright doesn't ask for it at launch. The Permissions pane and the menu-bar panel say so when it happens. |

- Upright never reads keystrokes. It only opens Logitech HID interfaces (the vendor usage pages
  `0xFF00` and `0xFF43`, plus the MX Vertical's own mouse interface over Bluetooth and USB), and
  only posts the actions you assign.
- Until Accessibility is granted, buttons with keyboard, media or click actions are **not
  diverted**, so they keep working as normal mouse buttons. The menu-bar panel and the Buttons
  pane show an **Allow…** button that opens the right System Settings page. The UI updates by
  itself once you flip the switch.
- **Rebuilds and updates.** macOS ties the Accessibility grant to the app's code signature. An
  ad-hoc build gets a new signature every time you rebuild, and an updated or moved copy can
  look the same. System Settings may then show Upright switched on, while macOS refuses the
  new copy. Upright detects this (it was trusted before and isn't now) and offers a
  **Reset Permission** button in Settings → Permissions and in the welcome window. It removes
  the old entry with `tccutil` and asks again. To do it by hand:

  ```bash
  tccutil reset Accessibility io.github.upright.Upright
  tccutil reset ListenEvent io.github.upright.Upright
  ```

- The app is not sandboxed, because posting synthetic input and opening HID devices requires
  that. It doesn't phone home or collect anything. **Run Shortcut** starts
  `/usr/bin/shortcuts`, and **Open App/URL** go through macOS.

## Scrolling

**Settings → Scrolling** applies to mouse wheels only. Trackpads and Magic Mouse send
continuous scroll events, and Upright never touches those.

- **Reverse** vertical and horizontal scrolling separately from the trackpad's Natural Scrolling.
- **Speed** multiplies the distance of each wheel step (0.5x to 3x).
- **Smooth scrolling** (experimental) turns each wheel step into a short eased glide.
- **Only while the MX Vertical is connected** (on by default). macOS doesn't tell an event tap
  which mouse a scroll came from. With this on, Upright rewrites wheel events only while an MX
  Vertical is connected, but it can't tell that mouse from another one. So while the MX
  Vertical is connected, **any other mouse wheel is changed too**. With the option off, every
  mouse wheel is always changed.

This needs Accessibility. Without it, scrolling works as usual and the pane says why.

## Testing with a real MX Vertical

The core of Upright is unit-tested against a simulated MX Vertical (see below). These steps
verify the real hardware path. If something fails, the output from step 1 and the log from
step 6 make a great bug report.

1. **Probe from the terminal (no app needed).**

   ```bash
   make probe                 # or: swift run --package-path UprightKit upright-probe
   make probe ARGS=--divert   # also divert every remappable button and print events
   ```

   You should see the receiver or cable interface, then `✓ MX Vertical over …`, followed by the
   battery, firmware, serial number, pointer speed, Easy-Switch channels, the HID++ feature
   table and the control list. Remappable controls are marked with `*`, and controls that can
   report raw movement (needed for hold-and-move gestures) carry a `raw XY` flag. With
   `--divert`, pressing a thumb button prints `● Back Button (0x0053) pressed/released`
   instead of navigating, and **Ctrl-C** gives the buttons back. If nothing is found, click a
   mouse button to wake it. If macOS blocks access, allow your terminal app under Privacy &
   Security → Input Monitoring.
2. **Launch the app** (`make open` or ⌘R in Xcode). The menu-bar panel should show
   *Connected via Unifying receiver* (or USB cable / Bluetooth) and the battery level.
3. **Grant Accessibility** when asked. The orange callout disappears.
4. **Defaults.** On a fresh install, nothing is remapped. In Safari or Finder the thumb buttons
   still go back and forward as mouse buttons 4 and 5, and the top button still cycles DPI.
5. **Remap.** Open **Settings → Buttons**, set *Top Button* to **Keyboard Shortcut…** and
   press e.g. ⇧⌘5. Pressing the top button should now open the screenshot toolbar. Set a button
   to **Default** to give it back to the mouse. For the top button, that brings back DPI
   cycling.
6. **Sleep and reconnects.** Watch **Settings → Device → Activity** while you:
   - switch the mouse off and on (expect *Slot n link lost*, then *link restored* and
     *Reapplied configuration*),
   - put the Mac to sleep and wake it (expect *Mac woke up; reapplying button configuration*),
   - unplug and replug the receiver or cable.

   After each one, remapped buttons should still work. Turn on **Raw HID++ reports** to see
   every packet.
7. **Quit** Upright. The buttons should immediately behave like stock mouse buttons again.

Something not working? See [Troubleshooting](#troubleshooting).

### Automated tests

`UprightKit` contains every protocol, mapping, scrolling and battery decision and runs on any
platform with Swift 5.9+:

```bash
swift test --package-path UprightKit
```

The tests cover HID++ framing and response/error matching, control-table and event decoding,
mapping persistence and migration, profiles, gestures, scroll transforms and battery alerts.
They also drive `MXVerticalController` end to end against `SimulatedMXVertical`, a software
mouse that answers HID++ the way the real one does, either directly or behind a receiver slot.
Those scenarios include receiver slot discovery, diversion, button events, sleeping and
waking, a mouse that shows up later, the `0x1D4B` reconnect event, Mac wake, transport removal
mid-press, retry with backoff and restore on quit.

## Troubleshooting

**Upright says "Not connected" or can't find the mouse.**
Plug in the Unifying receiver or the USB cable, or pair over Bluetooth, then click a mouse
button to wake the mouse. Open Settings → Device → Activity to see what Upright found. Use
**Reconnect** on the Device pane to make it look again. Remember that the MX Vertical can't
use a Bolt receiver. Run `make probe` (see above): if the probe can't find the mouse either,
the problem is below Upright.

**Bluetooth: the mouse is paired but Upright never sees HID++.**
macOS has to expose the mouse's HID++ collection to apps, and it sometimes doesn't. Check
Privacy & Security → Input Monitoring: if the Permissions pane shows Input Monitoring as
needed, allow Upright there and choose Reconnect. If the probe also fails over Bluetooth, use
the Unifying receiver or the USB cable instead.

**Accessibility looks switched on, but buttons don't remap.**
This is usually a stale grant after a rebuild, an update or moving the app. Open
Settings → Permissions and click **Reset Permission**, then allow Upright again. If the button
isn't there, run the `tccutil reset Accessibility io.github.upright.Upright` command above,
then relaunch Upright and allow it again. Also check that **Remap buttons** is on, and that
the frontmost app doesn't have a profile that overrides the button.

**A Mission Control, App Exposé or Show Desktop action does nothing.**
Upright starts these through macOS (`open -a "Mission Control"`). Try that command in Terminal.
If it works there, check Upright's Activity log. If not, assign a keyboard shortcut instead:
turn on the shortcut in System Settings → Keyboard → Keyboard Shortcuts → Mission Control and
record the same shortcut in Upright.

**Open at Login doesn't stick, or Upright isn't there after logging in.**
Upright must live in `/Applications` first. A copy run from `build/`, Downloads or a mounted
DMG breaks when it moves or is deleted. Move it to Applications, quit, launch it from there,
then turn Open at login on again. If macOS asks for approval, use **Open Login Items…** in the
General pane.

**Scrolling settings have no effect.**
Scrolling needs Accessibility. The Scrolling pane says "Accessibility access needed" when it is
missing, and "Paused until the MX Vertical connects" when **Only while the MX Vertical is
connected** is on and the mouse isn't connected. Trackpad and Magic Mouse scrolling is never
changed. If smooth scrolling feels wrong, turn it off; it is experimental.

**Gestures move the cursor.**
Your mouse didn't offer raw movement for that button (the probe doesn't mark it `raw XY`), so
Upright watches the cursor instead. Gestures still work, but the pointer moves while the
button is held. The Buttons pane shows a note when this applies.

**Another app is fighting over the buttons.**
Logi Options+, Logitech Options, Solaar and LogiOps also divert buttons. Only one can win.
Quit them (and remove them from your login items) while using Upright.

**Collect diagnostics.** Run `make probe` and copy its output. Then open Settings → Device →
Activity, turn on **Raw HID++ reports** if asked, reproduce the problem, and use **Copy**. Include
both in a bug report (see `.github/ISSUE_TEMPLATE`).

## Architecture

```
┌──────────────────────────── Upright.app (SwiftUI, AppKit) ─────────────────────────────┐
│ MenuBarView · OnboardingView                                                           │
│ SettingsView (Buttons / Scrolling / Device / General / Permissions / About)            │
│ AppModel ── mappings + per-app profiles (MappingStore), remap switch, routing          │
│ AppSettings ── scroll, battery and pointer-speed preferences                           │
│ DeviceManager ── IOKit matching, sleep/wake observers, status and activity log         │
│ SystemActionPerformer ── CGEvent keys, media keys, clicks, apps, URLs, Shortcuts       │
│ FrontmostAppMonitor · ScrollController (event tap) · BatteryNotifier                   │
│ PermissionsMonitor · LoginItemController (SMAppService)                                │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │ compiled into the app from
┌───────────────────────────── UprightKit (Swift package) ───────────────────────────────┐
│ Platform/  HIDDeviceMonitor, IOKitHIDTransport (IOHIDManager, macOS only)              │
│ Device/    MXVerticalController ── discovery, receiver notifications, reconnect logic  │
│            DeviceSession ── features, controls, diversion, events, device info         │
│            ButtonStateTracker, MXVertical (IDs), KnownControl (CIDs)                   │
│ HIDPP/     HIDPPMessage, HIDPPClient (request/response matching, busy retry),          │
│            HIDPPDevice (root, feature set, name, battery), ReprogControls (0x1B04),    │
│            DeviceFeatures (firmware, DPI, Easy-Switch)                                 │
│ Mapping/   ButtonAction, SystemAction, KeyCombo, ButtonMappings, MappingProfiles,      │
│            MappingStore, GestureSet, GestureRecognizer, RemapEngine                    │
│ Scrolling/ ScrollSettings, ScrollTransform, SmoothScrollAnimator                       │
│ Battery/   BatteryAlertPolicy                                                          │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

**How a button press gets remapped:**

1. `HIDDeviceMonitor` matches Logitech interfaces on usage page `0xFF00` or `0xFF43`, plus the
   MX Vertical's mouse interface (needed over Bluetooth). `MXVertical.classify` tells receivers
   (`C52B`/`C532`/`C548`) from a directly connected mouse (`C08A`/`B020`).
2. `MXVerticalController` finds the mouse. For a receiver, it enables wireless notifications
   (HID++ 1.0 register `0x00`), reads the pairing list (register `0xB5`) when it can, pings
   slots with `Root.getProtocolVersion`, and reads each answering device's name. A direct
   connection uses device index `0xFF`.
3. `DeviceSession` resolves feature indices, reads the `REPROG_CONTROLS_V4` control table, and
   calls `setCidReporting(cid, divert)` for every button the **frontmost app's effective
   mappings** need. `AppModel` re-evaluates this when the frontmost app, the mappings or the
   Accessibility state change.
4. The mouse now sends `divertedButtonsEvent` reports (the list of CIDs currently held) instead
   of acting on those buttons. `ButtonStateTracker` turns them into press and release events.
5. `RemapEngine` looks up the action and asks `SystemActionPerformer` to post it, or hands a
   pointer-speed or Easy-Switch action back to `DeviceManager`. Keys and clicks follow the
   physical button (down on press, up on release). One-shot actions fire on press. A button
   mapped to gestures also reports raw movement, which `GestureRecognizer` turns into a
   direction (or a tap, if the button is released first).

**Staying configured.** Temporary diversion is lost when the mouse power-cycles, so the
controller reapplies it (and the kept pointer speed) when:

- the receiver reports a link-established notification (`0x41`) for the mouse's slot,
- the mouse sends a `WIRELESS_DEVICE_STATUS` (`0x1D4B`) reconnection event,
- macOS posts a wake, screens-wake or session-active notification,
- IOKit re-matches a replugged receiver or cable,
- a mouse that was asleep starts sending reports again.

Signals that arrive close together are coalesced into one pass. If the mouse stops answering,
the controller keeps the session, shows *Asleep* and retries with exponential backoff (1 s,
doubling to 30 s). All controller work runs on the main actor through a serial operation
queue, so probes and reconfigurations never interleave.

**Why the app compiles UprightKit's sources directly.** The Xcode project references the files
in `UprightKit/Sources/UprightKit` instead of linking the package. That keeps the project
buildable on any Xcode 15+ without package resolution. Meanwhile `swift test` exercises exactly
the same code, on Linux too. New Kit files must therefore be added to `project.pbxproj`; see
[CONTRIBUTING.md](CONTRIBUTING.md).

See [`docs/HIDPP.md`](docs/HIDPP.md) for the exact messages Upright sends.

## Scope and limitations

- Upright targets the **MX Vertical** only. Receivers are scanned, but other devices on them are
  ignored.
- No pairing, no firmware updates. Pointer speed is the only mouse setting Upright changes
  besides button diversion. Many mice forget a speed set this way when they reconnect, so
  Upright re-applies the speed it keeps each time the mouse connects. Setting the top button to **Default** keeps its built-in
  DPI cycling.
- Scroll features act on macOS scroll events. Upright doesn't change the wheel's own hardware
  settings (SmartShift, ratchet or hi-res mode).
- No kernel extension, no driver, no App Store build.
- Bluetooth depends on macOS exposing the mouse's vendor HID collection. If the probe can't
  reach the mouse over Bluetooth, use the receiver or cable.
- Wheel scrolling changes can't tell mice apart; see [Scrolling](#scrolling).

## Attribution

Upright was written from public information only. No Logitech software, driver or binary was
disassembled, decompiled or otherwise reverse-engineered, and none is included.

- **Logitech's HID++ 2.0 documentation drafts** (published by Logitech and mirrored by the
  projects below) for the report format, the root and feature-set features, and
  `REPROG_CONTROLS_V4`.
- **[Solaar](https://github.com/pwr-Solaar/Solaar)** (GPL-2.0) for its descriptions of receiver
  registers and notifications, the device product IDs, the firmware and DPI feature layouts, and
  the CID names in its special-keys table.
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [changelog](CHANGELOG.md).

## License

[MIT](LICENSE). Logitech, MX Vertical, Unifying, Bolt and Logi Options+ are trademarks of
Logitech. Upright is an independent project and is not affiliated with or endorsed by Logitech.
