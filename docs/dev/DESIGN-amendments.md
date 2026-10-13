# Amendments to DESIGN-multimouse.md (orchestrator decisions — these override the design where they conflict)

## A1. Simulator lives in the Kit (for Demo Mode)
- The multi-device simulator (SimulatedReceiver, SimulatedDeviceProfile, DeviceProfiles, the HIDPPTransport test double)
  goes in `UprightKit/Sources/UprightKit/Simulation/` (public, Foundation-only, Linux-safe) instead of `T/Simulation/`,
  so the app's Demo Mode can drive the real UI with simulated mice. `T/SimulatedMXVertical.swift` becomes a thin facade
  over it; `FleetHarness` stays in tests as `T/FleetHarness.swift`. W1.6 owns `K/Simulation/*` instead of `T/Simulation/*`.
  Profiles needed at minimum: MX Vertical, MX Master 3S, Lift, plus a keyboard (MX Keys, for the anti-hijack test) and an
  unsupported/HID++1.0 device. Simulated serials/unit IDs must be obviously fake (e.g. "DEMO-0001").
- W0 registers the new `K/Simulation/*.swift` stub files in project.pbxproj (they compile into the app too).

## A2. Demo Mode + snapshot export (spec: scratchpad/DEMO-MODE-SPEC.md — read it)
- W0 creates compiling stubs and registers them in pbxproj:
  `Upright/App/DemoMode.swift` (`enum DemoMode { static var isActive: Bool; static var exportDirectory: URL?; static func configure(arguments: [String]) }`),
  `Upright/App/SnapshotExporter.swift` (stub `@MainActor enum SnapshotExporter { static func run(model: AppModel, to: URL) async throws }`),
  `Upright/Views/SnapshotAnchor.swift` (`extension View { func snapshotAnchor(_ name: String) -> some View }` — no-op unless exporting;
  a PreferenceKey collecting `[String: Anchor<CGRect>]`).
- W4.1 DeviceManager: interface discovery goes through an injectable source protocol (e.g. `LinkSource`): the IOKit monitor
  is the default; Demo Mode supplies simulated links built from `K/Simulation`. With a non-IOKit source DeviceManager must
  never touch IOKit (no matching, no open, no IOHIDRequestAccess).
- W4.2 AppModel: an environment switch (e.g. `AppEnvironment.live / .demo`). In demo: its own UserDefaults suite
  (`io.github.upright.Upright.demo`, cleared at start), no CGEventTaps (scroll, drag rewriter, gesture fallback), a no-op action
  performer, PermissionsMonitor reports granted without prompting, LoginItem and BatteryNotifier untouched/no-op.
- W5.1–W5.3: add `.snapshotAnchor("<name>")` to the views at the rect names listed in DEMO-MODE-SPEC.md (rows, pickers,
  sliders, toggles, battery rows). W5.1 also wires launch args in `UprightApp.swift`: call `DemoMode.configure(arguments:)`
  first; when exporting, show no status item/windows/Dock icon, run the exporter, then exit.
- New task W5.5 (opus, runs AFTER W5.1–W5.3): owns `DemoMode.swift`, `SnapshotExporter.swift`, `SnapshotAnchor.swift`, and the
  `Makefile` target `make snapshots` (→ `media/snapshots/`). Acceptance: `Upright --demo --export-snapshots <dir>` writes every
  essential state id (light + dark, 2x; `menubar.label` 6x) and as many nice-to-haves as possible, plus `manifest.json` with
  rects; exits 0; no IOKit device opened; the user's `io.github.upright.Upright` defaults domain unchanged before/after
  (`defaults export io.github.upright.Upright -` diff); runs fine while a normal Upright instance is running.

## A3. Process rules for parallel agents in one tree
- Build/test with your OWN scratch path to avoid SwiftPM lock contention:
  `swift build --package-path UprightKit --scratch-path <scratchpad>/build-<task id>` (same for `swift test`).
- Files outside your ownership may be mid-edit by another agent. If a build fails ONLY in files you don't own, wait ~1 min
  and retry (up to 5 times), then report it — never edit them.
- Never run git commands that change state (no add/commit/stash/checkout/reset). The orchestrator commits at wave gates.
- Swift 6.0 / Linux rules from PLAN.md "CI lessons" apply (explicit integer literal typing; all test methods in @MainActor
  XCTestCase classes are `async`).
- Don't run the real app against real hardware and don't run `upright-probe --divert`.
