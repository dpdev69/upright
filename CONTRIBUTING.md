# Contributing to Upright

Thanks for helping. Bug reports with real hardware output are the most useful thing you can
send: see the issue templates in `.github/ISSUE_TEMPLATE`.

## Layout

```
Upright/                    the macOS app (SwiftUI + AppKit)
  App/                      AppModel, AppSettings, DeviceManager, ScrollController, …
  Views/                    menu-bar panel, settings panes, onboarding
UprightKit/                 Swift package: protocol, device, mapping, scrolling, battery
  Sources/UprightKit/
    Platform/               IOKit glue (macOS only, behind #if canImport(IOKit))
    Device/ HIDPP/ Mapping/ Scrolling/ Battery/    pure Swift, Foundation only
  Sources/upright-probe/    command-line tool behind `make probe`
  Tests/UprightKitTests/    unit tests, including the simulated mouse
docs/HIDPP.md               every HID++ message Upright sends
scripts/                    DMG packaging and icon generation
.github/workflows/          CI and release
```

## Build and test

```bash
make test     # swift test --package-path UprightKit
make app      # Release build → build/Build/Products/Release/Upright.app
make verify   # check the signature of the built app
make open     # build and launch
make probe    # try the HID++ layer on a real mouse; ARGS=--divert to watch button events
```

Please run `make test` before opening a pull request, and `make app` if you touched the app
target.

## The app compiles UprightKit directly

The Xcode target does **not** link the package. It references the files in
`UprightKit/Sources/UprightKit` and compiles them into the app module, so app code uses Kit
types without `import UprightKit`. Two consequences:

- **A new Swift file must be added to `Upright.xcodeproj/project.pbxproj`** (to the Upright
  target's Sources build phase), whether it lives in `Upright/` or in
  `UprightKit/Sources/UprightKit/`. Add it in Xcode (drag it into the group and tick the
  Upright target) and commit the project file. The package picks up new files on its own, so
  `swift test` passing doesn't prove the app builds.
- Kit types that the app uses need `public` access for the package's tests and the probe, and
  stay internal-safe for the app. Don't rely on `import UprightKit` inside `Upright/`.

## Keep the Kit portable

The tests run on Linux in CI, so everything in `UprightKit/Sources/UprightKit` **outside
`Platform/`** must use Foundation only: no AppKit, CoreGraphics, IOKit, Combine or
`os.Logger`. IOKit-dependent code belongs in `Platform/` behind `#if canImport(IOKit)`. Anything
that needs AppKit or CGEvent (posting events, event taps, notifications) goes in `Upright/App/`
behind a small protocol if the Kit needs to call it (see `ActionPerforming`).

Put decisions in the Kit and side effects in the app. That keeps them testable.

## Tests

- Use the **simulator**, not hardware. `SimulatedMXVertical` (in the test target) answers
  HID++ like a real mouse, directly or behind a receiver slot. Add a scenario to
  `ControllerTests` or `DeviceFeatureTests` for device behavior; extend the simulator if it
  lacks a feature.
- Pure logic (mappings, profiles, scrolling, gestures, battery policy, persistence) gets plain
  unit tests next to the existing ones.
- Tests must not post synthetic events, touch real devices, or depend on timing beyond what the
  controller's configurable delays allow. Set short delays (`reconnectDelay`, `retryBaseDelay`,
  `probeTimeout`) in tests.
- If you change how mappings are stored, add a persistence test and keep migrating old data:
  unreadable data is backed up, never dropped.

## Compatibility

- Deployment target is macOS 13. Gate newer APIs with `#available`.
- CI builds with Xcode 16.2 (Swift 6.0) and the project stays in Swift 5 language mode. Don't
  use language or SDK features newer than that.
- Raw `Codable` formats (`ButtonAction`, `DeviceAction`, settings) are saved data. Don't rename
  cases or payload labels; add new cases instead and bump `MappingProfiles.schemaVersion` only
  for incompatible changes.

## Style

- Small, focused types. Match the code around you.
- Comments explain *why* or document a non-obvious protocol detail. Don't narrate the code.
- User-facing strings are written so they can be localized: `Text("literal")`, or
  `String(localized:)` for strings built in code.
- No force unwraps in app code paths. HID++ replies can be short or wrong; check lengths.
- Keep the app permission-light. Ask for Accessibility only where an action truly needs it
  (`requiresAccessibility`), and never prompt at launch.
- Don't add dependencies.

## Protocol work

Write new HID++ support from public documentation and the credited projects, as the README
describes. Don't copy code from GPL projects and don't use Logitech binaries. Record every new
message in `docs/HIDPP.md`.

## Pull requests

1. Keep a pull request to one change.
2. Update `README.md`, `INSTALL.md` or `docs/HIDPP.md` when behavior or protocol use changes,
   and add a line under **Unreleased** in `CHANGELOG.md`.
3. Fill in the pull request template, including what you tested and on which mouse
   connection.

## Releasing

1. Set `MARKETING_VERSION` in `project.pbxproj` and move the **Unreleased** changelog entries
   under the new version.
2. Tag the commit `vX.Y.Z`. CI refuses a tag that doesn't match `MARKETING_VERSION`.
3. The `release` job attaches `Upright-X.Y.Z.dmg` to a GitHub release. The DMG is ad-hoc
   signed unless the signing and notarization secrets are set (see the README).
