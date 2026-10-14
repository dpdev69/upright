# Upright improvement plan (shared brief for all agents)

Project root: /Users/dpercinel/cursor/mouseapp/Untitled/Upright-macos-source
Upright is a macOS 13+ SwiftUI menu-bar app that remaps Logitech MX Vertical buttons over HID++ 2.0 (IOKit).
- `UprightKit/` is a SwiftPM package (pure Swift core + IOKit layer guarded by `#if canImport(IOKit)`); tests run on Linux too, so
  anything outside `Platform/` must stay Foundation-only.
- `Upright/` is the app. The Xcode target compiles UprightKit sources DIRECTLY (same module, no `import UprightKit`).
- Baseline copy of the original source (read-only reference): scratchpad/baseline/

## Rules for every agent
- Only edit the files your task OWNS. You may read anything. If you need a change in a file you don't own, don't make it;
  describe it precisely in your final report under "Needs from other owners".
- Do NOT edit Upright.xcodeproj/project.pbxproj unless your task explicitly owns it. If you create new Swift files,
  list them in your report under "New files" (the orchestrator registers them).
- Match the surrounding code style: small focused types, doc comments only where they add info, no over-commenting,
  Swift 5.9 language features, macOS 13 deployment target (gate 14+ APIs with #available).
- Verify before reporting:
  - `swift test --package-path UprightKit` (from project root) must pass.
  - `scratchpad/typecheck.sh` must print `typecheck exit: 0` with no errors (typechecks app + kit as one module).
- Do not commit, push, or touch git. Do not run the app with real devices; do not post synthetic events in tests.
- Final report: summary of changes per file, new files, public API added/changed (signatures), tests added,
  verification output (last lines), known limitations, "Needs from other owners".

## Product decisions (already made — do not re-litigate)
- Fresh-install defaults: NO buttons diverted (Back/Forward/Top stay native: buttons 4/5 and DPI cycling).
  Existing users' saved mappings must be preserved via migration.
- Mappings get a schema version and tolerant per-entry decoding; unreadable raw data is backed up, never silently lost.
- Per-app profiles: a global mapping table plus per-app (bundle ID) overrides that fall back to global per button.
- New actions: Cycle DPI / set DPI preset, Launch App, Open URL, Run Shortcut (Shortcuts.app via `shortcuts run`),
  plus a hold-and-move Gestures action for a button (4 directions + tap) — gestures come in a later wave.
- Scroll settings (app-level CGEventTap): reverse mouse scrolling independently of trackpad (non-continuous events only),
  speed multiplier, optional smooth scrolling, default all off.
- No Sparkle / notarization implementation that needs the user's Apple account; CI gets optional signing steps
  that run only when secrets exist.

## Status log
- Wave 1 DONE (85 tests green, typecheck 0): connection state machine (A), mappings v2 / MappingProfiles / MappingStore /
  new actions / drag synthesis / permissions (C), hardened runtime + CI (D).
  Read the current code; the API summaries are in the source. Key types: MappingProfiles, MappingStore, AppProfile,
  ButtonAction (.launchApp/.openURL/.runShortcut/.device(DeviceAction)), DeviceAction (.cycleDPI, .setDPI(Int)),
  RemapEngine.onDeviceAction, AppModel.performDeviceAction (currently logs only), FrontmostAppMonitor.
- New files not yet in project.pbxproj (orchestrator registers at the end): Upright/App/FrontmostAppMonitor.swift,
  UprightKit/Sources/UprightKit/Mapping/MappingProfiles.swift, MappingStore.swift.

## Toolchain constraint
CI builds with Xcode 16.2 / Swift 6.0 (local is Xcode 27 / Swift 6.4). Don't use language/library features newer than
Swift 6.0 or SDK APIs newer than macOS 13 without #available. Language mode stays Swift 5.
- Wave 2 DONE (131 tests, typecheck 0): DPI (0x2201) / firmware / serial / Easy-Switch (0x1814/0x1815) / raw XY in
  DeviceManager + snapshot (B); AppSettings (scrollSettings, batteryAlertsEnabled, showBatteryInMenuBar, preferredDPI,
  dpiPresets), ScrollController, BatteryNotifier, menu-bar battery label (F).
  More files to register later: Upright/App/AppSettings.swift, ScrollController.swift, BatteryNotifier.swift,
  UprightKit/.../Scrolling/{ScrollSettings,ScrollTransform,SmoothScrollAnimator}.swift, Battery/BatteryAlertPolicy.swift,
  HIDPP/DeviceFeatures.swift.

## Wave 3 contract (gestures ↔ UI)
- Agent G adds `indirect case gestures(GestureSet)` to ButtonAction and `public struct GestureSet: Codable, Hashable, Sendable`
  { tap, up, down, left, right: ButtonAction (non-gesture; default .disabled/.deviceDefault semantics documented in code) }.
- Agent G creates Upright/Views/GestureEditor.swift: `struct GestureEditor: View { init(gestures: Binding<GestureSet>) }`
  (a compact form editing the 5 slots with the standard action picker for each slot).
- UI agents use exactly that API; G creates these types FIRST so the tree compiles early.
- Shared action picker: agent E1 owns ButtonRow.swift and should factor the action menu into a reusable
  `ActionPicker(selection: Binding<ButtonAction>, allowsGestures: Bool)` in a NEW file Upright/Views/ActionPicker.swift,
  created early; G's GestureEditor uses ActionPicker(selection:allowsGestures: false). Until it exists G may use a temporary
  private picker and switch when it appears.
- Localization: write user-facing strings so they're extractable (Text("literal") / LocalizedStringKey, or
  String(localized:) for strings built in code). A later wave adds the String Catalog.

## CI lessons (Oct 13, after first push to github.com/dpdev69/upright)
- Swift 6.0 can't infer `0xE000 | 50` as UInt16 inside a [UInt16] literal — type such expressions explicitly.
- Linux SwiftPM 6.0 test discovery: every test method in a @MainActor XCTestCase class MUST be `async`
  (synchronous ones fail to compile in the generated __allTests__ table). macOS doesn't catch this.
- Repo is now its own git repo (Upright-macos-source), remote origin = dpdev69/upright, CI green at 01c22a1.
  Agents: never `git add -A`; only the orchestrator commits.
