# Demo mode + snapshot export (requirement for the multi-mouse implementation)

Purpose: real-UI marketing captures for the launch video / README screenshots, and a way for
contributors without hardware to see the app with several mice.

## Invocation
- `Upright --demo` — runs the normal UI driven by SIMULATED mice (MX Vertical, MX Master 3S, Lift) from
  the multi-device simulator. Must be fully isolated:
  - no IOKit device matching/opening, no HID++ traffic to real devices, no diversion of the real mouse;
  - no CGEventTaps (scroll, drag, gesture fallback), no synthetic events, no permission prompts, no login item changes;
  - uses its own UserDefaults suite (e.g. `io.github.upright.Upright.demo`, wiped at start) — never reads or writes the user's settings;
  - does not conflict with a normally running Upright instance (skip single-instance logic; distinct status item is fine).
- `Upright --demo --export-snapshots <dir>` — renders the real SwiftUI views OFFSCREEN (NSHostingView/ImageRenderer +
  cacheDisplay or bitmapImageRep, no Screen Recording permission), writes PNGs + `manifest.json`, then exits 0.
  No status item, no windows shown, no Dock icon.

## Output
- PNG per state per appearance: `<id>.<light|dark>.png`, default scale 2x; `menubar.label` at 6x.
- Settings window states rendered at the real settings window size (sidebar + pane) — same view tree as the app.
- `manifest.json`: `[{ id, appearance, file, scale, size:{w,h} (points), rects: { "<name>": {x,y,w,h} (points, top-left origin) } }]`
  Rects come from a no-op-unless-exporting modifier (e.g. `.snapshotAnchor("row.back")`) collected via anchor preferences.
  Needed rect names: each button row (`row.<cid hex>`), profile picker (`profilePicker`), "In effect now" line (`inEffect`),
  overridden rows, gesture editor rows (`gesture.tap|up|down|left|right`), pointer-speed slider (`dpiSlider`), presets (`dpiPresets`),
  device list rows (`device.<n>`), scrolling toggles (`scroll.reverseVertical`, `scroll.speed`, `scroll.smooth`), menu panel battery rows
  (`battery.<n>`), General "behavior" rows.

## State ids (each in light and dark)
Essential: `buttons.global`, `buttons.profile` (an app profile selected — use a real installed app such as Safari so its icon
renders — with "In effect now" and overridden rows), `gesture.editor` (one button with all 5 slots filled),
`device.pointer` (Device pane: device list of the 3 simulated mice, pointer speed slider + presets), `scrolling`
(reverse + smooth ON, Experimental label visible), `menubar.panel` (3 mice with battery rows), `general.behavior`.
Nice to have: `buttons.global.1`…`.6` (Top Button row label = Mission Control, Space Left/Right, a media action, Open App,
Open URL, Run Shortcut); `buttons.profile.2` (a second app); `device.pointer.800|1600|3200`;
`menubar.panel.lowbattery` (one mouse at ≤10%); `menubar.label` (status-item icon + %, 6x);
Device activity log containing "Mac woke up; reapplying button configuration" (or the app's real equivalent).

## Privacy
Simulated devices only: fake serials like `DEMO-0001`; never real device data or the user's real settings/app list beyond icons
of standard Apple apps.
