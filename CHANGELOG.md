# Changelog

All notable changes to Upright are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Per-app profiles.** A global mapping table plus per-app overrides, chosen by the frontmost
  app's bundle ID. A button without an override uses the global action; an override can also
  give a button back to the mouse in that app.
- **Gestures.** A button can be set to five actions: a click, and hold-and-move up, down, left
  or right. The mouse reports raw movement (HID++ `0x1B04` raw XY) while the button is held.
  Buttons that can't report it fall back to watching the cursor.
- **New actions:** Open App, Open URL, Run Shortcut (Shortcuts.app), pointer speed (cycle
  presets or set a DPI), and Easy-Switch to computer 1, 2 or 3.
- **Pointer speed control** (`0x2201`): slider, presets, and a speed that is re-applied on every
  reconnect, with a menu-bar quick control.
- **Device information:** firmware versions and serial number (`0x0003`), Easy-Switch channels
  and host names (`0x1814`, `0x1815`), shown in the Device pane and the probe output.
- **Battery:** approximate levels for mice that report only a coarse level, low-battery
  notifications at 15% and 5%, and an optional percentage next to the menu-bar icon.
- **Scrolling pane:** reverse mouse-wheel direction independently of the trackpad (wheel
  events only), a speed multiplier, an "only while the MX Vertical is connected" option and
  experimental smooth scrolling. All off by default.
- **Export and import** of mappings and profiles as JSON, with a schema version.
- **First-run onboarding** for new installs.
- **Reset Permission** button (Settings → Permissions and onboarding) that clears a stale
  Accessibility entry with `tccutil` and asks again, shown when a previous grant no longer works.
- **Open at Login** warns when Upright isn't in the Applications folder.
- `make verify` target, and `make probe` now prints battery, firmware, serial number, pointer
  speed, Easy-Switch channels and which controls support raw XY.
- `CONTRIBUTING.md`, issue and pull request templates, and this changelog.
- A Troubleshooting section in the README.

### Changed

- **Fresh installs divert no buttons.** Back, Forward and the Top button keep their native
  behavior. Users upgrading from 1.0 keep their previous mappings (including the old defaults
  if they never changed them).
- Mappings are saved in a versioned format and decoded entry by entry. Data that can't be read
  is backed up in preferences instead of being reset silently.
- Accessibility is only required for mappings that post keys, media keys or clicks, and for
  scroll changes. Mission Control, Open App/URL, Run Shortcut, pointer speed and Easy-Switch
  work without it.
- Input Monitoring is requested only when macOS actually refuses access to the mouse. Nothing
  is asked for at launch.
- Reconnection is more robust: signals are coalesced, an unresponsive mouse is retried with
  exponential backoff (1 s up to 30 s) without ever giving up while its HID interface is open,
  and requests the device answers with "busy" are retried.
- On Unifying receivers, the pairing list (register `0xB5`) is read before probing slots, so
  Upright knows which slot holds the MX Vertical without pinging every slot.
- CI builds on `macos-15` with Xcode 16.2, checks that a release tag matches
  `MARKETING_VERSION`, names the DMG after the version or commit, and can sign and notarize the
  DMG when the signing secrets are set.
- The app is built with the hardened runtime.
- Documentation no longer says the app uses system materials, and now states that the MX
  Vertical pairs over Unifying or Bluetooth only (not Bolt).

## [1.0.0]

Initial release.

- Menu-bar app that remaps the MX Vertical's Back, Forward, Top (DPI) and wheel-click buttons to
  system actions or any keyboard shortcut, over HID++ 2.0 (`REPROG_CONTROLS_V4`).
- Supports the USB cable, Unifying receivers and Bluetooth (best effort).
- Reapplies button diversion after the mouse sleeps or reconnects, after Mac wake, and when a
  receiver or cable is replugged.
- Out-of-the-box mappings: Back and Forward to browser navigation, Top button to Mission Control.
- Temporary diversion only: buttons return to the mouse when Upright quits.
- Settings window with Buttons, General, Permissions, Device and About panes; Open at Login via
  `SMAppService`.
- `upright-probe` command-line tool and a unit-test suite that runs against a simulated mouse.
