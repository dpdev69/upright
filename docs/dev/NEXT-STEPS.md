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
| 4 | App core: DeviceManager (records, LinkSource injection), AppModel (per-model bindings, planner, demo environment), peripherals | Done, committed (`8f2e02c`) |
| 5 | UI: Mice pane, Buttons model picker, onboarding/copy, Kit cleanup | Done, committed (`88a66aa`) |
| 5b | Demo Mode + `--export-snapshots` (real-UI PNGs for the video/README) | Done, committed (`30bbb2b`); snapshot export (`make snapshots`) writes real-UI PNGs plus `manifest.json` to `media/snapshots/` |
| 6 | Strings catalog, docs (supported-devices table), pbxproj rename EndpointController.swift, full build/test | Done, committed (`06f15a2`); 388 Kit tests green after the wave 7 audit fixes |
| 7 | Final Opus audit + hardware smoke checklist | Done, committed (`c6a3900`): audit (two lenses, see "Audit outcome") fixes and [`HARDWARE-SMOKE-CHECKLIST.md`](HARDWARE-SMOKE-CHECKLIST.md); 388 tests green, `make app` green. Remaining: push branch + CI, owner hardware smoke test, launch video, merge |
| Video | 30 s launch video; pre-production done ([`launch-video-spec.json`](launch-video-spec.json)) | Unblocked: `media/snapshots/manifest.json` exists (not yet run) |

The multi-mouse app is in: per-model bindings, the Mice and Buttons UI, Demo Mode (`Upright --demo`) and the
snapshot exporter (`make snapshots`). None of the multi-mouse code (HIDPPLink/EndpointController, the request gate,
generic vendor-046D usage matching, mapping v3 migration) has run on real hardware yet (see the smoke checklist).

## Remaining work

Waves 0-7 are done. What is left, in order:

1. **Owner hardware smoke test** on the one MX Vertical: follow [`HARDWARE-SMOKE-CHECKLIST.md`](HARDWARE-SMOKE-CHECKLIST.md)
   (about 30-40 minutes; never run `upright-probe --divert`). Record the result and date here and in the commit message.
2. **Push the branch and run CI** (Linux Swift 6.0 + macOS Xcode 16.2). Not run yet: CI only triggers on pushes to
   `main` and on pull requests, so push `multi-mouse` and open a draft PR against `main` (needs the owner's go-ahead).
   Green CI is the merge gate. The Linux Swift 6.0 job has never seen this branch (no docker or 6.0 toolchain locally;
   only static checks were done, see "Audit outcome").
3. **Launch video**: `docs/dev/workflows/launch-video.js` is now unblocked because `media/snapshots/manifest.json`
   exists. Run it with the same args the launch-video skill uses plus `spec: <contents of launch-video-spec.json>`
   (skips pre-production). Size `M`, format `16:9`.
4. **Merge** `multi-mouse` into `main` once CI is green and the smoke test has passed.

How to resume: check out `multi-mouse` (wave 7 is done in `c6a3900`: 388 tests green, `make app` green; nothing is
uncommitted), run `swift test --package-path UprightKit` and `make app` to re-confirm, then continue from item 1 above
(the remaining items are: owner hardware smoke test, push the branch + CI, launch video, merge).

Historical note: waves 4, 5 and 5b were run with `docs/dev/workflows/multi-mouse-app.js`; it is not needed any more.

## Hardware checks only the owner can do (one MX Vertical available)

The full step-by-step list, with expected output and what to paste back, is in
[`HARDWARE-SMOKE-CHECKLIST.md`](HARDWARE-SMOKE-CHECKLIST.md). Summary of what it must settle:

- Same unit ID over Bluetooth and Unifying (same-unit dedupe); raw-XY flags per control.
- Mappings, app profiles and pointer speed migrate unchanged from 2.x; no Input Monitoring prompt at launch.
- Reconnect latency after sleep, power-cycle and Easy-Switch is as fast as 2.x; quit restores native buttons; no stuck
  keys when toggling "Remap buttons".
- **Highest priority** (checklist section 4): interface opening changed in the wave 7 audit: the IOHIDManager is no longer opened, only the interfaces the
  classifier accepts are (one `IOHIDDeviceOpen` each). Confirm the mouse is still found and button reports still
  arrive over the receiver, USB and Bluetooth (`tccutil reset ListenEvent io.github.upright.Upright` to test with
  Input Monitoring undecided; expect no prompt and no "macOS is blocking access" banner).
- Everything about other models and two physical mice at once is simulator-verified only until a contributor with
  that hardware reports `upright-probe --all` output (README marks those models "untested on hardware").

## Audit outcome

Final audit at `06f15a2`, two lenses (A: transport, hub, engine, app; B: data, UI, build). Read-only verification:
`swift test` 383 tests, 0 failures (the only warnings are the expected `onlyWhileMXVerticalConnected` deprecation
warnings in ScrollTransformTests); `xcodebuild` Debug and Release (universal, ad-hoc, hardened runtime) build
succeeded; no change to deployment target, signing, entitlements or `Package.swift`. Static Swift 6.0 / Linux lint
passed (async `@MainActor` tests, typed integer literals, Foundation-only Kit outside `Platform/`). Not run: Linux
swift:6.0 and CI on the branch.

Accepted limitations and deferred items:

- **A1** (fixed in `c6a3900`): Demo Mode no longer registers or reads the login item.
- **A2** (fixed in `c6a3900`, hardware check outstanding): `IOHIDManagerOpen` is gone, so interfaces the classifier
  rejects are no longer opened implicitly and the implicit Input Monitoring prompt risk is removed in code; still to be
  confirmed on the MX Vertical (checklist section 4).
- **A3** (fixed in `c6a3900`): `upright-probe` without `--divert` is read-only for button reporting.
- **A5**: AppKit UI-state keys land in the real defaults domain during an interactive demo.
- **A6**: the shortcut main key is not refcounted across devices (modifiers and mouse buttons are).
- **A9**: cursor-fallback gestures cannot be attributed to a device.
- **A11**: transient-ID corner case for per-unit DPI.
- Request gate priority is strict, so background requests could starve under sustained interactive load; not realistic
  (interactive bursts are bounded).
- The legacy `MXVerticalController` facade is used only by tests; the app and `upright-probe` use `HIDPPLink` directly.
- No restore is sent by design on unpair, replaced slot, or transport close (nothing reachable to send to).
- Hardware-unverified: same unit ID across BT and Unifying (checklist step 2), raw-XY v5 first-report drop (D16).
- **B1**: the branch has never run in CI.
- Only the MX Vertical is verified on hardware; all other models are simulator-verified only.

## Known decisions worth remembering

- Support is decided by capability (HID++ ≥ 2.0, pointer kind, 0x1B04 with configurable controls), never by name/PID.
  Keyboards are excluded by kind and PID range (anti-hijack); Lightspeed receivers are never opened.
- Runtime routing key `DeviceAddress(link, index)`; persisted key `DeviceID` (unit-based). Mappings are per model
  (`ModelKey("046D:<pid>")`, PID-canonical from 0x0003); v2 data migrates into the MX Vertical model; v2 key frozen
  for downgrades.
- One HID++ request in flight per transport with an interactive lane (unverified whether receivers tolerate more).
- CI gotchas: Swift 6.0 integer-literal typing; every test method in a `@MainActor` XCTestCase must be `async` for
  Linux test discovery.
