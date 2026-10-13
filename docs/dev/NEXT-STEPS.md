# Multi-mouse support: handoff and next steps

Last updated: 2026-10-14. Branch: `multi-mouse` (main stays at the last green release state).

## Where things stand

Goal: Upright works with any Logitech HID++ 2.0 mouse that has programmable buttons (REPROG_CONTROLS_V4), and with
several mice at once (any mix of USB, Bluetooth and Unifying/Bolt/Nano receivers, several mice on one receiver).

Design: [`DESIGN-multimouse.md`](DESIGN-multimouse.md) (final, judged from three candidate architectures) plus
[`DESIGN-amendments.md`](DESIGN-amendments.md) (orchestrator overrides; they win). Demo Mode spec:
[`DEMO-MODE-SPEC.md`](DEMO-MODE-SPEC.md). Agent rules and CI lessons: [`AGENT-RULES.md`](AGENT-RULES.md).

| Wave | Content | State |
|---|---|---|
| 0 | Contracts, stubs, pbxproj registration | Done, green, committed |
| 1 | Catalog, classifier + IOKit matching, HID++ identity reads, multi-source engine, mapping schema v3 + migration, Kit simulator, per-device preferences | Done, green (307 tests), committed |
| 2 | DeviceSession capability gate, DeviceRegistry, ConfigurationPlanner | Done, green (352 tests), committed |
| 3 | HIDPPLink hub + per-endpoint EndpointController, request gate, upright-probe `--all`, end-to-end routing tests + 1000-step fuzz | Done (383 tests); see the wave-3 commit for its gate result |
| 4 | App core: DeviceManager (records, LinkSource injection), AppModel (per-model bindings, planner, demo environment), peripherals | **Next** |
| 5 | UI: Mice pane, Buttons model picker, onboarding/copy, Kit cleanup | To do |
| 5b | Demo Mode + `--export-snapshots` (real-UI PNGs for the video/README) | To do |
| 6 | Strings catalog, docs (supported-devices table), pbxproj rename EndpointController.swift, full build/test | To do |
| 7 | Final Opus audit + hardware smoke checklist | To do |
| Video | 30 s launch video; pre-production done ([`launch-video-spec.json`](launch-video-spec.json)) | Waiting for wave 5b snapshots |

The app target still builds through compatibility shims (`MXVerticalController`, compat `status`/`snapshot`), so the
current branch runs like before with one MX Vertical; the multi-mouse UI arrives in waves 4–5.

## How to resume (next Claude Code session)

1. Check out `multi-mouse`, run `swift test --package-path UprightKit` (expect 383+ green) and `make app`.
2. Run waves 4, 5 and 5b with the saved workflow script (it reads the design docs from `docs/dev/`):
   `Workflow({ scriptPath: "<repo>/docs/dev/workflows/multi-mouse-app.js", args: { scratch: "<new session scratchpad>", kitReport: "<one-paragraph summary of waves 0-3>" } })`
   It has a build/test/`make app` gate after each wave, a fix loop (max 2 rounds) and local checkpoint commits.
3. Wave 6 (parallel: strings, docs, project rename, then build/test) and wave 7 (final audit) per §H of the design.
4. Video: run `docs/dev/workflows/launch-video.js` with the same args the launch-video skill uses plus
   `spec: <contents of launch-video-spec.json>` (skips pre-production) once `media/snapshots/manifest.json` exists.
   Brief/visuals/CTA text used for the spec is in the spec itself; size `M`, format `16:9`.
5. Merge `multi-mouse` into `main` once CI is green on the branch (Linux Swift 6.0 + macOS Xcode 16.2).

## Hardware checks only the owner can do (one MX Vertical available)

- `make probe ARGS=--all` over the receiver and over Bluetooth: confirms the 0x0003 unit ID is identical across
  transports (same-unit dedupe), reports raw-XY capability per control, and that the generic IOKit matching still
  finds the mouse. Read-only; does not divert buttons.
- After wave 4: run the app with the MX Vertical and confirm behaviour is unchanged (mappings migrated, fast reconnect
  after sleep/power-cycle, no Input Monitoring prompt at launch).
- Everything about other models and two physical mice at once is simulator-verified only until a contributor with
  that hardware reports `upright-probe --all` output (README marks those models "untested on hardware").

## Known decisions worth remembering

- Support is decided by capability (HID++ ≥ 2.0, pointer kind, 0x1B04 with configurable controls), never by name/PID.
  Keyboards are excluded by kind and PID range (anti-hijack); Lightspeed receivers are never opened.
- Runtime routing key `DeviceAddress(link, index)`; persisted key `DeviceID` (unit-based). Mappings are per model
  (`ModelKey("046D:<pid>")`, PID-canonical from 0x0003); v2 data migrates into the MX Vertical model; v2 key frozen
  for downgrades.
- One HID++ request in flight per transport with an interactive lane (unverified whether receivers tolerate more).
- CI gotchas: Swift 6.0 integer-literal typing; every test method in a `@MainActor` XCTestCase must be `async` for
  Linux test discovery.
