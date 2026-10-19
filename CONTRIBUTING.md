# Contributing to Upright

Thanks for helping. The most useful thing you can send is real hardware output: Upright is
tested on a single mouse (the MX Vertical), and every other model is built from published data
and a simulator until someone with the mouse says otherwise. Pick the issue template that fits
(`.github/ISSUE_TEMPLATE`):

- **Bug report**: something doesn't work. Attach `make probe ARGS=--all` output.
- **Request support for a mouse** (`new_mouse.md`): your mouse isn't in
  [`docs/DEVICES.md`](docs/DEVICES.md), or is there as "untested" and you tried it.
- **Feature request**: a new action or setting.

## Layout

```
Upright/                    the macOS app (SwiftUI + AppKit)
  App/                      AppModel, DeviceManager, LinkSource, DemoMode, SnapshotExporter, …
  Views/                    menu-bar panel, settings panes, onboarding
UprightKit/                 Swift package: protocol, device, mapping, scrolling, battery
  Sources/UprightKit/
    Platform/               IOKit glue (macOS only, behind #if canImport(IOKit))
    Device/                 HIDPPLink (hub), EndpointController, DeviceSession, DeviceRegistry,
                            ConfigurationPlanner, DeviceCatalog, InterfaceClassifier, …
    HIDPP/ Mapping/ Scrolling/ Battery/
    Simulation/             software mice and receivers (also used by Demo Mode)
                            (everything outside Platform/ is pure Swift, Foundation only)
  Sources/upright-probe/    command-line tool behind `make probe`
  Tests/UprightKitTests/    unit tests, including the end-to-end fleet tests
docs/HIDPP.md               every HID++ message Upright sends, and the hub/endpoint architecture
docs/DEVICES.md             supported models and their verification status
docs/dev/                   design notes of the multi-mouse work (background reading)
media/snapshots/            pictures of the real UI rendered by Demo Mode (`make snapshots`)
scripts/                    DMG packaging and icon generation
.github/workflows/          CI and release
```

Read [`docs/HIDPP.md`](docs/HIDPP.md) first if you touch anything under `Device/` or `HIDPP/`:
it explains the hub (`HIDPPLink`, one per HID interface) and the endpoint
(`EndpointController`, one per mouse), the identity model, the capability gate and the request
gate.

## Build and test

```bash
make test       # swift test --package-path UprightKit
make app        # Release build → build/Build/Products/Release/Upright.app
make verify     # check the signature of the built app
make open       # build and launch
make probe      # try the HID++ layer on a real mouse
make snapshots  # render the real UI with simulated mice into media/snapshots/
```

`make probe` passes `ARGS` to `upright-probe`:

```bash
make probe ARGS=--all                  # also read interfaces Upright doesn't use (keyboards,
                                       # Lightspeed receivers, unknown mice): reads only
make probe ARGS=--divert               # divert every mouse's buttons and print the events
make probe ARGS='--divert="bolt slot 2"'   # only the mice whose label contains that text
make probe ARGS=--trace                # print the raw HID++ reports in both directions
make probe ARGS=--help
```

