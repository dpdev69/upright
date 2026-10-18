# Changelog

All notable changes to Upright are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- A [Logi Options+ alternatives for Mac](https://upright.hellobasalt.dev/logi-options-alternatives)
  page on the website, comparing Upright with BetterMouse, Mac Mouse Fix, SteerMouse and
  LinearMouse, linked from the home page and listed in the sitemap.
- A `robots.txt` for the website that allows all crawlers and points to the sitemap.
- The privacy and terms pages now also give hello@hellobasalt.dev for questions about Basalt.
- A "Page not found" page for the website, so unknown addresses answer with a real 404.

### Changed

- The website is now served by Cloudflare Pages from `site/` on main. The GitHub Pages
  workflow and `site/CNAME` are gone.
- Website links, canonical URLs and the sitemap now use addresses without `.html`
  (for example /privacy). The old `.html` addresses keep working.
- The website moved to [upright.hellobasalt.dev](https://upright.hellobasalt.dev/). The old
  dpdev69.github.io/upright address redirects there.
- The website footer now follows the shared Basalt layout, with a More from Basalt column
  linking the other Basalt apps and a support address.
- The More from Basalt column now also links ByeWall and KahveDrop.

## [1.1.2] - 2026-10-17

### Fixed

- **A receiver mouse could stay disconnected after the Mac slept or after an Easy-Switch
  away and back.** When its link dropped, Upright waited only for the receiver's link-up
  notification; if that notification was missed, nothing ever looked for the mouse again. A
  dropped link is now retried with the usual backoff (up to 30 s), so the mouse is found even
  without the notification.
- If re-enabling a receiver's link notifications fails (for example right after the Mac
  wakes), absent mice go back to being probed every 30 s instead of every 5 minutes.
- **A Bluetooth mouse could stay disconnected after the Mac slept or the mouse reconnected,**
  for three reasons seen in an MX Vertical's activity log:
  - macOS publishes a reconnected Bluetooth mouse a moment before it can be opened
    (`kIOReturnNotReady`), and Upright never tried again. A refused open is now retried
    (after 0.5, 1, 2 and 4 s, then every 8 s, for about 40 s).
  - After a sleep, macOS can keep the old handle and refuse every report sent on it
    (`kIOReturnBadArgument`). Upright kept retrying on that handle. A Bluetooth or USB mouse
    whose reports are refused now shows as failed, which makes Upright open it again.
  - **Reconnect All** reused the stopped IOKit manager, which doesn't report devices it
    already had, so it found nothing for a mouse that was still connected. It now starts a
    new one, and the automatic recovery that restarts the search benefits too.
- Simulator-tested only; not yet verified on hardware.

## [1.1.1] - 2026-10-14

### Changed

- **Less idle work.** The permissions check asks macOS once a minute when nothing is missing
  (was every 5 s for the whole session, every second with a window open); it still polls every
  second while a grant is awaited and a window is open or Upright just asked for it, and
  rechecks when a window opens or closes, when Upright becomes active and when the Mac wakes.
- **Absent receiver mice are probed every 5 minutes instead of every 30 s** once the receiver
  sends link notifications; the receiver's link-up notification or the mouse's first report
  reconnects it right away. Receivers without notifications keep the 30 s cap.
  Hardware-unverified; see the smoke checklist, section 5.
- **Faster button presses.** Mission Control, App Exposé and Show Desktop are started through
  LaunchServices directly rather than by spawning `open`; the drag event tap used while a mouse
  button mapping is held runs on its own thread, is created once and only switched on while a
  button is held.
- **Less UI churn.** Button presses, device log lines and app switches no longer rebuild the menu
  bar item or every open pane; the Activity log and press feedback are observed only by the views
  that show them.
- HID++ request timeouts are cancelled once the reply arrives; a few settings skip no-op writes.
- Raw HID++ report logging turns off when the Settings window closes.
- Release builds strip dead code.

## [1.1.0] - 2026-10-14

### Added

- **Multi-mouse support.** Upright now works with Logitech HID++ 2.0 mice other than the MX
  Vertical, and with several mice at once, over any mix of USB cable, Bluetooth and Unifying,
  Bolt or Nano receivers, including several mice on one receiver. A mouse is served when it
  answers HID++ 2.0 as a pointer and offers programmable buttons (`REPROG_CONTROLS_V4`), not
  because of its name or product ID. Keyboards and other non-mice are never opened.
  **Only the MX Vertical is verified on hardware.** Every other model, Bolt and Nano receivers,
  and two real mice at once are verified in the simulator only.
- **Device catalog** with 23 models (MX Vertical, the MX Master, MX Anywhere, MX Ergo, Lift,
  M720, M585/M590, Signature M650 L and M550, ERGO M575, Marathon M705, Pebble M350, M510 (v2)
  and M185/M235/M310 families), built from published Solaar and libratbag data and marked
  **published data, untested on hardware**. See [docs/DEVICES.md](docs/DEVICES.md), which is
  derived from `DeviceCatalog.swift`.
- **Receivers:** Bolt (`C548`, Bolt pairing layout) and Nano receivers join Unifying. Lightspeed
  receivers (G and PRO mice, which have no programmable-button feature) and the 27 MHz receiver
  are never opened.
- **Mice pane** (replaces Device): connected mice, mice seen before ("Not Connected") and a
  collapsed "Other Logitech devices" list with the reason a device isn't configured. Per mouse: a
  nickname, **Remap this mouse**, its pointer speed, Easy-Switch, battery, device info and
  **Copy Device Report** for issues.
- **Per-model mappings.** A **Configure** picker in Settings → Buttons chooses the model being
  edited, including models that aren't connected. Each model has its own buttons and per-app
  profiles; two mice of one model share them. "Copy setup from…" and "Use this setup for all my
  mice" are available.
- **Menu-bar panel with several mice:** one row per mouse with its connection and battery,
  "Reconnect All Mice", and button, pointer-speed and Easy-Switch sections for the mouse last
  used. The battery percentage next to the icon shows the lowest battery, and low-battery
  notifications name the mouse.
- **A mouse seen over two links** (for example receiver and cable) is recognized by its unit ID
  and used once, the other link kept on standby.
- **Demo Mode:** `Upright --demo` runs the real interface against simulated mice (an MX
  Vertical, an MX Master 3S and a Lift) with its own preferences, no event taps and no
  permission prompts. `Upright --demo --export-snapshots <dir>` (and `make snapshots`) renders
  the interface offscreen into light and dark PNGs plus a `manifest.json`; the screenshots in
  `media/snapshots/` and the README come from it.
- **`upright-probe`:** `--all` also reads interfaces Upright doesn't use (read-only), output lines
  carry a per-mouse label such as `[MX Master 3S · Bolt slot 2]`, and `--divert` can be limited to
  mice whose label contains some text.
- The mouse simulator (`SimulatedReceiver`, `SimulatedDirect`, `DeviceProfiles`) now lives in
  UprightKit, so Demo Mode and the tests share it.

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
  events only), a speed multiplier, an "only while a Logitech mouse is connected" option and
  experimental smooth scrolling. All off by default. They apply to every mouse wheel.
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