Quit Upright first, even without `--divert`: both use HID++ software ID `0x0A` on the same
shared interface (each could take the other's replies), the probe turns on a receiver's
notification flags, and two programs diverting the same buttons fight over them. Every line the
probe prints is prefixed with its device, for example `[MX Master 3S · Bolt slot 2]`.

Please run `make test` before opening a pull request, `make app` if you touched the app
target, and `make snapshots` if you touched a view (the pictures in the README come from it).

## The app compiles UprightKit directly

The Xcode target does **not** link the package. It references the files in
`UprightKit/Sources/UprightKit` and compiles them into the app module, so app code uses Kit
types without `import UprightKit`. The package picks up new files on its own, so `swift test`
passing doesn't prove the app builds. Two consequences:

- Kit types that the app uses need `public` access for the package's tests and the probe. Don't
  rely on `import UprightKit` inside `Upright/`.
- **Every Swift file must be registered once in the Upright target.** This is the pbxproj
  checklist.

### The pbxproj checklist

For a **new** `.swift` file under `Upright/` or `UprightKit/Sources/UprightKit/`
(tests and `Sources/upright-probe/` are not in the Xcode project):

1. In Xcode, drag the file into the matching group (the groups mirror the folders), with
   **Upright** ticked as the target. Or edit `Upright.xcodeproj/project.pbxproj` by hand and add
   all four of: a `PBXFileReference`, a `PBXBuildFile`, the file in its `PBXGroup`, and one
   entry in the Upright target's `PBXSourcesBuildPhase`.
2. Check the file is registered **exactly once**. Zero registrations compile fine in
   `swift test` and then fail in `make app` with "cannot find type in scope". Two give
   duplicate-symbol errors.
3. Run the check below. It must print nothing.
4. Commit the project file with the source file.

For a **rename or delete**, remove or rename all four entries too. Use `git mv`, and rename the
file in Xcode's navigator so it keeps the reference.

```bash
# From the repository root. Prints each Swift file not registered exactly once in the Upright
# target's Sources phase, and each Sources entry whose file no longer exists.
phase=$(awk '/Begin PBXSourcesBuildPhase/,/End PBXSourcesBuildPhase/' Upright.xcodeproj/project.pbxproj)
for f in $(find Upright UprightKit/Sources/UprightKit -name '*.swift'); do
  n=$(grep -c " $(basename "$f") in Sources" <<<"$phase")
  [ "$n" -eq 1 ] || echo "$f: registered $n times"
done
for name in $(grep -o '[A-Za-z0-9_+]*\.swift in Sources' <<<"$phase" | sed 's/ in Sources//'); do
  find Upright UprightKit/Sources/UprightKit -name "$name" | grep -q . || echo "$name: in the project but not on disk"
done
```

File names must be unique across `Upright/` and the Kit, because both compile into one module.

## Keep the Kit portable

The tests run on Linux in CI, so everything in `UprightKit/Sources/UprightKit` **outside
`Platform/`** must use Foundation only: no AppKit, CoreGraphics, IOKit, Combine or
`os.Logger`. IOKit-dependent code belongs in `Platform/` behind `#if canImport(IOKit)`. Anything
that needs AppKit or CGEvent (posting events, event taps, notifications) goes in `Upright/App/`
behind a small protocol if the Kit needs to call it (see `ActionPerforming`, `LinkSource`).

Put decisions in the Kit and side effects in the app. That keeps them testable. The registry
(which endpoint is active), the planner (what each endpoint should be doing), the classifier
(which interface to open) and the catalog are all in the Kit for that reason.

## Tests

Use the **simulator**, not hardware. Tests must not post synthetic events, touch real devices,
or depend on timing beyond what the configurable delays allow.

### Simulator profiles

`UprightKit/Sources/UprightKit/Simulation/` holds software mice and receivers that answer HID++
the way published device dumps say real ones do. It is public and Foundation-only, so tests and
Demo Mode use the same code:

| Type | What it is |
| --- | --- |
| `SimulatedDeviceProfile` | One device as plain values: name, kind, protocol version, product IDs, unit ID and serial, feature table (with versions and flags), control table, firmware entities, DPI list, battery feature, Easy-Switch hosts. |
| `DeviceProfiles` | Ready-made profiles: `mxVertical` (plus `mxVerticalSecondUnit`), `mxMaster3S`, `lift`, `mxMaster3`, `m720`, `mxErgo`, `m185`, plus the cases that must *not* be served: `g502Lightspeed` (no `0x1B04`), `mxKeys` (a keyboard with many divertable keys), `m510HIDPP10` (HID++ 1.0), `mouseWithoutUnitID`. `DeviceProfiles.all` lists them. |
| `SimulatedReceiver` | A receiver with slots 1…6: `.unifying([slot: profile])`, `.bolt(…)` and `.nano(…)`, each with its own pairing layout. Pair, unpair, re-pair, sleep and wake slots, hold buttons, move the pointer, report batteries, drop requests, add latency. |
| `SimulatedDirect` | One device on a USB or Bluetooth link (device index `FF`). |

Both transports record what the host sent (`sentReports`, `requestCount(feature:function:slot:)`,
`setReportingCount`) and the highest number of overlapping requests (`requestsInFlightMax`), so a
test can assert what went over the wire and what state a "device" ended up in
(`diverted(slot:)`, `dpi(slot:)`, …).

A test builds a hub on a simulator and checks the result:

```swift
@MainActor
final class MyTests: XCTestCase {
    func testSecondMouseKeepsItsOwnButtons() async {
        let receiver = SimulatedReceiver.unifying([1: DeviceProfiles.mxVertical, 2: DeviceProfiles.mxMaster3])
        let hub = makeLink(receiver)                       // TestSupport.swift: ControllerTuning.fastTests
        hub.configurationProvider = { _, snapshot in
            EndpointConfiguration(divert: Set(snapshot.configurableControls.map(\.cid)))
        }
        hub.start()
        await eventually("both connected") { isConnected(hub, at: 1) && isConnected(hub, at: 2) }
        XCTAssertEqual(receiver.diverted(slot: 2), Set(DeviceProfiles.mxMaster3.controls.filter(\.isConfigurable).map(\.cid)))
    }
}
```

- `FleetHarness` (test target) wires real hubs, `DeviceRegistry`, `ConfigurationPlanner`,
  `MappingLibrary`, preferences and `RemapEngine` the way `DeviceManager` and `AppModel` do,
  minus IOKit and AppKit. Use it for anything that spans devices (`EndToEndRoutingTests`).
- `MultiDeviceControllerTests` covers hub behavior: several mice per receiver, the capability
  gate, per-slot backoff, re-pairing, the request gate and teardown.
- `SimulatedMXVertical` is a facade that the older single-mouse `ControllerTests` use. New tests
  should use `SimulatedReceiver` or `SimulatedDirect` with `DeviceProfiles` directly.
- Short delays (`ControllerTuning.fastTests`, in `TestSupport.swift`) keep the suite fast.
- To simulate a new device, add a profile to `DeviceProfiles.swift`: copy its numbers from a
  published dump or an `upright-probe --all` output (see below). Unit IDs and serial numbers of
  simulated devices must be obviously fake (`0x?A2B3C4D` and `DEMO-00NN`), because Demo Mode
  shows them.

### Other tests

- Pure logic (mappings, profiles, scrolling, gestures, battery policy, persistence, the
  catalog and classifier) gets plain unit tests next to the existing ones.
- If you change how mappings are stored, add a persistence test and keep migrating old data:
  unreadable data is backed up, never dropped. Mappings are schema v3 (one setup per model);
  v2 data migrates into the MX Vertical model.
- Test classes that touch main-actor code are `@MainActor`, and **every test method in them must
  be `async`** (see [CI lessons](#ci-lessons)).

## Demo Mode and snapshots

Demo Mode runs the real UI against simulated mice, with no hardware and no permission:

```bash
make app
build/Build/Products/Release/Upright.app/Contents/MacOS/Upright --demo
```

It builds a `DemoMode.Fleet`: an MX Vertical on a simulated Unifying receiver, an MX Master 3S
on a simulated Bolt receiver and a Lift over simulated Bluetooth, driven by `SimulatedLinkSource`
(`Upright/App/LinkSource.swift`) instead of IOKit. It has its own defaults suite
(`io.github.upright.Upright.demo`, wiped at start), installs no event taps, posts no events,
asks for no permission and leaves the login item and battery notifications alone, so it can run
next to a normal Upright and never touches your settings. All names and serials are made up.
`DemoMode.Scenario` (in `Upright/App/DemoMode.swift`) holds the setup the demo shows: button
mappings for each model, app profiles, scrolling and pointer speeds.

`make snapshots` renders the interface offscreen into `media/snapshots/`:

```bash
make snapshots                     # replaces the PNGs and manifest.json in media/snapshots/
make snapshots SNAPSHOTS=/tmp/ui   # somewhere else
```

It builds the app, then runs `Upright --demo --export-snapshots <dir>`, which writes
`<state>.<light|dark>.png` at 2x (`menubar.label` at 6x) and a `manifest.json` with each image's
size and the rectangles of its named elements, then quits. It touches no real device and none of
your settings, and runs fine while Upright is running.

To add a state, add a `State` to `SnapshotExporter.States.all` and name the views the manifest
should locate with `.snapshotAnchor("name")` (a no-op outside an export). A new view that shows
mouse data should be reachable in Demo Mode, so change the scenario rather than special-casing
the view. `UPRIGHT_SNAPSHOT_ONLY=<id prefix> make snapshots` renders only the states you are
working on. The design is in [`docs/dev/DEMO-MODE-SPEC.md`](docs/dev/DEMO-MODE-SPEC.md).

## Adding a model from an `upright-probe --all` dump

Upright serves a mouse because of what it answers (HID++ 2.0, a pointer, `0x1B04` with
remappable controls), not because it is in a table, so a mouse that is missing from the catalog
may already work. The catalog adds its name, the order and wording of its controls, a suggested
setup and its product IDs. You need the mouse (or someone's dump) and `make probe ARGS=--all`.

1. **Get the dump.** Quit Upright, connect the mouse the way you use it, wake it, and run
   `make probe ARGS=--all`. Every line starts with the device's label. For each device you get
   an `Identity` block, the feature table and a control table (abridged, with made-up numbers):

   ```
   [MX Master 3S · Bolt slot 1] ✓ MX Master 3S: Upright supports this device
   [MX Master 3S · Bolt slot 1]     Connection: Bolt slot 1, device index 0x01, HID++ 4.5
   [MX Master 3S · Bolt slot 1]     Identity:
   [MX Master 3S · Bolt slot 1]       Kind: mouse
   [MX Master 3S · Bolt slot 1]       Model: 046D:B034 (not in Upright's catalog)
   [MX Master 3S · Bolt slot 1]       Model IDs (0x0003): Bluetooth LE B034
   [MX Master 3S · Bolt slot 1]       Wireless PID from the receiver: B034
   [MX Master 3S · Bolt slot 1]     Controls (REPROG_CONTROLS_V4 v5, 8 controls, 5 remappable by Upright):
   [MX Master 3S · Bolt slot 1]      * CID 0x0052  TID 0x0000  Middle Button  [mouse, reprogrammable, divertable, persistent, raw XY]  (flags …)
   ```

   `--all` also lists what Upright leaves alone and why (a Lightspeed receiver, a keyboard, a
   HID++ 1.0 device), and prints each receiver's `Pairing table` with its layout.

   The output includes the unit ID and serial number. Black them out if you like before
   sharing, but keep a note of whether the unit ID is the same across connections if you ran
   the probe over two of them.

2. **Read the numbers.** The *Model IDs* give the product IDs per transport (`Bluetooth`,
   `Bluetooth LE`, `wireless`, `USB`). The first of Bluetooth, Bluetooth LE, wireless, USB is
   the model's canonical ID, and `ModelKey("046D:XXXX")` is built from it. Controls marked `*`
   are the ones Upright can remap. A control name of "unnamed" means Solaar's table has no entry
   for that CID.

3. **Add the catalog entry** in `Device/DeviceCatalog.swift` with the `entry(…)` helper and list
   it in `DeviceCatalog.models`:

   ```swift
   static let mxMaster3S = entry("MX Master 3S", bluetooth: [0xB034], wireless: [0xB034],
                                 controls: [back, forward, gesture, smartShift, wheel])
   ```

   - The key becomes the first Bluetooth ID, else the first wireless one, else the USB one.
     **That must be the canonical ID the mouse reports.** The same value is already the key under
     which an unlisted mouse's mappings were saved, so a matching entry keeps users' setups.
     Never change an existing model's key.
   - `controls` is the display order (use `KnownControl` CIDs, or define a new constant). Every
     CID needs a name in `ControlCatalog.solaarNames` and wording in `ControlCatalog.genericText`
     or the model's own `text:` (`CatalogTests.testEveryControlOrderCIDIsNamed` checks it). A
     model-specific name goes in `text:`; see the MX Ergo's "Precision Button".
   - Do not list Left and Right click. Product IDs must be unique across the catalog.
   - New entries are `.publishedDump`. Only the maintainer sets `.hardware`, after testing
     (`CatalogTests.testOnlyTheMXVerticalIsVerifiedOnHardware`).
   - A new **receiver** goes in `DeviceCatalog.receivers` with its pairing layout (`.unifying`,
     `.bolt`). A mouse that is only reachable behind a receiver the classifier doesn't open
     (Lightspeed, 27 MHz) needs the proof first: show a dump with `0x1B04`.
   - Direct mice with a product ID outside the USB range `C07D`-`C094` or the Bluetooth range
     `B012`-`B0FF` are accepted because they are in the catalog
     (`InterfaceClassifier.classifyDirect`). A keyboard-range ID is accepted the same way, so
     double-check that the device is really a pointer.

4. **Add a simulator profile** to `Simulation/DeviceProfiles.swift` from the same dump, and add
   it to `DeviceProfiles.all`. Copy the feature table with its versions and flags, the control
   table (flags, raw XY bit, group), the firmware entities and the battery feature; invent the DPI
   list if you don't have one; use a fake unit ID and `DEMO-00NN` serial. A device that is
   interesting because it is *not* served (no `0x1B04`, HID++ 1.0, a keyboard) is a profile too.

5. **Add tests.** Extend the expectations in `CatalogTests.testResearchedModelsArePresentWithTheirIDs`
   (it also checks the number of models), add the profile to
   `SimulatorTests.testMouseProfilesAnswerFromTheirTables`, and, if the model has a quirk, a
   hub test in `MultiDeviceControllerTests`. `make test` must pass.

6. **Update the docs.** Add the model to [`docs/DEVICES.md`](docs/DEVICES.md) as *Published data
   (untested on hardware)*, add a line under **Unreleased** in `CHANGELOG.md`, and mention the
   dump in the pull request. Don't write that a model "works" before someone has run it.

If the dump shows something the hub gets wrong (a different device index, a pairing layout
that doesn't parse, controls that refuse `setCidReporting`), describe it in the pull request and
attach the `--trace` output; it is more valuable than the catalog line.

## CI lessons

CI builds the app with Xcode 16.2 (Swift 6.0) on macOS 15, runs `swift test` there, and runs it
again on Ubuntu with Swift 6.0. Your local toolchain may be newer, and macOS doesn't catch
everything Linux does. The
project stays in Swift 5 language mode and targets macOS 13: don't use language or SDK features
newer than that, and gate newer APIs with `#available`. Known traps:

- **Integer literals in mixed expressions.** Swift 6.0 can't infer `0xE000 | 50` as `UInt16`
  inside a `[UInt16]` literal. Type such expressions explicitly: `UInt16(0xE000) | 50`.
- **Every test method in a `@MainActor` `XCTestCase` class must be `async`.** Synchronous ones
  fail to compile in the generated `__allTests__` table of Linux SwiftPM 6.0. macOS doesn't
  complain, so a green local run proves nothing. (Classes that aren't `@MainActor` can keep
  synchronous tests.)
- **Foundation only outside `Platform/`.** The Linux build has no AppKit, IOKit or Combine, so
  a stray import breaks CI and nothing else. `InterfaceClassifier.hex` avoids `String(format:)`
  to be exact on Linux too; do the same where a test compares formatted text.
- New Kit value types are `Sendable`, and types that hold callbacks are `@MainActor`, as the
  existing ones are.
- Anything that passes only because of timing is a flaky test on a loaded CI machine. Use
  `eventually(…)` with a generous timeout and the fast tuning, not `sleep`.

## Compatibility

- Deployment target is macOS 13. Gate newer APIs with `#available`.
- Raw `Codable` formats (`ButtonAction`, `DeviceAction`, `MappingLibrary`, settings) are saved
  data. Don't rename cases or payload labels; add new cases instead and bump the schema version
  only for incompatible changes. A model key (`046D:XXXX`) is part of that data too.

## Style

- Small, focused types. Match the code around you.
- Comments explain *why* or document a non-obvious protocol detail. Don't narrate the code.
- User-facing strings are written so they can be localized: `Text("literal")`, or
  `String(localized:)` for strings built in code.
- No force unwraps in app code paths. HID++ replies can be short or wrong; check lengths.
- Keep the app permission-light. Ask for Accessibility only where an action truly needs it
  (`requiresAccessibility`), and never prompt at launch.
- A device that isn't a supported mouse is never written to. If you add a code path that
  writes, make sure it sits behind the capability gate.
- Don't add dependencies.

## Protocol work

Write new HID++ support from public documentation and the credited projects, as the README
describes. Don't copy code from GPL projects and don't use Logitech binaries. Record every new
message in `docs/HIDPP.md`, and say whether it was tested on hardware.

## Pull requests

1. Keep a pull request to one change.
2. Update `README.md`, `INSTALL.md`, `docs/HIDPP.md` or `docs/DEVICES.md` when behavior,
   protocol use or device support changes, and add a line under **Unreleased** in
   `CHANGELOG.md`.
3. Fill in the pull request template, including what you tested and on which mouse and
   connection. If you couldn't test on hardware, say so; the simulator is a good answer.

## Releasing

1. Set `MARKETING_VERSION` in `project.pbxproj`, raise `CURRENT_PROJECT_VERSION` by one, and
   move the **Unreleased** changelog entries under the new version.
2. Tag the commit `vX.Y.Z`. CI refuses a tag that doesn't match `MARKETING_VERSION`.
3. The `release` job attaches `Upright-X.Y.Z.dmg` to a GitHub release. The DMG is ad-hoc
   signed unless the signing and notarization secrets are set. See
   [docs/dev/RELEASING.md](docs/dev/RELEASING.md) for the full steps.