- **Mappings are saved per model** in a new format (schema v3), and a mouse model without a
  saved setup keeps every button native. See "Migration and downgrade notes" below.
- Upright is described as remapping Logitech mice over HID++, built and tested on the MX
  Vertical. Documentation, the About pane and the permission texts no longer say it only
  supports the MX Vertical.
- **Settings → Device is now Settings → Mice.**
- **Scrolling:** the option is now "Only while a Logitech mouse is connected" (any supported
  mouse, not just the MX Vertical). The saved setting keeps its name, so nothing is reset. Scroll
  settings remain global to every mouse wheel, because macOS doesn't say which mouse a scroll
  came from.
- Bluetooth matching now includes the mouse interface of any Logitech mouse, which is where
  Bluetooth mice carry HID++. Interfaces Upright can't use are never opened.
- Pointer-speed controls and actions are shown only for mice that offer `ADJUSTABLE_DPI`
  (`0x2201`); Upright uses no other speed feature.
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

### Migration and downgrade notes

- **From 1.x, or from a build that saved the single-setup format (schema v2).** On first launch the
  saved setup moves into the **MX Vertical's** setup in the new schema v3 library
  (`mappingProfiles.v3`), because only an MX Vertical could have produced it. Other models start
  with every button native. Upgrading without saved data keeps the old defaults on the MX
  Vertical, and a fresh install remaps nothing.
- **Nothing is deleted.** The v2 data (`mappingProfiles.v2`) is copied once, unchanged, to
  `mappingProfiles.v2.preV3Backup`, and the v2 key itself is never written or removed again.
  The 1.x key is not touched either. Data that can't be read is backed up under
  `mappingProfiles.corruptBackup.*` instead of being reset.
- **Pointer speed.** The single saved pointer speed is copied once to the MX Vertical's
  per-mouse preferences, and the old key is left in place.
- **Going back to an older build.** An older build reads the frozen v2 data, which is your MX
  Vertical setup **as it was when you upgraded**. It does not see anything you changed in the new
  version, and nothing you change in the older build reaches the new one: once a v3 library
  exists, it always wins. Setups for other models are only in the v3 library and are ignored by
  older builds.
- **Export and import.** Exported files now hold every model's setup. They also carry the MX
  Vertical's setup as top-level `global` and `apps` so an older build can still import them.
  Importing a file from an older build asks which model it should go to, shows what it will
  replace, and backs up your current setup first so the import can be undone. Importing a v3 file
  replaces only the models the file contains.
- **Per-mouse data** (nickname, remap switch, pointer speed, last seen) stays on this Mac and is
  never exported.

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
